import AppKit
import Foundation

/// Update checker: asks GitHub for the latest release and, if it's newer than the running
/// version, offers to install it in place (see `UpdateInstaller`). No keys, no Sparkle.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "siliconile/Nook"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    struct Release: Equatable {
        let version: String
        let page: URL
        /// Release assets: Nook-<version>.zip and its .sha256.
        var zipURL: URL? = nil
        var shaURL: URL? = nil
    }

    @Published private(set) var available: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
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
                var release = Release(version: version, page: page)
                for asset in json["assets"] as? [[String: Any]] ?? [] {
                    guard let name = asset["name"] as? String,
                          let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }
                    if name == "Nook-\(version).zip" { release.zipURL = url }
                    if name == "Nook-\(version).zip.sha256" { release.shaURL = url }
                }
                let isNew = available != release
                available = release
                AppDelegate.shared?.updateMenuChanged()
                if userInitiated {
                    promptToUpdate(release)
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

    /// Installs the available update and relaunches. On failure Nook keeps running and
    /// offers the download page instead.
    func installAvailable() {
        guard let release = available, !isInstalling else { return }
        isInstalling = true
        AppDelegate.shared?.updateMenuChanged()
        NookState.shared.show(NookActivity(
            id: "update", symbol: "arrow.down.circle.fill", tint: .blue,
            title: String(localized: "Updating…"), trailingText: release.version, duration: 60))
        Task {
            do {
                try await UpdateInstaller.install(release) // quits Nook on success
            } catch {
                isInstalling = false
                AppDelegate.shared?.updateMenuChanged()
                NookState.shared.show(NookActivity(id: "update", symbol: "arrow.down.circle.fill", duration: 0.1))
                informInstallFailed(release, error)
            }
        }
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

    private func promptToUpdate(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Nook \(release.version) is available")
        alert.informativeText = String(localized: "You have version \(Self.currentVersion). Nook will restart to finish updating.")
        alert.addButton(withTitle: String(localized: "Update Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Release Notes"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: installAvailable()
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    private func informInstallFailed(_ release: Release, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch error as? UpdateInstaller.Failure {
        case .notInHomebrewYet:
            alert.messageText = String(localized: "The update hasn't reached Homebrew yet")
            alert.informativeText = String(localized: "Nook \(release.version) usually reaches Homebrew within an hour. Try again later, or download it now.")
        case .notWritable:
            alert.messageText = String(localized: "Nook can't update itself here")
            alert.informativeText = String(localized: "Its folder isn't writable. Download the new version and replace Nook.app.")
        case .checksum, .invalidBundle:
            alert.messageText = String(localized: "The download couldn't be verified")
            alert.informativeText = String(localized: "Nothing was changed. Download the new version from GitHub instead.")
        default:
            alert.messageText = String(localized: "Couldn't download the update")
            alert.informativeText = String(localized: "Check your internet connection and try again.")
        }
        alert.addButton(withTitle: String(localized: "Open Download Page"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
