//
//  PageScript.swift
//  NFCCardLab
//
//  解析 pages.txt（由 PC 侧 tools/ntag_build.py 生成）：
//    页号  4字节hex
//    4  0314D101
//  也接受纯 hex 行，按出现顺序自动编号。
//

import Foundation

enum PageScript {

    static func parse(_ text: String) -> [(index: Int, hex: String)] {
        var out: [(Int, String)] = []
        var auto = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            line = line.replacingOccurrences(of: ":", with: " ")
                       .replacingOccurrences(of: "=", with: " ")
                       .replacingOccurrences(of: "0x", with: " ")
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .map(String.init)
                .filter { !$0.isEmpty }

            var idx: Int
            var hex: String

            if fields.count >= 2 {
                guard let n = Int(fields[0]) else { continue }
                idx = n
                hex = fields[1]
            } else if fields.count == 1 {
                idx = auto
                hex = fields[0]
            } else {
                continue
            }
            auto = idx + 1

            hex = hex.uppercased()
            guard hex.count == 8, hex.allSatisfy({ $0.isHexDigit }) else { continue }
            out.append((idx, hex))
        }

        // 去重（后写的覆盖先写的），按页号排序
        var dict: [Int: String] = [:]
        for (i, h) in out { dict[i] = h }
        return dict.sorted { $0.key < $1.key }.map { (index: $0.key, hex: $0.value) }
    }
}
