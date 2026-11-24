import AppKit
import Foundation

/// Lightweight update checker: asks GitHub for the latest release and, if it's newer
/// than the running version, offers to open its download page. No auto-install, no keys.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "siliconile/Nook"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var timer: Timer?

    /// Checks shortly after launch, then once a day, while enabled in Settings.
    func startAutomaticChecks() {
        timer?.invalidate()
        guard UserDefaults.standard.bool(forKey: Pref.autoUpdateCheck) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            await self.check(userInitiated: false)
        }
        let t = Timer(timeInterval: 24 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nook-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            else { throw URLError(.badServerResponse) }
            lastChecked = Date()
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(version, than: Self.currentVersion) {
                let release = Release(version: version, page: page)
                let isNew = available != release
                available = release
                AppDelegate.shared?.updateMenuChanged()
                if userInitiated {
                    promptToDownload(release)
                } else if isNew {
                    NookState.shared.show(NookActivity(
                        id: "update", symbol: "arrow.down.circle.fill", tint: .blue,
                        title: String(localized: "Update"), trailingText: version, duration: 4))
                }
            } else {
                available = nil
                AppDelegate.shared?.updateMenuChanged()
                if userInitiated { informUpToDate() }
            }
        } catch {
            if userInitiated { informFailed() }
        }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(available?.page ?? Self.releasesPage)
    }

    /// Semantic-version comparison ("0.10.0" > "0.9.1"); pre-release suffixes are ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Alerts

    private func promptToDownload(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Nook \(release.version) is available")
        alert.informativeText = String(localized: "You have version \(Self.currentVersion). Open the download page?")
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }

    private func informUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(localized: "Nook \(Self.currentVersion) is the latest version.")
        alert.runModal()
    }

    private func informFailed() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't check for updates")
        alert.informativeText = String(localized: "Check your internet connection and try again.")
        alert.runModal()
    }
}
