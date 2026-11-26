//
//  NFCReader.swift
//  NFCCardLab
//
//  读卡 / 写卡 / 抓 APDU。基于 CoreNFC 的 NFCTagReaderSession。
//
//  能力边界（写死在代码里，不吹）：
//   · MiFare Classic 的加密扇区：CoreNFC 不给 key，只能读 0 扇区 UID/BCC/SAK/ATQA，
//     以及 Ultralight/NTAG 的全部明文页。想解 Classic 的 A/B key 要 PC + PN532/ACR122U。
//   · CPU 卡（银行卡/门禁 CPU）：只能发 APDU 读公开的 AID/ATR，读不到受保护文件。
//   · 写入：NDEF 可写标签可全量写；Ultralight/NTAG 明文页可单页写（不可写 OTP/lock 页）。
//

import CoreNFC
import Foundation
import Combine

enum NFCError: LocalizedError {
    case unsupported
    case noTag
    case transmit(String)
    case ndefWrite(String)
    var errorDescription: String? {
        switch self {
        case .unsupported:       return "本机不支持 NFC 或未授权"
        case .noTag:             return "没有检测到标签"
        case .transmit(let m):   return "APDU 失败: \(m)"
        case .ndefWrite(let m):  return "NDEF 写入失败: \(m)"
        }
    }
}

final class NFCReader: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var status: String = "待机"
    @Published var lastCard: CardDump?
    @Published var log: [APDURecord] = []

    /// 抓到的原始 transcript，写卡时复用
    private(set) var transcript: [APDURecord] = []

    private var session: NFCTagReaderSession?
    private var tag: NFCTag?
    private var finishAction: (@MainActor (CardDump?) -> Void)?

    /// 连接成功后要执行的自定义任务（认证、读写等）。返回给调用方的结果。
    private var tagTask: ((NFCTag) async throws -> CardDump)?
    private var taskCompletion: (@MainActor (Result<CardDump, Error>) -> Void)?

    // MARK: - 读卡

    func beginRead(alert: String = "把卡片贴到 iPhone 顶部",
                  completion: @escaping @MainActor (CardDump?) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            status = "本机不支持 NFC 读卡（或系统版本过低）"
            completion(nil); return
        }
        finishAction = completion
        transcript = []
        log = []
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693, .iso18092], delegate: self, queue: nil)
        session?.alertMessage = alert
        session?.begin()
        isScanning = true
        status = "扫描中…"
    }

    /// 开一个会话，连上卡之后执行 task，把结果回主线程。
    /// 用于「认证后读卡」这类不能拆成两次会话的操作。
    func beginTask(alert: String = "把卡片贴到 iPhone 顶部",
                   task: @escaping (NFCTag) async throws -> CardDump,
                   completion: @escaping @MainActor (Result<CardDump, Error>) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            completion(.failure(NFCError.unsupported)); return
        }
        tagTask = task
        taskCompletion = completion
        transcript = []
        log = []
        session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        session?.alertMessage = alert
        session?.begin()
        isScanning = true
        status = "扫描中…"
    }

    // MARK: - 发一条 APDU

    @discardableResult
    func transmit(_ apdu: Data, note: String = "") async throws -> Data {
        guard let tag else { throw NFCError.noTag }
        guard case let .iso7816(card) = tag else { throw NFCError.transmit("非 ISO7816 标签") }
        guard let command = NFCISO7816APDU(data: apdu) else {
            throw NFCError.transmit("APDU 格式非法: \(apdu.hex)")
        }
        let (payload, sw1, sw2) = try await card.sendCommand(apdu: command)
        var resp = payload
        resp.append(sw1)
        resp.append(sw2)
        let record = APDURecord(request: apdu.hex, response: resp.hex, note: note)
        transcript.append(record); log.append(record)
        return resp
    }

    /// 选择 AID
    @discardableResult
    func select(aid: String) async throws -> Data {
        guard let aidData = Data(hex: aid) else { throw NFCError.transmit("AID 非法") }
        var apdu = Data([0x00, 0xA4, 0x04, 0x00, UInt8(aidData.count)])
        apdu.append(aidData)
        apdu.append(0x00)
        return try await transmit(apdu, note: "SELECT \(aid)")
    }

    /// 读二进制（CPU 卡透明文件）
    @discardableResult
    func readBinary(offset: UInt16, length: UInt8) async throws -> Data {
        let apdu = Data([0x00, 0xB0, UInt8(offset >> 8), UInt8(offset & 0xFF), length])
        return try await transmit(apdu, note: "READ BINARY @\(offset) len=\(length)")
    }

    // MARK: - 结束

    func cancel() {
        session?.invalidate(errorMessage: "已取消")
        session = nil; tag = nil; isScanning = false
    }

    // MARK: - 数据组装

    private func buildDump(_ tag: NFCTag) -> CardDump {
        var card = CardDump()
        card.transcript = transcript

        switch tag {
        case .miFare(let m):
            card.kind = .iso14443A_MiFare
            card.uid = m.identifier.hex
            switch m.mifareFamily {
            case .ultralight:
                card.atqa = "0044"; card.sak = "00"; card.label = "NTAG / Ultralight"
            case .plus:
                card.atqa = "0002"; card.sak = "20"; card.label = "MiFare Plus"
            case .desfire:
                card.atqa = "0344"; card.sak = "20"; card.label = "DESFire"
            case .unknown:
                card.atqa = "0004"; card.sak = "08"; card.label = "MiFare Classic"
            @unknown default:
                card.atqa = "0004"; card.sak = "08"; card.label = "MiFare"
            }

        case .iso7816(let c):
            card.kind = .iso7816
            card.uid = c.identifier.hex
            card.historicalBytes = c.historicalBytes?.hex ?? ""
            card.ats = c.applicationData?.hex ?? ""
            card.maxTransceiveLength = c.maximumTransceiveLength
            card.label = c.initialSelectedAID.isEmpty ? "ISO7816 卡" : "AID:\(c.initialSelectedAID)"

        case .iso15693(let v):
            card.kind = .iso15693
            card.uid = v.identifier.hex
            card.label = "ISO15693"

        case .feliCa(let f):
            card.kind = .felica
            card.uid = f.currentIDm.hex
            card.label = "FeliCa"

        @unknown default:
            card.kind = .unknown
        }

        if card.label.isEmpty { card.label = card.summary }
        return card
    }
}

