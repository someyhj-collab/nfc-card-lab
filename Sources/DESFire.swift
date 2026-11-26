//
//  DESFire.swift
//  NFCCardLab
//
//  MIFARE DESFire EV1/EV2 认证与读卡。
//
//  为什么 DESFire 能做而 Classic 不能：
//   · Classic 的 Crypto1 认证完全在硬件层，CoreNFC 不暴露任何加密原语，App 拿不到 key 也发不了认证帧。
//   · DESFire 是 ISO7816-4 应用，认证就是普通 APDU（0x90 Authenticate），
//     密钥算法是标准 AES / DES / 3DES，手机端用 CommonCrypto 就能算。
//     所以只要知道密钥，iPhone 上可以完整认证、读文件、甚至改密钥。
//
//  支持：
//   · AuthenticateEV2First (0x71) / AuthenticateISO (0x1A) / Authenticate (0x0A)
//   · AES-128 / 2K3DES / 3K3DES
//   · GetVersion / GetApplicationIDs / GetFileSettings / ReadData
//
//  不支持（需要 EV2 的 Secure Messaging 或厂商私有协议）：
//   · 认证后的加密通信（EV2 的 CmdCtr/IV 链）
//   · ChangeKey / 创建删除应用
//

import Foundation
import Security

enum DESFireError: LocalizedError {
    case badResponse(String)
    case authFailed(String)
    case unsupportedKeyType

    var errorDescription: String? {
        switch self {
        case .badResponse(let s): return "DESFire 响应异常: \(s)"
        case .authFailed(let s): return "认证失败: \(s)"
        case .unsupportedKeyType: return "不支持的密钥类型"
        }
    }
}

/// DESFire 原生指令码（ISO7816 包装成 90 INS 00 00）
enum DFIns: UInt8 {
    case authenticateLegacy = 0x0A   // 3DES / DES，单轮
    case authenticateISO    = 0x1A   // 2K3DES / 3K3DES
    case authenticateEV2    = 0x71   // AES / EV2
    case getVersion         = 0x60
    case getApplicationIDs  = 0x6A
    case getFileIDs         = 0x6F
    case getFileSettings    = 0xF5
    case readData           = 0xBD
    case additionalFrame    = 0xAF
}

struct DESFireVersion {
    var hwVendor: String = ""
    var hwType: String = ""
    var hwVersion: String = ""
    var swVendor: String = ""
    var swType: String = ""
    var swVersion: String = ""
    var uid: String = ""
    var batchNo: String = ""
    var productionWeek: String = ""
    var productionYear: String = ""

    var description: String {
        "HW \(hwVendor)/\(hwType)/\(hwVersion) · SW \(swVendor)/\(swType)/\(swVersion) · UID \(uid)"
    }
}

/// 会话状态：认证成功后保存，后续读文件要用
struct DESFireSession {
    var keyNo: UInt8 = 0
    var algorithm: KeyAlgorithm = .aes128
    var sessionKey: Data = Data()
    var iv: Data = Data()
    var authenticated = false
}

enum KeyAlgorithm {
    case aes128
    case des2k
    case des3k

    var blockSize: Int { self == .aes128 ? 16 : 8 }
    var keyLength: Int { self == .aes128 ? 16 : (self == .des2k ? 16 : 24) }
    var label: String {
        switch self {
        case .aes128: return "AES-128"
        case .des2k:  return "2K3DES"
        case .des3k:  return "3K3DES"
        }
    }
}

// MARK: - 会话驱动

/// 需要外部提供「发一条原生指令」的通道。
/// App 里接 NFCReader.sendRaw，PC 侧脚本里接 pyscard / nfcpy。
protocol DESFireTransport {
    /// 发 90 INS 00 00 [Lc] [data] 00，返回 (data, sw1sw2)
    func transceive(ins: UInt8, data: Data) throws -> (Data, UInt16)
}

final class DESFireClient {

    let transport: DESFireTransport
    private(set) var session = DESFireSession()
    /// 每次认证/读写的完整交互，落到 CardDump.transcript
    private(set) var transcript: [APDURecord] = []

    init(transport: DESFireTransport) {
        self.transport = transport
    }

    private func send(_ ins: UInt8, _ data: Data = Data(), note: String = "") throws -> Data {
        guard data.count <= 255 else {
            throw DESFireError.badResponse("数据超过 255 字节，需分帧")
        }
        let apdu = Data([0x90, ins, 0x00, 0x00, UInt8(data.count)]) + data + Data([0x00])
        let (resp, sw) = try transport.transceive(ins: ins, data: data)
        transcript.append(APDURecord(request: apdu.hex,
                                     response: resp.hex + String(format: "%04X", sw),
                                     note: note))
        guard sw == 0x9000 || sw == 0x9100 else {
            throw DESFireError.badResponse(String(format: "SW=%04X", sw))
        }
        return resp
    }

    // MARK: 基本信息

