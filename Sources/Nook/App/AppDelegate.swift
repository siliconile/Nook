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
    private var updateItem: NSMenuItem?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.migrateLegacyDefaults()
        Pref.registerDefaults()
        installEditMenu()
        notch.start()
        setupStatusItem()
        startModules()
        Updater.shared.startAutomaticChecks()
        // Debug aid: `Nook --self-update` installs the latest release without asking.
        if CommandLine.arguments.contains("--self-update") {
            Task {
                await Updater.shared.check(userInitiated: false)
                Updater.shared.installAvailable()
            }
        }
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

    /// Accessory apps have no menu bar, so Cmd+A/C/V/X/Z have nothing to route through.
    /// A (never shown) main menu with an Edit menu makes the standard shortcuts work in
    /// Notes, Tasks and every text field.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Nook")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Nook")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: String(localized: "Open Nook"), action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "About Nook"), action: #selector(showAbout), keyEquivalent: "").target = self
        let update = menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        updateItem = update
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Nook"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openNotch() { NookState.shared.open() }

    @objc private func checkForUpdates() {
        if Updater.shared.available != nil {
            Updater.shared.installAvailable()
        } else {
            Task { await Updater.shared.check(userInitiated: true) }
        }
    }

    /// Reflects an available update in the menu-bar menu.
    func updateMenuChanged() {
        updateItem?.isEnabled = !Updater.shared.isInstalling
        if Updater.shared.isInstalling {
            updateItem?.title = String(localized: "Updating…")
        } else if let v = Updater.shared.available?.version {
            updateItem?.title = String(localized: "Update Nook to \(v)")
        } else {
            updateItem?.title = String(localized: "Check for Updates…")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: String(localized: "Free and open source (MIT).\ngithub.com/siliconile/Nook")),
        ])
    }

    @objc func openSettings() {
        NookState.shared.close()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = String(localized: "Nook Settings")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
