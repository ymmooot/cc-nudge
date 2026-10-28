import Foundation
import Testing

@testable import NudgeCore

struct FakeProcesses: ProcessProvider {
    var procs: [Int32: ProcessSnapshot]
    func snapshot(of pid: Int32) -> ProcessSnapshot? { procs[pid] }
}

let started = Date(timeIntervalSince1970: 1_793_159_671)
/// started を procStart の書式（UTC）にしたもの
let procStart = "Wed Oct 28 03:54:31 2026"
let cwd = "/Users/you/ghq/github.com/example/app.web"

/// 一時ディレクトリに ~/.claude の sessions と projects を作る
final class Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "cc-nudge-\(UUID().uuidString)")
    var procs: [Int32: ProcessSnapshot] = [:]

    var ignoreFile: URL { root.appending(path: "ignore") }
    var titleFile: URL { root.appending(path: "titles") }
    var project: URL { root.appending(path: "projects").appending(path: SessionScanner.projectName(cwd)) }

    init() {
        try! FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func session(pid: Int32, sid: String, kind: String = "interactive", status: String = "idle", procStart: String? = procStart, name: String = "claude", lines: [String]) {
        var json: [String: Any] = ["pid": pid, "sessionId": sid, "cwd": cwd, "kind": kind, "status": status]
        json["procStart"] = procStart
        try! JSONSerialization.data(withJSONObject: json).write(to: root.appending(path: "sessions/\(pid).json"))
        procs[pid] = ProcessSnapshot(name: name, start: started)
        write(sid: sid, lines: lines)
    }

    func write(sid: String, lines: [String]) {
        try! (lines.joined(separator: "\n") + "\n").write(to: project.appending(path: "\(sid).jsonl"), atomically: true, encoding: .utf8)
    }

    func append(sid: String, _ line: String) throws {
        let h = try FileHandle(forWritingTo: project.appending(path: "\(sid).jsonl"))
        try h.seekToEnd()
        try h.write(contentsOf: Data((line + "\n").utf8))
        try h.close()
    }

    func scanner() -> SessionScanner {
        SessionScanner(claudeDir: root, ignoreFile: ignoreFile, titleFile: titleFile, processes: FakeProcesses(procs: procs))
    }
}

func assistant(_ ts: String, text: String = "done", tools: [String] = [], sidechain: Bool = false) -> String {
    var content: [[String: Any]] = [["type": "text", "text": text]]
    content += tools.map { ["type": "tool_use", "name": $0, "input": [:]] }
    return line(["type": "assistant", "timestamp": ts, "isSidechain": sidechain, "message": ["role": "assistant", "content": content]])
}

func user(_ ts: String, _ text: String = "go") -> String {
    line(["type": "user", "timestamp": ts, "message": ["role": "user", "content": text]])
}

func line(_ obj: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
}