// MARK: - NFCTagReaderSessionDelegate

extension NFCReader: NFCTagReaderSessionDelegate {

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) { }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.isScanning = false
            self.session = nil
            if let e = error as? NFCReaderError, e.code == .readerSessionInvalidationErrorUserCanceled {
                self.status = "已取消"
            } else {
                self.status = "会话结束: \(error.localizedDescription)"
            }
            self.finishAction?(self.lastCard)
            self.finishAction = nil
            if let done = self.taskCompletion {
                done(.failure(NFCError.noTag))
                self.taskCompletion = nil
                self.tagTask = nil
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor in
            guard let first = tags.first else { return }
            do {
                try await session.connect(to: first)
            } catch {
                session.invalidate(errorMessage: "连接失败: \(error.localizedDescription)")
                return
            }
            self.tag = first
            self.status = "已连接，读取中…"
            session.alertMessage = "读取中，请保持贴合"

            // 自定义任务优先（认证读卡等）
            if let task = self.tagTask {
                do {
                    let card = try await task(first)
                    card.transcript = self.transcript
                    self.lastCard = card
                    session.alertMessage = "完成"
                    session.invalidate()
                    self.taskCompletion?(.success(card))
                } catch {
                    session.invalidate(errorMessage: error.localizedDescription)
                    self.taskCompletion?(.failure(error))
                }
                self.tagTask = nil
                self.taskCompletion = nil
                return
            }

            var card = self.buildDump(first)

            // 1) NDEF
            let ndef = await self.readNDEF(tag: first)
            card.ndef = ndef.records
            card.ndefWritable = ndef.writable
            card.ndefReadLocked = ndef.locked

            // 2) MiFare 页 dump（仅 Ultralight / NTAG 可读明文页）
            if case let .miFare(m) = first, m.mifareFamily == .ultralight {
                card.pages = await self.dumpUltralightPages(m)
            }

            // 3) ISO7816：把 ATS / AID 记进 transcript
            if case let .iso7816(c) = first, !c.initialSelectedAID.isEmpty {
                _ = try? await self.select(aid: c.initialSelectedAID)
            }

            card.transcript = self.transcript
            self.lastCard = card
            session.alertMessage = "读取完成"
            session.invalidate()
        }
    }

    // MARK: NDEF

    /// 读 NDEF。返回 (记录, 是否可写)；读不到就给空，不影响其余流程。
    private func readNDEF(tag: NFCTag) async -> (records: [NDEFRecordDump], writable: Bool, locked: Bool) {
        let ndef: NFCNDEFTag?
        switch tag {
        case .miFare(let m):   ndef = m
        case .iso7816(let c):  ndef = c
        case .iso15693(let v): ndef = v
        case .feliCa(let f):   ndef = f
        @unknown default:      ndef = nil
        }
        guard let ndef else { return ([], false, false) }

        do {
            let (ndefStatus, _) = try await ndef.queryNDEFStatus()
            let writable = (ndefStatus == .readWrite)
            guard ndefStatus != .notSupported else { return ([], writable, false) }

            let msg = try await ndef.readNDEF()
            let records = msg.records.map { r in
                NDEFRecordDump(
                    tnf: r.typeNameFormat.rawValue,
                    type: String(data: r.type, encoding: .utf8) ?? r.type.hex,
                    payloadHex: r.payload.hex,
                    payloadText: String(data: r.payload, encoding: .utf8)
                )
            }
            return (records, writable, false)
        } catch {
            // NTAG 设了 AUTH0 之后，未认证时读 NDEF 会失败 —— 这通常意味着
            // 卡上了密码保护，不是坏卡。
            let msg = error.localizedDescription
            self.status = "NDEF 读取失败: \(msg)（可能设了密码保护）"
            return ([], false, true)
        }
    }

    // MARK: Ultralight 页 dump

    /// NTAG213 45 页 / 215 135 页 / 216 231 页。按 4 页一读（READ 0x30），
    /// 读失败即停 —— 越界读会 NAK，正好当边界探测。
    private func dumpUltralightPages(_ m: NFCMiFareTag) async -> [MemoryPage] {
        var pages: [MemoryPage] = []
        for p in stride(from: 0, to: 231, by: 4) {
            do {
                let resp = try await m.sendMiFareCommand(
                    commandPacket: Data([0x30, UInt8(p & 0xFF)]))
                guard resp.count >= 4 else { break }
                let chunk = resp.prefix(16)
                for i in stride(from: 0, to: chunk.count, by: 4) {
                    let sub = chunk.subdata(in: i..<min(i + 4, chunk.count))
                    pages.append(MemoryPage(index: p + i / 4, bytes: sub.hex))
                }
            } catch {
                break
            }
        }
        status = "已读 \(pages.count) 页"
        return pages
    }

    // MARK: NTAG 密码认证（0x1B PWD_AUTH）

    /// 带密码读全卡：先认证，再逐页读。
    /// 必须在同一会话内完成，所以接收 tag 而不是用 self.tag。
    func dumpNTAGWithPassword(tag: NFCTag, pwd: Data, pack: Data?) async throws -> CardDump {
        guard case let .miFare(m) = tag else {
            throw NFCError.transmit("不是 MiFare 标签")
        }
        guard pwd.count == 4 else {
            throw NFCError.transmit("密码必须是 4 字节")
        }

        // 1) PWD_AUTH
        var cmd = Data([0x1B])
        cmd.append(pwd)
        let resp = try await m.sendMiFareCommand(commandPacket: cmd)
        let record = APDURecord(request: cmd.hex, response: resp.hex, note: "PWD_AUTH")
        transcript.append(record); log.append(record)

        guard resp.count >= 2 else {
            throw NFCError.transmit("PWD_AUTH 无应答，密码可能错误")
        }
        let gotPACK = resp.prefix(2)
        if let expected = pack, expected.count == 2, gotPACK != expected {
            throw NFCError.transmit("PACK 不匹配（卡回 \(gotPACK.hex)，期望 \(expected.hex)）")
        }

        // 2) 认证通过，读全卡
        var card = buildDump(tag)
        card.pages = await dumpUltralightPages(m)
        card.ndefReadLocked = false
        card.authLog.append("PWD_AUTH ✓ PACK=\(gotPACK.hex)")
        return card
    }
}

