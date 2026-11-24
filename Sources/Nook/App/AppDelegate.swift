import AppKit
import SwiftUI

@main
enum NookMain {
    static func main() {
        let app = NSApplication.shared
        if MainActor.assumeIsolated({ Snapshot.runIfRequested() }) { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private let notch = NotchWindowController()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        notch.start()
        setupStatusItem()
        startModules()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HUDController.shared.stop()
        NowPlayingModel.shared.stop()
        NotesStore.shared.flush()
        TasksStore.shared.flush()
        notch.stop()
    }

    /// Starts background monitors according to preferences. Safe to call repeatedly.
    func startModules() {
        let d = UserDefaults.standard
        if d.bool(forKey: Pref.nowPlaying) { NowPlayingModel.shared.start() } else { NowPlayingModel.shared.stop() }
        if d.bool(forKey: Pref.battery) { BatteryMonitor.shared.start() } else { BatteryMonitor.shared.stop() }
        if d.bool(forKey: Pref.hud) { HUDController.shared.start() } else { HUDController.shared.stop() }
        if d.bool(forKey: Pref.reminders) { RemindersModel.shared.start() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Nook")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Nook")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Nook", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openNotch() { NookState.shared.open() }

    @objc func openSettings() {
        NookState.shared.close()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Nook Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