struct SessionScannerTests {
    @Test func assistantReplyWithoutToolsIsWaiting() async {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [user("2026-10-28T04:00:00.000Z"), assistant("2026-10-28T04:01:00.500Z", text: "line1\nline2")])
        let s = await f.scanner().scan()
        #expect(s.count == 1)
        #expect(s[0].state == .waiting)
        #expect(s[0].lastAt == Date(timeIntervalSince1970: 1_793_160_060.5))
        #expect(s[0].text == "line1 line2")
        #expect(s[0].title == "app.web")
    }

    @Test(arguments: [(["AskUserQuestion"], SessionState.waiting), (["Bash"], .running)])
    func toolUseDecidesState(tools: [String], want: SessionState) async {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [assistant("2026-10-28T04:01:00Z", tools: tools)])
        #expect(await f.scanner().scan().first?.state == want)
    }

    @Test func userMessageLastIsRunning() async {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [assistant("2026-10-28T04:00:00Z"), user("2026-10-28T04:01:00Z")])
        #expect(await f.scanner().scan().first?.state == .running)
    }

    @Test func sidechainMessagesAreSkipped() async {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [assistant("2026-10-28T04:00:00Z"), assistant("2026-10-28T04:05:00Z", tools: ["Bash"], sidechain: true)])
        let s = await f.scanner().scan()
        #expect(s.first?.state == .waiting)
        #expect(s.first?.lastAt == Date(timeIntervalSince1970: 1_793_160_000))
    }

    @Test func titleComesFromTheLastAiTitle() async {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [
            line(["type": "ai-title", "aiTitle": "古い題"]),
            line(["type": "ai-title", "aiTitle": "新しい題"]),
            assistant("2026-10-28T04:00:00Z"),
        ])
        #expect(await f.scanner().scan().first?.title == "新しい題")
    }

    @Test func customTitleOverridesTheDisplayOnly() async throws {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [line(["type": "ai-title", "aiTitle": "AI の題"]), assistant("2026-10-28T04:00:00Z")])
        try "s1 自分の題\n".write(to: f.titleFile, atomically: true, encoding: .utf8)
        let s = await f.scanner().scan()[0]
        #expect(s.title == "AI の題")
        #expect(s.customTitle == "自分の題")
        #expect(s.displayTitle == "自分の題")
    }

    @Test func deadOrOtherProcessesAreSkipped() async {
        let f = Fixture()
        f.session(pid: 1, sid: "dead", lines: [assistant("2026-10-28T04:00:00Z")])
        f.session(pid: 2, sid: "node", name: "node", lines: [assistant("2026-10-28T04:00:00Z")])
        f.procs[1] = nil
        #expect(await f.scanner().scan().isEmpty)
    }

    @Test func reusedPidIsSkipped() async {
        let f = Fixture()
        f.session(pid: 1, sid: "stale", procStart: "Mon Oct 26 03:54:31 2026", lines: [assistant("2026-10-28T04:00:00Z")])
        f.session(pid: 2, sid: "unknown", procStart: nil, lines: [assistant("2026-10-28T04:00:00Z")])
        f.session(pid: 3, sid: "unparsable", procStart: "yesterday", lines: [assistant("2026-10-28T04:00:00Z")])
        #expect(await f.scanner().scan().map(\.id).sorted() == ["unknown", "unparsable"])
    }

    @Test func procStartMayBeLocalTime() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        #expect(SessionScanner.sameProcess(procStart: f.string(from: started), start: started.addingTimeInterval(1)))
        #expect(SessionScanner.sameProcess(procStart: "Wed Oct  28 03:54:31 2026", start: started))
    }

    @Test func backgroundJobsCountOnlyWhenWaiting() async {
        let f = Fixture()
        f.session(pid: 1, sid: "busy", kind: "bg", status: "busy", lines: [assistant("2026-10-28T04:00:00Z")])
        f.session(pid: 2, sid: "waiting", kind: "bg", status: "waiting", lines: [assistant("2026-10-28T04:00:00Z", tools: ["Bash"])])
        let s = await f.scanner().scan()
        #expect(s.map(\.id) == ["waiting"])
        #expect(s.first?.state == .waiting)
    }

    @Test func continuedSessionIsSkippedOnlyWhenTheSuccessorExists() async {
        let f = Fixture()
        let handOff = line(["type": "continued-in", "timestamp": "2026-10-28T04:00:00Z", "continuedInSessionId": "next"])
        f.session(pid: 1, sid: "old", lines: [assistant("2026-10-28T03:00:00Z"), handOff])
        #expect(await f.scanner().scan().first?.state == .running)
        f.write(sid: "next", lines: [assistant("2026-10-28T04:00:00Z")])
        #expect(await f.scanner().scan().isEmpty)
    }

    @Test func ignoredSessionsAreKeptAndMarked() async throws {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [assistant("2026-10-28T04:00:00Z")])
        try "# 2026-10-28 一時中断 (app)\ns1  # 本人\n".write(to: f.ignoreFile, atomically: true, encoding: .utf8)
        var s = await f.scanner().scan()
        #expect(s.first?.ignored == true)
        #expect(s.first?.ignoredBySession == true)
        #expect(s.first?.isOverdue(at: .distantFuture, thresholds: Thresholds()) == false)

        try "example/app\n".write(to: f.ignoreFile, atomically: true, encoding: .utf8)
        s = await f.scanner().scan()
        #expect(s.first?.ignored == true)
        #expect(s.first?.ignoredBySession == false)
    }

    @Test func appendedLinesAreReadIncrementally() async throws {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [assistant("2026-10-28T04:00:00Z")])
        let scanner = f.scanner()
        #expect(await scanner.scan().first?.state == .waiting)

        try f.append(sid: "s1", user("2026-10-28T04:10:00Z"))
        #expect(await scanner.scan().first?.state == .running)

        // 改行が付く前の行も、JSON として閉じていれば読む
        let h = try FileHandle(forWritingTo: f.project.appending(path: "s1.jsonl"))
        try h.seekToEnd()
        try h.write(contentsOf: Data(assistant("2026-10-28T04:20:00Z").utf8))
        try h.close()
        #expect(await scanner.scan().first?.lastAt == Date(timeIntervalSince1970: 1_793_161_200))
    }

    @Test func halfWrittenLineWaitsForTheRest() async throws {
        let f = Fixture()
        f.session(pid: 1, sid: "s1", lines: [assistant("2026-10-28T04:00:00Z")])
        let scanner = f.scanner()
        _ = await scanner.scan()
        let full = user("2026-10-28T04:10:00Z")
        let h = try FileHandle(forWritingTo: f.project.appending(path: "s1.jsonl"))
        try h.seekToEnd()
        try h.write(contentsOf: Data(full.prefix(20).utf8))
        #expect(await scanner.scan().first?.state == .waiting)
        try h.write(contentsOf: Data((full.dropFirst(20) + "\n").utf8))
        try h.close()
        #expect(await scanner.scan().first?.state == .running)
    }

    @Test func thresholdsDependOnState() async {
        let f = Fixture()
        f.session(pid: 1, sid: "w", lines: [assistant("2026-10-28T04:00:00Z")])
        let s = await f.scanner().scan()[0]
        let t = Thresholds(idleMinutes: 15, stuckMinutes: 45)
        #expect(!s.isOverdue(at: s.lastAt.addingTimeInterval(14 * 60), thresholds: t))
        #expect(s.isOverdue(at: s.lastAt.addingTimeInterval(15 * 60), thresholds: t))
    }
}

