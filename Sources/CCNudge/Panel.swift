import NudgeCore
import ServiceManagement
import SwiftUI

/// パネルに出すもの。アプリのタイマーで更新する
@MainActor @Observable
final class Model {
    var sessions: [Session] = []
    var now = Date()
    var thresholds = Thresholds()
    var loginEnabled = SMAppService.mainApp.status == .enabled
    /// 矢印の位置。パネルの左端から、メニューバーの項目の中央まで
    var arrowX: CGFloat = 20
    var refresh: () -> Void = {}
    var dismiss: () -> Void = {}
    /// タイトルを入力中のセッション ID
    var editing: String?
    let ignore: IgnoreList
    let titles: TitleList

    init(ignore: IgnoreList, titles: TitleList) {
        self.ignore = ignore
        self.titles = titles
    }

    /// 放置の長いものから
    private var sorted: [Session] { sessions.sorted { $0.lastAt < $1.lastAt } }
    var waiting: [Session] { sorted.filter { !$0.ignored && $0.state == .waiting } }
    var running: [Session] { sorted.filter { !$0.ignored && $0.state == .running } }
    var ignored: [Session] { sorted.filter(\.ignored) }
    var overdueCount: Int { sessions.count { $0.isOverdue(at: now, thresholds: thresholds) } }

    /// herdr でそのセッションのペインを開く
    func open(_ s: Session) {
        guard let script = Bundle.main.url(forResource: "open", withExtension: "sh") else { return }
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = [script.path, s.cwd, s.title, String(s.pid)]
        do {
            try p.run()
        } catch {
            NSLog("cc-nudge: open.sh: \(error)")
        }
        dismiss()
    }

    func toggleIgnore(_ s: Session) {
        do {
            if s.ignored {
                try ignore.remove(sessionID: s.id)
            } else {
                try ignore.add(sessionID: s.id, reason: "パネルから除外", directoryName: s.directoryName)
            }
        } catch {
            NSLog("cc-nudge: ignore: \(error)")
        }
        refresh()
    }

