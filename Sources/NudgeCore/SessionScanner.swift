import Foundation

/// `~/.claude/sessions/<pid>.json` から稼働中の claude プロセスを拾い、会話ログから状態を判定する。
///
/// 対象外:
/// - pid が使い回されて別プロセスになっている json（procStart で照合）
/// - バックグラウンドジョブ（kind=bg）。ただし status=waiting なら入力待ちとして扱う
/// - 別セッションに引き継がれた会話（ログの末尾が continued-in で、後継のログが実在するもの）
public actor SessionScanner {
    let claudeDir: URL
    let ignore: IgnoreList
    let processes: any ProcessProvider
    /// 会話ログごとに読んだ位置を覚え、次からは伸びた分だけ読む
    private var logs: [URL: SessionLog] = [:]

    public init(claudeDir: URL, ignoreFile: URL, processes: any ProcessProvider = SystemProcesses()) {
        self.claudeDir = claudeDir
        ignore = IgnoreList(url: ignoreFile)
        self.processes = processes
    }

    public func scan() -> [Session] {
        let patterns = ignore.patterns()
        let files = (try? FileManager.default.contentsOfDirectory(at: claudeDir.appending(path: "sessions"), includingPropertiesForKeys: nil)) ?? []
        var sessions: [Session] = []
        var seen: Set<URL> = []
        for file in files where file.pathExtension == "json" {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent),
                  let proc = processes.snapshot(of: pid), proc.name.contains("claude"),
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  !record.sessionId.isEmpty, !record.cwd.isEmpty,
                  Self.sameProcess(procStart: record.procStart, start: proc.start)
            else { continue }
            let kind = record.kind ?? "interactive"
            // バックグラウンドジョブはジョブが終わってもデーモンがプロセスを抱えたままなので、
            // 生きていても人間が待っているとは限らない。本人が入力待ちを自己申告している時だけ拾う
            if kind == "bg", record.status != "waiting" { continue }

            let project = claudeDir.appending(path: "projects").appending(path: Self.projectName(record.cwd))
            let url = project.appending(path: "\(record.sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let log = logs[url] ?? SessionLog(url: url)
            log.refresh()
            logs[url] = log
            seen.insert(url)
            guard let last = log.last, let at = last.timestamp else { continue }
            // 引き継がれた会話はこの sid では二度と動かず、放置時間だけが伸び続ける。後継のログが実在する時だけ外す
            if last.type == "continued-in", !last.next.isEmpty,
               FileManager.default.fileExists(atPath: project.appending(path: "\(last.next).jsonl").path)
            {
                continue
            }

            let waiting = kind == "bg" || (last.type == "assistant" && (last.tools.isEmpty || last.tools.contains("AskUserQuestion")))
            let ignored = IgnoreList.match(patterns, sessionID: record.sessionId, cwd: record.cwd)
            sessions.append(Session(
                id: record.sessionId,
                pid: pid,
                cwd: record.cwd,
                kind: kind,
                status: record.status,
                title: log.title ?? (record.cwd as NSString).lastPathComponent,
                state: waiting ? .waiting : .running,
                lastAt: at,
                lastType: last.type,
                tools: last.tools,
                text: last.text,
                ignored: ignored.ignored,
                ignoredBySession: ignored.bySession
            ))
        }
        logs = logs.filter { seen.contains($0.key) }
        return sessions
    }

    /// 会話ログのディレクトリ名。作業ディレクトリの `/` と `.` を `-` にしたもの
    static func projectName(_ cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// json の procStart と実プロセスの起動時刻が一致するか。
    /// procStart は UTC 表記だが、ローカル表記になっても壊れないよう両方で照合する。判定できない時は対象に残す
    static func sameProcess(procStart: String?, start: Date) -> Bool {
        guard let procStart else { return true }
        let text = procStart.split(separator: " ").joined(separator: " ")
        let candidates = [TimeZone(identifier: "UTC")!, .current].compactMap { zone -> Date? in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return f.date(from: text)
        }
        guard !candidates.isEmpty else { return true }
        return candidates.contains { abs($0.timeIntervalSince(start)) <= 2 }
    }

    struct Record: Decodable {
        let sessionId: String
        let cwd: String
        let kind: String?
        let status: String?
        let procStart: String?
    }
}