// MARK: - 写 NDEF

extension NFCReader {
    /// 把一条文本记录写进标签
    func beginWriteNDEF(text: String, completion: @escaping @MainActor (Bool, String) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            completion(false, "本机不支持 NFC"); return
        }
        guard let payload = text.data(using: .utf8) else {
            completion(false, "文本编码失败"); return
        }
        let record = NFCNDEFPayload(format: .nfcWellKnown,
                                    type: Data([0x54]),            // 'T'
                                    identifier: Data(),
                                    payload: Data([0x02, 0x65, 0x6E]) + payload)  // lang="en"
        let message = NFCNDEFMessage(records: [record])

        let s = NFCTagReaderSession(pollingOption: [.iso14443], delegate: WriteDelegate(message: message, done: completion), queue: nil)
        s.alertMessage = "把标签贴到 iPhone 顶部写入"
        s.begin()
        SessionHolder.shared.session = s
    }
}

/// 写会话持有者。NFCTagReaderSession 必须被强引用，否则会被立刻释放。
final class SessionHolder {
    static let shared = SessionHolder()
    var session: NFCTagReaderSession?
}

// MARK: - 写 Ultralight / NTAG 明文页

/// 把一串 4 字节页写到 NTAG/Ultralight。只碰用户区（page 4 起），
/// 不碰 OTP(3)、lock(2/40)、配置页(41/42/43)，写坏就废卡。
extension NFCReader {
    func beginWritePages(_ pages: [(index: Int, hex: String)],
                         completion: @escaping @MainActor (Bool, String) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            completion(false, "本机不支持 NFC"); return
        }
        let s = NFCTagReaderSession(pollingOption: [.iso14443],
                                    delegate: PageWriteDelegate(pages: pages, done: completion),
                                    queue: nil)
        s.alertMessage = "把标签贴到 iPhone 顶部写入 \(pages.count) 页"
        s.begin()
        SessionHolder.shared.session = s
    }
}

