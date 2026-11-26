//
//  ContentView.swift
//  NFCCardLab
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = CardStore()
    @StateObject private var reader = NFCReader()
    @StateObject private var emulator = CardEmulator()

    @State private var showWriteSheet = false
    @State private var showPageSheet = false
    @State private var writeText = "https://example.com"
    @State private var pageText = ""
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        reader.beginRead { card in
                            guard let card else { toast = "没有读到卡片"; return }
                            let url = store.save(card)
                            toast = "已保存 \(card.label)" + (url == nil ? "（写盘失败）" : "")
                        }
                    } label: {
                        Label(reader.isScanning ? "扫描中…" : "读取卡片", systemImage: "wave.3.right")
                    }
                    .disabled(reader.isScanning)

                    Button {
                        showWriteSheet = true
                    } label: {
                        Label("写入 NDEF", systemImage: "square.and.pencil")
                    }

                    Button {
                        pageText = ""
                        showPageSheet = true
                    } label: {
                        Label("写入页镜像 (pages.txt)", systemImage: "square.stack.3d.up")
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text(reader.status)
                }

                Section("卡片库 (\(store.cards.count))") {
                    if store.cards.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有抓过卡").foregroundStyle(.secondary)
                            Text("点上面「读取卡片」贴一张 NFC 标签试试；\n或用「文件」App 把 sample/example-card.json 拖进本 App 的 Documents/cards/。")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(store.cards) { card in
                        NavigationLink {
                            CardDetailView(card: card, emulator: emulator)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.label).font(.headline)
                                Text(card.summary).font(.caption).foregroundStyle(.secondary)
                                Text("\(card.transcript.count) 条 APDU · \(card.pages.count) 页")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { idx in
                        idx.map { store.cards[$0] }.forEach(store.delete)
                    }
                }
            }
            .navigationTitle("NFC 卡片实验室")
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            self.toast = nil
                        }
                }
            }
            .sheet(isPresented: $showPageSheet) {
                NavigationStack {
                    Form {
                        Section {
                            TextEditor(text: $pageText)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 220)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                        } header: {
                            Text("粘贴 pages.txt 内容")
                        } footer: {
                            Text("每行「页号 4字节hex」。UID 页与各型号末尾的锁位/配置/密码页会自动跳过。")
                        }
                        Section {
                            Button("开始写页") {
                                let pages = PageScript.parse(pageText)
                                guard !pages.isEmpty else { toast = "没解析到页数据"; return }
                                showPageSheet = false
                                reader.beginWritePages(pages) { ok, msg in
                                    toast = (ok ? "✓ " : "✗ ") + msg
                                }
                            }
                        }
                    }
                    .navigationTitle("写 NTAG 页")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showPageSheet = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showWriteSheet) {
                NavigationStack {
                    Form {
                        Section("内容") {
                            TextField("文本 / URL", text: $writeText, axis: .vertical)
                                .lineLimit(3...6)
                        }
                        Section {
                            Button("开始写入") {
                                showWriteSheet = false
                                reader.beginWriteNDEF(text: writeText) { ok, msg in
                                    toast = (ok ? "✓ " : "✗ ") + msg
                                }
                            }
                        }
                    }
                    .navigationTitle("写 NDEF 标签")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showWriteSheet = false }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 详情

struct CardDetailView: View {
    let card: CardDump
    @ObservedObject var emulator: CardEmulator
    @State private var dryInput = "00A4040007A0000000031010"
    @State private var dryOutput = ""

    var body: some View {
        List {
            Section("射频层") {
                row("类型", card.kind.display)
                row("UID", card.uid.isEmpty ? "—" : card.uid)
                if !card.atqa.isEmpty { row("ATQA", card.atqa) }
                if !card.sak.isEmpty  { row("SAK", card.sak) }
                if !card.ats.isEmpty  { row("ATS", card.ats) }
                if !card.historicalBytes.isEmpty { row("历史字节", card.historicalBytes) }
                row("最大传输", "\(card.maxTransceiveLength)")
            }

            Section("NDEF") {
                row("可写", card.ndefWritable ? "是" : "否")
                ForEach(Array(card.ndef.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TNF \(r.tnf) · \(r.type)").font(.caption).foregroundStyle(.secondary)
                        Text(r.payloadText ?? r.payloadHex)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if card.ndef.isEmpty { Text("无 NDEF 记录").foregroundStyle(.secondary) }
            }

            if !card.pages.isEmpty {
                Section("内存页 (\(card.pages.count))") {
                    ForEach(card.pages, id: \.index) { p in
                        HStack {
                            Text(String(format: "%03d", p.index))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(p.bytes)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !card.sectorDump.isEmpty {
                Section("扇区密钥 (\(card.sectorDump.count))") {
                    ForEach(card.sectorDump.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }, id: \.self) { k in
                        let t = card.sectorDump[k]!
                        VStack(alignment: .leading, spacing: 2) {
                            Text("扇区 \(k)").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text("A " + t.keyA).font(.system(.caption2, design: .monospaced))
                                Spacer()
                                Text(t.access).font(.system(.caption2, design: .monospaced))
                                Spacer()
                                Text("B " + t.keyB).font(.system(.caption2, design: .monospaced))
                            }
                            .foregroundStyle(t.isBlank ? .tertiary : .primary)
                            .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("APDU 抓包 (\(card.transcript.count))") {
                ForEach(card.transcript) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("→ \(r.request)")
                            .font(.system(.caption2, design: .monospaced))
                        Text("← \(r.response)  \(r.ok ? "✓" : "✗")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(r.ok ? Color.primary : Color.red)
                        if !r.note.isEmpty {
                            Text(r.note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if card.transcript.isEmpty { Text("没有 APDU 记录").foregroundStyle(.secondary) }
            }

            if card.kind == .iso14443A_MiFare && card.ndefReadLocked {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这张卡设了密码保护（NTAG PWD_AUTH）")
                            .font(.callout.weight(.medium))
                        Text("读用户区前需要先发 0x1B + 4 字节密码。密码存在 page 43/133/229，只有知道密码才能读到 PACK。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink("输入密码并读全卡") {
                        NTAGAuthView(card: card)
                    }
                } header: {
                    Text("加密卡")
                }
            }

            Section("回放") {
                Button(emulator.isEmulating ? "停止模拟" : "开始模拟") {
                    if emulator.isEmulating { emulator.stop() } else { emulator.start(card: card) }
                }
                Text(emulator.status).font(.caption).foregroundStyle(.secondary)

                TextField("APDU (hex)", text: $dryInput)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button("本地试跑") {
                    dryOutput = emulator.dryRun(dryInput)
                }
                if !dryOutput.isEmpty {
                    HStack {
                        Text("应答").foregroundStyle(.secondary)
                        Spacer()
                        Text(dryOutput)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Text("已服务 \(emulator.servedCount) 次").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(card.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}


// MARK: - NTAG 密码认证

struct NTAGAuthView: View {
    let card: CardDump

    @State private var pwdHex = ""
    @State private var packHex = ""
    @State private var result = ""
    @State private var pages: [MemoryPage] = []
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("密码（8 hex，4 字节）", text: $pwdHex)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("PACK（4 hex，可选）", text: $packHex)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("NTAG21x 密码")
            } footer: {
                Text("密码在配置页里，出厂空白卡是 00000000。PACK 填了会校验，不填则只看卡是否返回 ACK。")
            }

            Section {
                Button(busy ? "认证中…" : "认证并读全卡") {
                    authenticate()
                }
                .disabled(busy || pwdHex.count != 8)
            }

            if !result.isEmpty {
                Section("结果") {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(result.hasPrefix("✓") ? .primary : .red)
                }
            }

            if !pages.isEmpty {
                Section("读到 \(pages.count) 页") {
                    ForEach(pages, id: \.index) { p in
                        HStack {
                            Text(String(format: "%03d", p.index))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(p.bytes)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("密码认证")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func authenticate() {
        guard let pwd = Data(hex: pwdHex), pwd.count == 4 else {
            result = "✗ 密码要 8 位 hex"
            return
        }
        let pack: Data? = packHex.isEmpty ? nil : Data(hex: packHex)
        if !packHex.isEmpty, pack?.count != 2 {
            result = "✗ PACK 要 4 位 hex"
            return
        }

        busy = true
        result = ""

        let reader = NFCReader()
        reader.beginTask(alert: "把卡贴到 iPhone 顶部认证") { tag in
            try await reader.dumpNTAGWithPassword(tag: tag, pwd: pwd, pack: pack)
        } completion: { res in
            busy = false
            switch res {
            case .success(let card):
                pages = card.pages
                result = "✓ 认证通过，读到 \(card.pages.count) 页"
            case .failure(let err):
                result = "✗ \(err.localizedDescription)"
            }
        }
    }
}
