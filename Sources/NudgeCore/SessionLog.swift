import Foundation

/// 会話ログの、判定に使う最後のメッセージ
struct LogMessage: Equatable {
    let type: String
    let timestamp: Date?
    /// continued-in の引き継ぎ先 session-id
    let next: String
    let tools: [String]
    let text: String
}

/// 会話ログ 1 本を、伸びた分だけ読み足して最後のメッセージとタイトルを持つ
final class SessionLog {
    /// 初回に最後のメッセージを探す範囲。数十 MB のログの全行を JSON として読まないよう、末尾のこの行数までにする
    static let tailLines = 300
    static let relevantTypes: Set<String> = ["user", "assistant", "continued-in"]
    static let titleMarker = Data("\"ai-title\"".utf8)
    static let newline = UInt8(ascii: "\n")

    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private(set) var last: LogMessage?
    private(set) var title: String?

    init(url: URL) {
        self.url = url
    }

    func refresh() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {
            // 作り直されたログは最初から読む
            offset = 0
            partial = Data()
            last = nil
            title = nil
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        let initial = offset == 0
        offset += UInt64(data.count)

        var chunk = partial + data
        partial = Data()
        if let end = chunk.lastIndex(of: Self.newline) {
            // 改行の後ろは書き途中のこともあるので持ち越す。ただし JSON として閉じていれば最後の行として読む
            let rest = chunk[chunk.index(after: end)...]
            if !rest.isEmpty, (try? JSONSerialization.jsonObject(with: rest)) == nil {
                partial = Data(rest)
                chunk = chunk[..<end]
            }
        } else if (try? JSONSerialization.jsonObject(with: chunk)) == nil {
            partial = chunk
            return
        }
        let lines = chunk.split(separator: Self.newline)
        if initial {
            loadInitial(lines)
        } else {
            lines.forEach(consume)
        }
    }

    private func loadInitial(_ lines: [Data.SubSequence]) {
        for (i, line) in lines.reversed().enumerated() {
            if last == nil, i < Self.tailLines, let m = Self.message(line) {
                last = m
            }
            if title == nil, let t = Self.title(line) {
                title = t
            }
            if title != nil, last != nil || i >= Self.tailLines { break }
        }
    }

    private func consume(_ line: Data.SubSequence) {
        if let t = Self.title(line) { title = t }
        if let m = Self.message(line) { last = m }
    }

    static func title(_ line: Data.SubSequence) -> String? {
        guard line.range(of: titleMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let t = obj["aiTitle"] as? String, !t.isEmpty
        else { return nil }
        return t
    }

    static func message(_ line: Data.SubSequence) -> LogMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String, relevantTypes.contains(type),
              obj["isSidechain"] as? Bool != true
        else { return nil }
        let content = (obj["message"] as? [String: Any])?["content"]
        let items = (content as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let tools = items.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
        let text = (content as? String) ?? items.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
        return LogMessage(
            type: type,
            timestamp: (obj["timestamp"] as? String).flatMap(parseTimestamp),
            next: obj["continuedInSessionId"] as? String ?? "",
            tools: tools,
            text: String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        )
    }

    static func parseTimestamp(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}