struct IgnoreListTests {
    @Test func addThenRemoveRestoresTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ignore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "# 既存\n/some/dir"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let list = IgnoreList(url: url)

        try list.add(sessionID: "s1", reason: "パネルから除外", directoryName: "app", date: Date(timeIntervalSince1970: 1_793_160_000))
        #expect(try String(contentsOf: url, encoding: .utf8) == original + "\n# 2026-10-28 パネルから除外 (app)\ns1\n")
        #expect(list.patterns() == ["/some/dir", "s1"])

        try list.add(sessionID: "s1", reason: "二重", directoryName: "app")
        #expect(list.patterns() == ["/some/dir", "s1"])

        try list.remove(sessionID: "s1")
        #expect(try String(contentsOf: url, encoding: .utf8) == original + "\n")
    }
}

struct TitleListTests {
    @Test func setReplacesAndEmptyRemoves() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# 手書きのコメント\ns1   最初の題  \n".write(to: url, atomically: true, encoding: .utf8)
        let list = TitleList(url: url)
        #expect(list.titles() == ["s1": "最初の題"])

        try list.set(sessionID: "s2", title: " 二つ目 ")
        try list.set(sessionID: "s1", title: "書き換えた題")
        #expect(try String(contentsOf: url, encoding: .utf8) == "# 手書きのコメント\ns2 二つ目\ns1 書き換えた題\n")

        try list.set(sessionID: "s1", title: "  ")
        #expect(list.titles() == ["s2": "二つ目"])
    }

    @Test func missingFileHasNoTitles() {
        #expect(TitleList(url: URL(filePath: "/nonexistent/titles")).titles().isEmpty)
    }
}

struct ElapsedTests {
    @Test(arguments: [(59.0, "0分"), (14 * 60.0, "14分"), (90 * 60.0, "1時間"), (25 * 3600.0, "1日")])
    func text(interval: TimeInterval, want: String) {
        #expect(Elapsed.text(interval) == want)
    }
}
