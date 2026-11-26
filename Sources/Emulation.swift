//
//  Emulation.swift
//  NFCCardLab
//
//  卡片回放 / 模拟（HCE）。
//
//  ⚠️ 真实前提（这是硬门槛，绕不过）：
//   1. iOS 上第三方 App 做「卡模拟」只能用 Apple 的 NFC & SE Platform（HCE）能力，
//      需要向 Apple 单独申请 entitlement：com.apple.developer.nfc.hce
//      免费 Apple ID / 普通付费账号都拿不到，必须走 Apple 的申请表单审批。
//   2. 拿到后还要在 Info.plist 里声明 AID 列表，Apple 只放行 ISO7816 的 APDU 应答，
//      不支持 14443-3 层的 UID 伪装 —— 也就是「复制门禁卡的 UID」这件事，
//      在 iPhone 上物理上做不到。UID 是芯片在防冲突阶段回的，App 层碰不到。
//
//  所以本文件提供的是：
//   · 一个可编译的空实现（默认关闭，不申请 entitlement 也能构建）
//   · 拿到 entitlement 后要填的那层桥接协议，签名和数据流已经定好
//   · 基于 CardDump.transcript 的 APDU 应答表，HCE 侧直接查表回包
//

import Foundation
import Combine

// MARK: - 编译开关

/// 只有拿到 com.apple.developer.nfc.hce 并在 Xcode 里打开这个 flag，才会编进真实现。
/// 未打开时整个模块退化为本地回放演示，不影响其余功能。
// 真实现要 import Apple 的 NFC & SE Platform 框架（拿到 entitlement 后
// Apple 会在开发者后台给你这个 SDK）。未获批前不要写死 import，否则编不过。
#if HCE_ENABLED
// import NFCReaderSession   // ← 换成 Apple 给的实际模块名
#endif

// MARK: - 应答表

/// 从抓包 transcript 里建出来的 APDU 应答表。
/// key = 完整 APDU 的 hex（含 CLA/INS/P1/P2/Lc/Data/Le）
struct APDUResponder {

    private var table: [String: String] = [:]

    /// 前缀匹配用：只比 INS + P1 + P2 的粗粒度规则
    private var prefixRules: [(String, String)] = []

    init(transcript: [APDURecord]) {
        for r in transcript where !r.request.isEmpty {
            table[r.request.uppercased()] = r.response.uppercased()
        }
    }

    /// 加一条通配规则，比如 SELECT AID 之后所有 READ BINARY 都回同一段
    mutating func addRule(prefix: String, response: String) {
        prefixRules.append((prefix.uppercased(), response.uppercased()))
    }

    func respond(to apdu: Data) -> Data? {
        let key = apdu.hex.uppercased()
        if let exact = table[key], let d = Data(hex: exact) { return d }

        for (p, r) in prefixRules where key.hasPrefix(p) {
            if let d = Data(hex: r) { return d }
        }
        return nil
    }

    /// 默认回 6A82 (File not found)
    func respondOrDefault(to apdu: Data) -> Data {
        respond(to: apdu) ?? Data([0x6A, 0x82])
    }

    var ruleCount: Int { table.count + prefixRules.count }
}

// MARK: - 模拟会话

final class CardEmulator: ObservableObject {

    @Published var isEmulating = false
    @Published var status = "未启动"
    @Published var servedCount = 0

    private var responder: APDUResponder?

    /// 从一张卡开始模拟
    func start(card: CardDump) {
        responder = APDUResponder(transcript: card.transcript)
        guard let r = responder, r.ruleCount > 0 else {
            status = "这张卡没有抓到 APDU，无法回放"
            return
        }

        #if HCE_ENABLED
        // ── 拿到 entitlement 后在这里接真实会话 ────────────────────────
        // let session = NFCHCESession(aids: card.declaredAIDs)
        // session.onAPDU = { [weak self] apdu in
        //     self?.servedCount += 1
        //     return self?.responder?.respondOrDefault(to: apdu) ?? Data([0x6A, 0x82])
        // }
        // session.begin()
        // self.hceSession = session
        status = "模拟中（\(r.ruleCount) 条规则）"
        isEmulating = true
        #else
        status = "本地回放模式：\(r.ruleCount) 条 APDU 规则已装载，真机模拟需 NFC & SE Platform entitlement"
        isEmulating = true
        #endif
    }

    func stop() {
        #if HCE_ENABLED
        // hceSession?.invalidate()
        // hceSession = nil
        #endif
        isEmulating = false
        status = "已停止"
        servedCount = 0
    }

    /// 本地自测：喂一条 APDU 看回什么，不涉及硬件
    func dryRun(_ apduHex: String) -> String {
        guard let d = Data(hex: apduHex), let r = responder else { return "无规则" }
        servedCount += 1
        return r.respondOrDefault(to: d).hex
    }
}
