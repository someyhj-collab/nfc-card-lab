//
//  Models.swift
//  NFCCardLab
//
//  卡片数据模型。所有抓到的内容都落成 CardDump，可导出 JSON / 供 HCE 回放。
//

import Foundation

// MARK: - 标签类型

enum TagKind: String, Codable, CaseIterable {
    case iso14443A_MiFare      // MIFare Classic / Ultralight / NTAG / Plus / DESFire
    case iso7816               // 银行卡、身份证、SIM、门禁 CPU 卡
    case iso15693              // ICODE、NFC-V 标签
    case felica                // 交通卡（Suica / 八达通）
    case unknown

    var display: String {
        switch self {
        case .iso14443A_MiFare: return "ISO14443-A / MiFare"
        case .iso7816:          return "ISO7816 (CPU 卡)"
        case .iso15693:         return "ISO15693 (NFC-V)"
        case .felica:           return "FeliCa"
        case .unknown:          return "未知"
        }
    }
}

// MARK: - 一次 APDU 往返

struct APDURecord: Codable, Identifiable, Hashable {
    var id: UUID
    var request: String          // hex，不含空格
    var response: String         // hex，含 SW1SW2
    var note: String

    var sw: String { String(response.suffix(4)) }
    var ok: Bool { response.hasSuffix("9000") }

    init(request: String, response: String, note: String = "") {
        self.id = UUID()
        self.request = request
        self.response = response
        self.note = note
    }

    // PC 侧生成的 JSON 没有 id / note，缺了就补默认值
    private enum CodingKeys: String, CodingKey { case id, request, response, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        request = try c.decodeIfPresent(String.self, forKey: .request) ?? ""
        response = try c.decodeIfPresent(String.self, forKey: .response) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

// MARK: - MiFare 内存页

struct MemoryPage: Codable, Hashable {
    var index: Int
    var bytes: String            // 4 字节 hex（Ultralight）或 16 字节（Classic 块）
    var locked: Bool = false

    init(index: Int, bytes: String, locked: Bool = false) {
        self.index = index; self.bytes = bytes; self.locked = locked
    }

    private enum CodingKeys: String, CodingKey { case index, bytes, locked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        bytes = try c.decodeIfPresent(String.self, forKey: .bytes) ?? ""
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}

// MARK: - 一张卡

struct CardDump: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var label: String = "未命名卡片"

    // 射频层
    var kind: TagKind = .unknown
    var uid: String = ""                 // hex
    var atqa: String = ""                // hex，2 字节
    var sak: String = ""                 // hex，1 字节
    var historicalBytes: String = ""     // hex
    var ats: String = ""                 // ISO14443-4 ATS，hex
    var maxTransceiveLength: Int = 0

    // 应用层
    var ndef: [NDEFRecordDump] = []
    var ndefWritable: Bool = false
    var pages: [MemoryPage] = []         // Ultralight / NTAG 页 dump
    var transcript: [APDURecord] = []    // 全部 APDU 往返，HCE 回放用

    var sectorDump: [String: SectorTrailer] = [:]   // Classic：扇区尾块（keyA/AC/keyB）

    // DESFire：版本、应用、认证结果
    var desfireVersion: String = ""
    var applications: [String] = []
    var authLog: [String] = []          // 每次尝试的算法/key# /结果
    var ndefReadLocked: Bool = false    // NTAG 设了密码且未认证

    var summary: String {
        let uidText = uid.isEmpty ? "无 UID" : uid
        return "\(kind.display) · \(uidText)"
    }

    init() {}

    init(label: String) { self.label = label }
}

extension CardDump {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, label, kind, uid, atqa, sak, historicalBytes, ats,
             maxTransceiveLength, ndef, ndefWritable, pages, transcript, sectorDump,
             desfireVersion, applications, authLog, ndefReadLocked
    }

    /// PC 侧生成的 JSON 可能缺字段，全部按可选读，缺了用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "未命名卡片"
        kind = try c.decodeIfPresent(TagKind.self, forKey: .kind) ?? .unknown
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        atqa = try c.decodeIfPresent(String.self, forKey: .atqa) ?? ""
        sak = try c.decodeIfPresent(String.self, forKey: .sak) ?? ""
        historicalBytes = try c.decodeIfPresent(String.self, forKey: .historicalBytes) ?? ""
        ats = try c.decodeIfPresent(String.self, forKey: .ats) ?? ""
        maxTransceiveLength = try c.decodeIfPresent(Int.self, forKey: .maxTransceiveLength) ?? 0
        ndef = try c.decodeIfPresent([NDEFRecordDump].self, forKey: .ndef) ?? []
        ndefWritable = try c.decodeIfPresent(Bool.self, forKey: .ndefWritable) ?? false
        pages = try c.decodeIfPresent([MemoryPage].self, forKey: .pages) ?? []
        transcript = try c.decodeIfPresent([APDURecord].self, forKey: .transcript) ?? []
        sectorDump = try c.decodeIfPresent([String: SectorTrailer].self, forKey: .sectorDump) ?? [:]
        desfireVersion = try c.decodeIfPresent(String.self, forKey: .desfireVersion) ?? ""
        applications = try c.decodeIfPresent([String].self, forKey: .applications) ?? []
        authLog = try c.decodeIfPresent([String].self, forKey: .authLog) ?? []
        ndefReadLocked = try c.decodeIfPresent(Bool.self, forKey: .ndefReadLocked) ?? false
    }
}

struct SectorTrailer: Codable, Hashable {
    var keyA: String
    var access: String
    var keyB: String

    var isBlank: Bool { keyA == "000000000000" && keyB == "000000000000" }
}

struct NDEFRecordDump: Codable, Hashable {
    var tnf: UInt8
    var type: String            // 文本化
    var payloadHex: String
    var payloadText: String?
}
