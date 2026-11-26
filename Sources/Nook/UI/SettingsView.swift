import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.nowPlaying) private var nowPlaying = true
    @AppStorage(Pref.hud) private var hud = false
    @AppStorage(Pref.battery) private var battery = true
    @AppStorage(Pref.pomodoro) private var pomodoro = true
    @AppStorage(Pref.reminders) private var reminders = true
    @AppStorage(Pref.tasks) private var tasks = true
    @AppStorage(Pref.notes) private var notes = true
    @AppStorage(Pref.shelf) private var shelf = true
    @AppStorage(Pref.usage) private var usage = true
    @AppStorage(Pref.openMode) private var openMode = OpenMode.hover.rawValue
    @AppStorage(Pref.defaultTab) private var defaultTab = NookTab.home.rawValue
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.0
    @AppStorage(Pref.focusMinutes) private var focus = 25
    @AppStorage(Pref.breakMinutes) private var shortBreak = 5
    @AppStorage(Pref.longBreakMinutes) private var longBreak = 15
    @AppStorage(Pref.lowBatteryThreshold) private var lowBattery = 20
    @AppStorage(Pref.autoUpdateCheck) private var autoUpdate = true
    @ObservedObject private var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hudTrusted = HUDController.isTrusted

    var body: some View {
        Form {
            Section("General") {
                Picker("Default tab when nothing is playing", selection: $defaultTab) {
                    ForEach(NookTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab.rawValue)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Picker("Open notch on", selection: $openMode) {
                    ForEach(OpenMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if openMode == OpenMode.hover.rawValue {
                    Slider(value: $hoverDelay, in: 0...1, step: 0.05) { Text("Hover delay: \(hoverDelay, specifier: "%.2f")s") }
                }
            }
            Section("Modules") {
                Toggle("Now Playing", isOn: $nowPlaying)
                Toggle("Battery & charging", isOn: $battery)
                Toggle("Focus timer (Pomodoro)", isOn: $pomodoro)
                Toggle("Reminders", isOn: $reminders)
                Toggle("Tasks", isOn: $tasks)
                Toggle("Notes", isOn: $notes)
                Toggle("Shelf", isOn: $shelf)
                Toggle("AI Usage (Claude, Codex, Antigravity)", isOn: $usage)
            }
            Section {
                Toggle("Replace volume & brightness HUD", isOn: $hud)
                if hud && !hudTrusted {
                    HStack {
                        Text("Needs Accessibility permission.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Grant…") {
                            HUDController.requestTrust()
                            hudTrusted = HUDController.isTrusted
                            AppDelegate.shared?.startModules()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        hudTrusted = HUDController.isTrusted
                        if hudTrusted {
                            AppDelegate.shared?.startModules()
                        }
                    }
                }
            } header: { Text("System HUD") }
            Section("Focus timer") {
                Stepper("Focus: \(focus) min", value: $focus, in: 5...120, step: 5)
                Stepper("Short break: \(shortBreak) min", value: $shortBreak, in: 1...30)
                Stepper("Long break: \(longBreak) min", value: $longBreak, in: 5...60, step: 5)
            }
            Section("Now Playing") {
                LabeledContent("Source") {
                    switch NowPlayingModel.shared.source {
                    case .system: Label("All apps and browsers", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .appleScriptOnly: Label("Music and Spotify only", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .off: Text("Off").foregroundStyle(.secondary)
                    }
                }
                if NowPlayingModel.shared.source == .appleScriptOnly {
                    Text("The system media bridge isn't available on this Mac, so only Music and Spotify can be shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, on in
                        on ? Updater.shared.startAutomaticChecks() : Updater.shared.stopAutomaticChecks()
                    }
                HStack {
                    Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    if let v = updater.available?.version {
                        Button("Download \(v)") { Updater.shared.openDownloadPage() }
                    } else {
                        Button("Check Now") { Task { await Updater.shared.check(userInitiated: true) } }
                            .disabled(updater.isChecking)
                    }
                }
            }
            Section("Battery") {
                Stepper("Low battery alert at \(lowBattery)%", value: $lowBattery, in: 5...50, step: 5)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
        .onChange(of: nowPlaying) { _, _ in AppDelegate.shared?.startModules() }
        .onChange(of: battery) { _, _ in AppDelegate.shared?.startModules() }
        .onChange(of: hud) { _, _ in AppDelegate.shared?.startModules(); hudTrusted = HUDController.isTrusted }
        .onChange(of: reminders) { _, _ in AppDelegate.shared?.startModules() }
    }
}