    /// 空なら Claude Code のタイトルに戻す
    func setTitle(_ s: Session, _ title: String) {
        editing = nil
        do {
            try titles.set(sessionID: s.id, title: title)
        } catch {
            NSLog("cc-nudge: titles: \(error)")
        }
        refresh()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("cc-nudge: login item: \(error)")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

/// 一覧の高さを行数から決める。ScrollView は fittingSize で潰れるので、収まらない時だけ高さを決めて包む
enum Layout {
    static let rowHeight: CGFloat = 44
    static let bellWidth: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    static let headerHeight: CGFloat = 16
    static let headerSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 12
    static let maxListHeight: CGFloat = 480

    static func height(_ sections: [[Session]]) -> CGFloat {
        let filled = sections.filter { !$0.isEmpty }
        let body = filled.map { rows in
            headerHeight + headerSpacing + CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * rowSpacing
        }
        return body.reduce(0, +) + CGFloat(max(filled.count - 1, 0)) * sectionSpacing
    }
}

struct Panel: View {
    let model: Model

    var body: some View {
        let sections = [("入力待ち", model.waiting), ("実行中", model.running), ("除外中", model.ignored)]
        VStack(alignment: .leading, spacing: 14) {
            if model.sessions.isEmpty {
                Text("稼働中のセッションはありません").foregroundStyle(.secondary)
            } else {
                let height = Layout.height(sections.map(\.1))
                let list = VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    ForEach(sections, id: \.0) { name, rows in
                        if !rows.isEmpty {
                            SessionSection(name: name, rows: rows, model: model)
                        }
                    }
                }
                if height > Layout.maxListHeight {
                    // マウスがつながっていると常時表示の太いスクロールバーになり、行の右端に被る
                    ScrollView { list }
                        .scrollIndicators(.never)
                        .frame(height: Layout.maxListHeight)
                } else {
                    list
                }
            }
            Divider()
            HStack {
                Toggle("ログイン時に起動", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 380)
        .background(.white)
        // Esc を受けるためにパネルをキーにすると、最初のボタンにフォーカスの枠が付く
        .focusEffectDisabled()
    }
}

struct SessionSection: View {
    let name: String
    let rows: [Session]
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            Text("\(name) \(rows.count)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(height: Layout.headerHeight)
            VStack(spacing: Layout.rowSpacing) {
                ForEach(rows) { s in
                    Row(session: s, model: model)
                }
            }
        }
    }
}

struct Row: View {
    let session: Session
    let model: Model
    @State var hovered = false

    var body: some View {
        let overdue = session.isOverdue(at: model.now, thresholds: model.thresholds)
        let editing = model.editing == session.id
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TitleField(session: session, model: model)
                } else {
                    Text(session.displayTitle).fontWeight(overdue ? .semibold : .regular).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Elapsed.text(session.idle(at: model.now)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(overdue ? Color.orange : .secondary)
                .padding(.trailing, 2)
            Button {
                model.toggleIgnore(session)
            } label: {
                // 押し損ねて行を押す（ペインが開く）ことのないよう、行の高さいっぱいを押せる範囲にする
                Image(systemName: session.ignored ? "bell.slash" : "bell")
                    .frame(width: Layout.bellWidth, height: Layout.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .foregroundStyle(.secondary)
            // ディレクトリのパターンで外れているものは、ignore を直さないと戻せない
            .disabled(session.ignored && !session.ignoredBySession)
            .help(session.ignored ? "監視に戻す" : "監視から外す")
        }
        .padding(.leading, 10)
        .frame(height: Layout.rowHeight)
        .background(fill(overdue), in: RoundedRectangle(cornerRadius: 2))
        .foregroundStyle(session.ignored ? .secondary : .primary)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            if !editing { model.open(session) }
        }
        .contextMenu {
            Button("タイトルを変更") { model.editing = session.id }
        }
    }

    var detail: String {
        let what: String
        if session.ignored {
            what = session.ignoredBySession ? "除外中" : "ディレクトリごと除外中"
        } else if session.state == .waiting {
            what = session.text.isEmpty ? "返答済み" : session.text
        } else {
            what = session.tools.isEmpty ? "処理中" : "ツール実行中: \(session.tools.joined(separator: ", "))"
        }
        return "\(session.directoryName) · \(what)"
    }

    func fill(_ overdue: Bool) -> Color {
        if overdue { return Color.orange.opacity(hovered ? 0.22 : 0.12) }
        return hovered ? Color.black.opacity(0.05) : .clear
    }
}

/// 行のタイトルをその場で書き換える入力欄。Enter で保存、Esc は main.swift のモニターが受けて取り消す
struct TitleField: View {
    let session: Session
    let model: Model
    @State var text = ""
    @FocusState var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(session.title))
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = session.displayTitle
                focused = true
            }
            .onSubmit { model.setTitle(session, text) }
    }
}

/// 矢印がメニューバーの項目を指す吹き出しの形に切り抜いたパネル
struct BubblePanel: View {
    static let arrowWidth: CGFloat = 16
    static let arrowHeight: CGFloat = 8

    let model: Model
    let cornerRadius: CGFloat

    var body: some View {
        Panel(model: model)
            .padding(.top, Self.arrowHeight)
            .background(.white)
            .clipShape(Bubble(arrowX: model.arrowX, arrowWidth: Self.arrowWidth, arrowHeight: Self.arrowHeight, cornerRadius: cornerRadius))
    }
}

struct Bubble: Shape {
    var arrowX: CGFloat
    let arrowWidth: CGFloat
    let arrowHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + arrowHeight
        let half = arrowWidth / 2
        // 矢印は角丸にかからない、上辺のまっすぐな部分に置く
        let x = min(max(arrowX, rect.minX + cornerRadius + half), rect.maxX - cornerRadius - half)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + cornerRadius, y: top))
        p.addLine(to: CGPoint(x: x - half, y: top))
        p.addLine(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x + half, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: cornerRadius)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: cornerRadius)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: top), radius: cornerRadius)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top), radius: cornerRadius)
        p.closeSubpath()
        return p
    }
}
