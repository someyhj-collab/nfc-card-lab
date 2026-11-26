//
//  Crypto.swift
//  NFCCardLab
//
//  DESFire / NTAG 认证要用的密码学原语。
//  用 CommonCrypto（系统自带，不引第三方），AES-CBC / 3DES-CBC 都是硬件加速的。
//

import Foundation
import CommonCrypto

enum CryptoError: LocalizedError {
    case cryptFailed(Int32)
    case badKeyLength(Int)
    case badBlock

    var errorDescription: String? {
        switch self {
        case .cryptFailed(let s): return "加密失败 (CCCrypt status \(s))"
        case .badKeyLength(let n): return "密钥长度非法: \(n) 字节"
        case .badBlock: return "数据不是整块"
        }
    }
}

enum Crypto {

    // MARK: - AES-CBC（无填充，调用方保证整块）

    static func aesCBC(key: Data, iv: Data, data: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw CryptoError.badKeyLength(key.count)
        }
        guard data.count % kCCBlockSizeAES128 == 0 else { throw CryptoError.badBlock }

        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),                       // 无 padding
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, data.count,
                            outBuf.baseAddress, outBuf.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cryptFailed(status) }
        return out.prefix(moved)
    }

    /// 单块 ECB（DESFire 的 CBC 链起点用它）
    static func aesECBBlock(key: Data, block: Data) throws -> Data {
        try aesCBC(key: key, iv: Data(repeating: 0, count: 16), data: block, encrypt: true)
    }

    // MARK: - 3DES-CBC

    static func des3CBC(key: Data, iv: Data, data: Data, encrypt: Bool) throws -> Data {
        let k = key.count == 16 ? key + key.prefix(8) : key   // 2K3DES → 3K3DES
        guard k.count == 24 else { throw CryptoError.badKeyLength(key.count) }
        guard data.count % kCCBlockSize3DES == 0 else { throw CryptoError.badBlock }

        var out = Data(count: data.count + kCCBlockSize3DES)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            data.withUnsafeBytes { inBuf in
                k.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithm3DES),
                            CCOptions(0),
                            keyBuf.baseAddress, k.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, data.count,
                            outBuf.baseAddress, outBuf.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cryptFailed(status) }
        return out.prefix(moved)
    }

    // MARK: - CMAC（NIST SP 800-38B，AES-128）

    /// 左移一位，最高位溢出时异或 Rb
    private static func dbl(_ b: Data, rb: UInt8) -> Data {
        var out = Data(count: b.count)
        var carry: UInt8 = 0
        for i in stride(from: b.count - 1, through: 0, by: -1) {
            let v = b[b.startIndex + i]
            out[i] = (v << 1) | carry
            carry = (v & 0x80) != 0 ? 1 : 0
        }
        if carry == 1 { out[out.count - 1] ^= rb }
        return out
    }

    static func cmac(key: Data, message: Data) throws -> Data {
        let zero = Data(repeating: 0, count: 16)
        let L = try aesECBBlock(key: key, block: zero)
        let K1 = dbl(L, rb: 0x87)
        let K2 = dbl(K1, rb: 0x87)

        let blockCount = max(1, Int(ceil(Double(message.count) / 16.0)))
        let isComplete = message.count % 16 == 0 && message.count > 0

        var lastBlock: Data
        if isComplete {
            let start = message.count - 16
            lastBlock = xor(message.subdata(in: start..<message.count), K1)
        } else {
            let start = (blockCount - 1) * 16
            var tail = message.count > start ? message.subdata(in: start..<message.count) : Data()
            tail.append(0x80)
            while tail.count < 16 { tail.append(0) }
            lastBlock = xor(tail, K2)
        }

        var x = zero
        for i in 0..<(blockCount - 1) {
            let chunk = message.subdata(in: i * 16..<(i + 1) * 16)
            x = try aesECBBlock(key: key, block: xor(x, chunk))
        }
        return try aesECBBlock(key: key, block: xor(x, lastBlock))
    }

    static func xor(_ a: Data, _ b: Data) -> Data {
        let n = min(a.count, b.count)
        var out = Data(count: n)
        for i in 0..<n { out[i] = a[a.startIndex + i] ^ b[b.startIndex + i] }
        return out
    }

    /// 按块异或两条等长数据（DESFire 的 CBC 解密用）
    static func xorFull(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count, "长度不等")
        var out = Data(count: a.count)
        for i in 0..<a.count { out[i] = a[a.startIndex + i] ^ b[b.startIndex + i] }
        return out
    }

    /// 截断到 n 字节
    static func truncate(_ d: Data, _ n: Int) -> Data {
        d.count >= n ? d.prefix(n) : d + Data(repeating: 0, count: n - d.count)
    }
}
