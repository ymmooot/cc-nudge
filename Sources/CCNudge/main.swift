import AppKit
import NudgeCore
import ServiceManagement
import SwiftUI

let tick: TimeInterval = 10
let cornerRadius: CGFloat = 3
/// メニューバーとパネルの間
let gap: CGFloat = 2
let escape: UInt16 = 53

let home = FileManager.default.homeDirectoryForCurrentUser
let ignoreFile = home.appending(path: ".claude/cc-nudge/ignore")
let titleFile = home.appending(path: ".claude/cc-nudge/titles")
let scanner = SessionScanner(claudeDir: home.appending(path: ".claude"), ignoreFile: ignoreFile, titleFile: titleFile)

/// `defaults write com.ymmooot.cc-nudge idleMinutes 20` のように変えられる
func loadThresholds() -> Thresholds {
    let d = UserDefaults.standard
    return Thresholds(idleMinutes: d.integer(forKey: "idleMinutes").nonZero ?? 15, stuckMinutes: d.integer(forKey: "stuckMinutes").nonZero ?? 45)
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// 枠・矢印・角丸をシステムが描く NSPopover の代わりに、縁なしのパネルを使う
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = Model(ignore: IgnoreList(url: ignoreFile), titles: TitleList(url: titleFile))
    let window = PanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    var monitors: [Any] = []
    var timer: Timer?
    var scanning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // パネルは白で作っているので、ダークモードに追従させない
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: BubblePanel(model: model, cornerRadius: cornerRadius))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        model.refresh = { [weak self] in self?.update() }
        model.dismiss = { [weak self] in self?.close() }
        render()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { _ in
            MainActor.assumeIsolated { self.update() }
        }
    }

    @objc func toggle() {
        window.isVisible ? close() : open()
    }

    func open() {
        update()
        model.loginEnabled = SMAppService.mainApp.status == .enabled
        place()
        window.makeKeyAndOrderFront(nil)
        // キーになると最初のボタンが選ばれ、フォーカスの枠が付く
        window.makeFirstResponder(nil)
        // ほかのアプリでのクリックはグローバルモニターにしか来ない。メニューバーの項目のクリックは toggle に来る
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { self.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == escape {
                MainActor.assumeIsolated {
                    // タイトルの入力中なら、パネルは閉じずに入力だけやめる
                    if self.model.editing != nil {
                        self.model.editing = nil
                    } else {
                        self.close()
                    }
                }
                return nil
            }
            return event
        } as Any)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        model.editing = nil
        window.orderOut(nil)
    }

    /// パネルをメニューバーの項目の下に、中身の大きさで画面からはみ出さないように置く
    func place() {
        guard let button = item.button, let buttonWindow = button.window, let content = window.contentView else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = content.fittingSize
        var x = anchor.minX
        if let screen = buttonWindow.screen?.visibleFrame {
            x = min(max(x, screen.minX + gap), screen.maxX - size.width - gap)
        }
        model.arrowX = anchor.midX - x
        window.setFrame(NSRect(x: x, y: anchor.minY - gap - size.height, width: size.width, height: size.height), display: true)
        window.invalidateShadow()
    }

    func update() {
        guard !scanning else { return }
        scanning = true
        Task {
            let sessions = await scanner.scan()
            scanning = false
            model.now = Date()
            model.thresholds = loadThresholds()
            model.sessions = sessions
            render()
        }
    }

    func render() {
        let overdue = model.overdueCount
        if overdue > 0 {
            // メニューバーのボタンは contentTintColor を無視して黒く描くので、色は画像と文字に焼き込む
            let orange = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            let image = NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: "放置中のセッション")?.withSymbolConfiguration(orange)
            image?.isTemplate = false
            item.button?.image = image
            item.button?.attributedTitle = NSAttributedString(string: "\(overdue)", attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.menuBarFont(ofSize: 0),
            ])
        } else {
            let image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Claude Code のセッション")
            // テンプレートにして、メニューバーの明暗に合わせて白黒を切り替えさせる
            image?.isTemplate = true
            item.button?.image = image
            item.button?.attributedTitle = NSAttributedString(string: "")
        }
        if window.isVisible {
            // 行の増減でパネルの高さが、件数の表示でメニューバーの項目の幅が変わる
            place()
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--check" {
    // 判定のドライラン。/cc-nudge スキルの check から使う
    Task {
        let now = Date()
        let thresholds = loadThresholds()
        for s in await scanner.scan().sorted(by: { $0.lastAt < $1.lastAt }) {
            let idle = Int(s.idle(at: now) / 60)
            if s.ignored {
                print("IGNORED idle=\(idle)m sid=\(s.id) [\(s.displayTitle)] cwd=\(s.cwd)")
            } else {
                let overdue = s.isOverdue(at: now, thresholds: thresholds) ? " OVERDUE" : ""
                print("\(s.state.rawValue) idle=\(idle)m\(overdue) sid=\(s.id) [\(s.displayTitle)] last=\(s.lastType) tools=\(s.tools.joined(separator: ",")) kind=\(s.kind) status=\(s.status ?? "?")")
            }
        }
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