    func getVersion() throws -> DESFireVersion {
        let first = try send(DFIns.getVersion.rawValue, note: "GetVersion")
        var v = DESFireVersion()
        guard first.count >= 7 else { return v }
        v.hwVendor = first[0..<1].hex
        v.hwType = first[1..<2].hex
        v.hwVersion = first[2..<4].hex
        v.swVendor = first[4..<5].hex
        v.swType = first[5..<6].hex
        v.swVersion = first[6..<7].hex

        // 后续帧
        for _ in 0..<2 {
            if let more = try? send(DFIns.additionalFrame.rawValue, note: "AdditionalFrame") {
                if more.count >= 7 && v.uid.isEmpty {
                    v.batchNo = more[0..<5].hex
                    v.productionWeek = String(format: "%02X", more[5])
                    v.productionYear = String(format: "%02X", more[6])
                } else if more.count >= 7 {
                    v.uid = more[0..<7].hex
                }
            }
        }
        return v
    }

    func getApplicationIDs() throws -> [UInt32] {
        let r = try send(DFIns.getApplicationIDs.rawValue, note: "GetApplicationIDs")
        var out: [UInt32] = []
        for i in stride(from: 0, to: r.count - 2, by: 3) {
            let a = UInt32(r[i]) | (UInt32(r[i + 1]) << 8) | (UInt32(r[i + 2]) << 16)
            out.append(a)
        }
        return out
    }

    func getFileIDs(appID: UInt32) throws -> [UInt8] {
        try selectApplication(appID)
        return Array(try send(DFIns.getFileIDs.rawValue, note: "GetFileIDs"))
    }

    func selectApplication(_ appID: UInt32) throws {
        let d = Data([UInt8(appID & 0xFF),
                      UInt8((appID >> 8) & 0xFF),
                      UInt8((appID >> 16) & 0xFF)])
        _ = try send(0x5A, d, note: "SelectApplication")
    }

    // MARK: 认证

    /// 用指定密钥认证。key 必须是 keyLength 字节。
    func authenticate(keyNo: UInt8, key: Data, algorithm: KeyAlgorithm) throws {
        guard key.count == algorithm.keyLength else {
            throw DESFireError.unsupportedKeyType
        }

        switch algorithm {
        case .aes128:
            try authenticateEV2(keyNo: keyNo, key: key)
        case .des2k, .des3k:
            try authenticateISO(keyNo: keyNo, key: key, algorithm: algorithm)
        }
    }

