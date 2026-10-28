import Foundation

/// `~/.claude/cc-nudge/ignore`。1 行 1 パターンで、セッション ID なら完全一致、それ以外は作業ディレクトリの部分一致で外す
public struct IgnoreList: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func patterns() -> [String] {
        lines().compactMap { line in
            let pattern = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public static func match(_ patterns: [String], sessionID: String, cwd: String) -> (ignored: Bool, bySession: Bool) {
        let bySession = patterns.contains(sessionID)
        return (bySession || patterns.contains { cwd.contains($0) }, bySession)
    }

    /// スキルと同じく、パターン行の直前に `# YYYY-MM-DD <理由> (<ディレクトリ名>)` を置く
    public func add(sessionID: String, reason: String, directoryName: String, date: Date = Date()) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !text.split(separator: "\n").contains(where: { $0 == sessionID }) else { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        text += "# \(day) \(reason) (\(directoryName))\n\(sessionID)\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// パターン行と、その直前の日付コメント行を消す
    public func remove(sessionID: String) throws {
        var all = lines()
        guard let i = all.firstIndex(of: sessionID) else { return }
        var range = i...i
        if i > 0, all[i - 1].wholeMatch(of: /# \d{4}-\d{2}-\d{2} .*/) != nil {
            range = (i - 1)...i
        }
        all.removeSubrange(range)
        try all.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }
}
