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
    @AppStorage(Pref.openMode) private var openMode = OpenMode.hover.rawValue
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.0
    @AppStorage(Pref.focusMinutes) private var focus = 25
    @AppStorage(Pref.breakMinutes) private var shortBreak = 5
    @AppStorage(Pref.longBreakMinutes) private var longBreak = 15
    @AppStorage(Pref.lowBatteryThreshold) private var lowBattery = 20
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hudTrusted = HUDController.isTrusted

    var body: some View {
        Form {
            Section("General") {
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
            }
            Section {
                Toggle("Replace volume & brightness HUD", isOn: $hud)
                if hud && !hudTrusted {
                    HStack {
                        Text("Needs Accessibility permission.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Grant…") { HUDController.requestTrust(); hudTrusted = HUDController.isTrusted }
                    }
                }
            } header: { Text("System HUD") }
            Section("Focus timer") {
                Stepper("Focus: \(focus) min", value: $focus, in: 5...120, step: 5)
                Stepper("Short break: \(shortBreak) min", value: $shortBreak, in: 1...30)
                Stepper("Long break: \(longBreak) min", value: $longBreak, in: 5...60, step: 5)
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