    /// AES 认证（AuthenticateEV2First，0x71）
    private func authenticateEV2(keyNo: UInt8, key: Data) throws {
        // 1) 发 0x71，卡回 16 字节 E(Kx, RndB)
        let encRndB = try send(DFIns.authenticateEV2.rawValue, Data([keyNo]),
                               note: "AuthenticateEV2 key#\(keyNo)")
        guard encRndB.count == 16 else {
            throw DESFireError.authFailed("RndB 长度 \(encRndB.count)")
        }

        // 2) 解密得 RndB，左移一字节得 RndB'
        let rndB = try Crypto.aesCBC(key: key, iv: Data(repeating: 0, count: 16),
                                     data: encRndB, encrypt: false)
        let rndBp = rotateLeft(rndB)

        // 3) 生成 RndA，拼 RndA || RndB'，加密回卡
        let rndA = randomBytes(16)
        let plain = rndA + rndBp
        let enc = try Crypto.aesCBC(key: key, iv: encRndB, data: plain, encrypt: true)

        let resp = try send(DFIns.authenticateEV2.rawValue, enc, note: "AuthEV2 part2")
        guard resp.count == 16 else {
            throw DESFireError.authFailed("应答长度 \(resp.count)")
        }

        // 4) 解密应答得 RndA'，校验
        let decResp = try Crypto.aesCBC(key: key, iv: Data(repeating: 0, count: 16),
                                        data: resp, encrypt: false)
        let expectRndAp = rotateLeft(rndA)
        guard decResp == expectRndAp else {
            throw DESFireError.authFailed("RndA' 校验失败（密钥不对）")
        }

        // 5) 会话密钥（EV1 兼容派生；EV2 严格模式用 CMAC，见 deriveEV2SessionKey）
        let sv1 = Data([0xA5, 0x5A, 0x00, 0x00, 0x00, 0x00, keyNo,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let sessionKey = try deriveAESSessionKey(master: key, sv1: sv1, rndA: rndA)
        session = DESFireSession(keyNo: keyNo, algorithm: .aes128,
                                 sessionKey: sessionKey, iv: Data(repeating: 0, count: 16),
                                 authenticated: true)
    }

    /// 3DES 认证（AuthenticateISO，0x1A）
    private func authenticateISO(keyNo: UInt8, key: Data, algorithm: KeyAlgorithm) throws {
        let bs = algorithm.blockSize
        let encRndB = try send(DFIns.authenticateISO.rawValue, Data([keyNo]),
                               note: "AuthenticateISO key#\(keyNo)")
        guard encRndB.count == bs else {
            throw DESFireError.authFailed("RndB 长度 \(encRndB.count)")
        }

        let rndB = try Crypto.des3CBC(key: key, iv: Data(repeating: 0, count: bs),
                                      data: encRndB, encrypt: false)
        let rndBp = rotateLeft(rndB)
        let rndA = randomBytes(bs)
        let enc = try Crypto.des3CBC(key: key, iv: encRndB, data: rndA + rndBp, encrypt: true)
        let resp = try send(DFIns.authenticateISO.rawValue, enc, note: "AuthISO part2")

        let decResp = try Crypto.des3CBC(key: key, iv: Data(repeating: 0, count: bs),
                                         data: resp, encrypt: false)
        guard decResp == rotateLeft(rndA) else {
            throw DESFireError.authFailed("RndA' 校验失败（密钥不对）")
        }

        var sv1 = Data([0xA5, 0x5A, 0x00, 0x00, 0x00, 0x00, keyNo])
        sv1.append(Data(repeating: 0, count: max(0, bs - sv1.count)))
        let seed = Crypto.xorFull(Crypto.truncate(sv1, bs), Crypto.truncate(rndA, bs))
                 + Crypto.xorFull(Crypto.truncate(sv1, bs), Crypto.truncate(rotateLeft(rndA), bs))
        let sk = try Crypto.des3CBC(key: key, iv: Data(repeating: 0, count: bs),
                                    data: seed, encrypt: true)

        session = DESFireSession(keyNo: keyNo, algorithm: algorithm,
                                 sessionKey: sk, iv: Data(repeating: 0, count: bs),
                                 authenticated: true)
    }

    /// EV1 兼容的 AES 会话密钥派生：
    ///   SEED = (sv1 ⊕ RndA) || (sv1 ⊕ RndA')
    ///   SK   = AES-CBC(K, IV=0, SEED)[0..16]
    private func deriveAESSessionKey(master: Data, sv1: Data, rndA: Data) throws -> Data {
        let rndAPrime = rotateLeft(rndA)
        let seed = Crypto.xorFull(Crypto.truncate(sv1, 16), Crypto.truncate(rndA, 16))
                 + Crypto.xorFull(Crypto.truncate(sv1, 16), Crypto.truncate(rndAPrime, 16))
        let enc = try Crypto.aesCBC(key: master, iv: Data(repeating: 0, count: 16),
                                    data: seed, encrypt: true)
        return Crypto.truncate(enc, 16)
    }

    /// EV2 严格模式的 CMAC 派生（EV2 卡 + 开了 EV2 模式才用）
    func deriveEV2SessionKey(master: Data, keyNo: UInt8, rndA: Data) throws -> Data {
        var sv2 = Data([0xA5, 0x5A, 0x00, 0x00, 0x00, 0x00, keyNo])
        sv2.append(Data(repeating: 0, count: 9))
        let rndAPrime = rotateLeft(rndA)
        let msg = Crypto.xorFull(Crypto.truncate(sv2, 16), Crypto.truncate(rndA, 16))
                + Crypto.xorFull(Crypto.truncate(sv2, 16), Crypto.truncate(rndAPrime, 16))
        return try Crypto.cmac(key: master, message: msg)
    }

    // MARK: 读数据

    func readData(fileNo: UInt8, offset: Int = 0, length: Int = 32) throws -> Data {
        guard session.authenticated else {
            throw DESFireError.authFailed("还没认证")
        }
        var d = Data([fileNo])
        d.append(UInt8(offset & 0xFF))
        d.append(UInt8((offset >> 8) & 0xFF))
        d.append(UInt8((offset >> 16) & 0xFF))
        d.append(UInt8(length & 0xFF))
        d.append(UInt8((length >> 8) & 0xFF))
        d.append(UInt8((length >> 16) & 0xFF))
        return try send(DFIns.readData.rawValue, d, note: "ReadData file#\(fileNo)")
    }

    // MARK: 工具

    private func rotateLeft(_ d: Data) -> Data {
        guard !d.isEmpty else { return d }
        var out = d.dropFirst()
        out.append(d.first!)
        return out
    }

    private func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, n, buf.baseAddress!)
        }
        return d
    }
}

// MARK: - 把 CoreNFC 的 ISO7816 通道接成 DESFireTransport

import CoreNFC

final class ISO7816Transport: DESFireTransport {
    private let tag: NFCISO7816Tag
    var onRecord: ((APDURecord) -> Void)?

    init(tag: NFCISO7816Tag) { self.tag = tag }

    func transceive(ins: UInt8, data: Data) throws -> (Data, UInt16) {
        let apduData = Data([0x90, ins, 0x00, 0x00, UInt8(data.count)]) + data + Data([0x00])
        guard let apdu = NFCISO7816APDU(data: apduData) else {
            throw DESFireError.badResponse("APDU 构造失败")
        }
        var result: (Data, UInt16)?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        tag.sendCommand(apdu: apdu) { payload, sw1, sw2, error in
            if let error { failure = error }
            else { result = (payload, (UInt16(sw1) << 8) | UInt16(sw2)) }
            sem.signal()
        }
        sem.wait()
        if let failure { throw failure }
        guard let result else { throw DESFireError.badResponse("无响应") }
        return result
    }
}
