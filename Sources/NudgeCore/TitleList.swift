import Foundation

/// `~/.claude/cc-nudge/titles`。パネルで付け替えたタイトル。1 行 1 セッションで、session-id の後ろに空白を挟んでタイトルを書く
public struct TitleList: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func titles() -> [String: String] {
        var result: [String: String] = [:]
        for line in lines() {
            guard let (id, title) = Self.parse(line) else { continue }
            result[id] = title
        }
        return result
    }

    /// 空のタイトルは行ごと消す（Claude Code のタイトルに戻る）
    public func set(sessionID: String, title: String) throws {
        var all = lines()
        if all.last == "" { all.removeLast() }
        all.removeAll { Self.parse($0)?.id == sessionID }
        let title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { all.append("\(sessionID) \(title)") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (all.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func parse(_ line: String) -> (id: String, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
    }

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }
}
