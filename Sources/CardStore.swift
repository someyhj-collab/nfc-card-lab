//
//  CardStore.swift
//  NFCCardLab
//
//  卡片库：Documents/cards/*.json。一个文件一张卡，便于 AirDrop / 导出给 PC 侧分析。
//

import Foundation
import Combine

final class CardStore: ObservableObject {
    @Published private(set) var cards: [CardDump] = []

    private let dir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 日期兼容
    // 本 App 写的是带毫秒的 ISO8601，PC 侧脚本写的是不带毫秒的，
    // JSONDecoder.iso8601 不认小数秒，所以自己解。

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601DateFormatter 只认 3 位小数秒；PC 侧 Python 可能写 6 位微秒，
    /// 所以先把小数部分规整成 3 位再解析。
    private static func parseDate(_ s: String) -> Date? {
        if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d }

        guard let dot = s.firstIndex(of: ".") else { return nil }
        let tail = s[s.index(after: dot)...]
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let frac = String(digits)
        let milli = frac.count >= 3 ? String(frac.prefix(3))
                                    : frac + String(repeating: "0", count: 3 - frac.count)
        let rest = tail.dropFirst(digits.count)
        let rebuilt = String(s[..<dot]) + "." + milli + String(rest)
        return withFraction.date(from: rebuilt) ?? plain.date(from: rebuilt)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = CardStore.parseDate(s) else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "无法解析日期: \(s)")
            }
            return date
        }
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(CardStore.withFraction.string(from: date))
        }
        return e
    }

    // MARK: - 读写

    func load() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let dec = decoder
        cards = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> CardDump? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                return try? dec.decode(CardDump.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ card: CardDump) -> URL? {
        guard let data = try? encoder.encode(card) else { return nil }
        let url = dir.appendingPathComponent("\(card.id.uuidString).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        load()
        return url
    }

    func delete(_ card: CardDump) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(card.id.uuidString).json"))
        load()
    }

    func fileURL(for card: CardDump) -> URL {
        dir.appendingPathComponent("\(card.id.uuidString).json")
    }

    /// 卡片库目录，用于 iTunes 文件共享 / Xcode 拖入
    var directoryURL: URL { dir }
}
