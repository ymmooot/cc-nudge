import Foundation

public enum SessionState: String, Sendable {
    /// 最後が Claude の返答で tool_use が無い（または AskUserQuestion）。こちらの入力待ち
    case waiting = "WAITING"
    /// それ以外。ツール実行中・思考中・許可プロンプト待ちの可能性
    case running = "RUNNING"
}

/// 稼働中の Claude Code セッション 1 つの判定結果
public struct Session: Sendable, Equatable, Identifiable {
    /// session-id（会話ログ `<session-id>.jsonl` の名前）
    public let id: String
    public let pid: Int32
    public let cwd: String
    public let kind: String
    public let status: String?
    public let title: String
    public let state: SessionState
    public let lastAt: Date
    public let lastType: String
    public let tools: [String]
    public let text: String
    public let ignored: Bool
    /// ignore にセッション ID で載っている。ディレクトリのパターンで外れているものはパネルから戻せない
    public let ignoredBySession: Bool

    public var directoryName: String { (cwd as NSString).lastPathComponent }

    public func idle(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(lastAt))
    }

    public func isOverdue(at now: Date, thresholds: Thresholds) -> Bool {
        !ignored && idle(at: now) >= thresholds.limit(for: state)
    }
}

public struct Thresholds: Sendable, Equatable {
    public var idle: TimeInterval
    public var stuck: TimeInterval

    public init(idleMinutes: Int = 15, stuckMinutes: Int = 45) {
        idle = TimeInterval(idleMinutes * 60)
        stuck = TimeInterval(stuckMinutes * 60)
    }

    public func limit(for state: SessionState) -> TimeInterval {
        state == .waiting ? idle : stuck
    }
}

public enum Elapsed {
    /// 放置時間をパネル用に丸める（`12分`、`3時間`、`2日`）
    public static func text(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)分" }
        if minutes < 24 * 60 { return "\(minutes / 60)時間" }
        return "\(minutes / (24 * 60))日"
    }
}
