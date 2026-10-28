import Darwin
import Foundation

public struct ProcessSnapshot: Sendable, Equatable {
    public let name: String
    public let start: Date

    public init(name: String, start: Date) {
        self.name = name
        self.start = start
    }
}

public protocol ProcessProvider: Sendable {
    /// pid のプロセスが無ければ nil
    func snapshot(of pid: Int32) -> ProcessSnapshot?
}

public struct SystemProcesses: ProcessProvider {
    public init() {}

    public func snapshot(of pid: Int32) -> ProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // 存在しない pid でも sysctl は成功し、size が 0 で返る
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // Claude Code の実行ファイルは versions/2.1.312 のような名前なので、p_comm ではなく ps と同じ argv[0] を見る
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = Self.argv0(of: pid) ?? comm
        let t = info.kp_proc.p_starttime
        return ProcessSnapshot(name: name, start: Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000))
    }

    /// KERN_PROCARGS2 は argc (Int32)、実行ファイルのパス、詰め物の NUL、argv[0] の順に並ぶ
    static func argv0(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        var rest = buf[MemoryLayout<Int32>.size ..< size].drop { $0 != 0 }.drop { $0 == 0 }
        rest = rest.prefix { $0 != 0 }
        return rest.isEmpty ? nil : String(decoding: rest, as: UTF8.self)
    }
}