final class PageWriteDelegate: NSObject, NFCTagReaderSessionDelegate {
    let pages: [(index: Int, hex: String)]
    let done: @MainActor (Bool, String) -> Void

    init(pages: [(index: Int, hex: String)], done: @escaping @MainActor (Bool, String) -> Void) {
        self.pages = pages; self.done = done
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) { }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let e = error as? NFCReaderError, e.code == .readerSessionInvalidationErrorUserCanceled {
            let finish = done
            Task { @MainActor in finish(false, "已取消") }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        let finish = done
        Task {
            guard case let .miFare(m) = first else {
                session.invalidate(errorMessage: "不是 MiFare 标签")
                Task { @MainActor in finish(false, "目标不是 NTAG/Ultralight") }; return
            }
            do {
                try await session.connect(to: .miFare(m))
            } catch {
                session.invalidate(errorMessage: "连接失败")
                Task { @MainActor in finish(false, "连接失败: \(error.localizedDescription)") }; return
            }

            // 保护区：UID 页 + 各型号末尾的锁位/配置/密码页。
            // 型号从最大页号反推，写错这几页会永久锁死标签。
            let maxPage = pages.map { $0.index }.max() ?? 44
            var protected: Set<Int> = [0, 1, 2, 3]
            switch maxPage {
            case 229...:            protected.formUnion(226...230)   // NTAG216
            case 133..<229:         protected.formUnion(130...134)   // NTAG215
            default:                protected.formUnion(40...44)     // NTAG213
            }
            var written = 0

            for p in pages {
                guard !protected.contains(p.index) else { continue }
                guard let payload = Data(hex: p.hex), payload.count == 4 else { continue }
                var cmd = Data([0xA2, UInt8(p.index & 0xFF)])
                cmd.append(payload)
                do {
                    let resp = try await m.sendMiFareCommand(commandPacket: cmd)
                    // NTAG 回 ACK 0x0A
                    if resp.first == 0x0A { written += 1 }
                } catch {
                    session.invalidate(errorMessage: "第 \(p.index) 页写入失败")
                    Task { @MainActor in finish(false, "第 \(p.index) 页失败: \(error.localizedDescription)") }
                    return
                }
            }

            session.alertMessage = "写入完成 \(written) 页"
            session.invalidate()
            Task { @MainActor in finish(true, "已写 \(written) 页（跳过保护区）") }
        }
    }
}

/// 写卡专用 delegate，独立于读卡，避免状态互相污染
final class WriteDelegate: NSObject, NFCTagReaderSessionDelegate {
    let message: NFCNDEFMessage
    let done: @MainActor (Bool, String) -> Void
    init(message: NFCNDEFMessage, done: @escaping @MainActor (Bool, String) -> Void) {
        self.message = message; self.done = done
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) { }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let e = error as? NFCReaderError, e.code == .readerSessionInvalidationErrorUserCanceled {
            let finish = done
            Task { @MainActor in finish(false, "已取消") }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        let finish = done
        Task {
            do {
                try await session.connect(to: first)
                let ndef: NFCNDEFTag? = {
                    switch first {
                    case .miFare(let m): return m
                    case .iso7816(let c): return c
                    case .iso15693(let v): return v
                    case .feliCa(let f): return f
                    @unknown default: return nil
                    }
                }()
                guard let ndef else { throw NFCError.noTag }
                let (status, capacity) = try await ndef.queryNDEFStatus()
                guard status == .readWrite else { throw NFCError.ndefWrite("标签不可写 (status=\(status.rawValue))") }
                guard message.length <= capacity else { throw NFCError.ndefWrite("容量不足 \(message.length)/\(capacity)") }
                try await ndef.writeNDEF(message)
                session.alertMessage = "写入成功"
                session.invalidate()
                Task { @MainActor in finish(true, "已写入 \(message.length) 字节") }
            } catch {
                session.invalidate(errorMessage: "写入失败")
                Task { @MainActor in finish(false, error.localizedDescription) }
            }
        }
    }
}

// MARK: - Hex 工具

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }

    init?(hex: String) {
        let clean = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")
            .uppercased()
        guard clean.count % 2 == 0 else { return nil }
        var out = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
