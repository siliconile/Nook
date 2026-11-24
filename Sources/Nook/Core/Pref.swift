import Foundation

/// UserDefaults keys. Defaults are registered at launch in `Pref.registerDefaults()`.
enum Pref {
    static let nowPlaying = "module.nowPlaying"
    static let hud = "module.hud"
    static let battery = "module.battery"
    static let pomodoro = "module.pomodoro"
    static let reminders = "module.reminders"
    static let tasks = "module.tasks"
    static let notes = "module.notes"
    static let shelf = "module.shelf"

    static let openMode = "openMode"                  // OpenMode raw value
    static let defaultTab = "defaultTab"              // NookTab raw value shown when nothing plays
    static let hoverDelay = "hoverDelay"              // seconds before hovering opens the notch
    static let focusMinutes = "pomodoro.focusMinutes"
    static let breakMinutes = "pomodoro.breakMinutes"
    static let longBreakMinutes = "pomodoro.longBreakMinutes"
    static let sessionsBeforeLong = "pomodoro.sessionsBeforeLong"
    static let lowBatteryThreshold = "battery.lowThreshold"
    static let autoUpdateCheck = "updates.autoCheck"

    /// One-time copy of settings saved under the old bundle identifier (com.local.Nook),
    /// so switching to io.github.siliconile.Nook keeps the user's choices.
    static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        let flag = "migratedFromLegacyBundleID"
        guard !d.bool(forKey: flag) else { return }
        if let old = d.persistentDomain(forName: "com.local.Nook") {
            for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }
        d.set(true, forKey: flag)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            nowPlaying: true, hud: false, battery: true, pomodoro: true,
            reminders: true, tasks: true, notes: true, shelf: true,
            openMode: OpenMode.hover.rawValue, hoverDelay: 0.0, defaultTab: "home",
            focusMinutes: 25, breakMinutes: 5, longBreakMinutes: 15, sessionsBeforeLong: 4,
            lowBatteryThreshold: 20, autoUpdateCheck: true,
        ])
    }

    /// Folder for local data (tasks, notes, shelf): ~/Library/Application Support/Nook
    static var dataDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// How the closed notch opens.
enum OpenMode: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
    var title: String { self == .hover ? String(localized: "Hover") : String(localized: "Click") }
}
