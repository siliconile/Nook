import AppKit
import CryptoKit
import Foundation

/// Installs an update in place. Two paths:
///  - Installed with Homebrew (`nook-notch` cask): quit, `brew upgrade --cask nook-notch`, relaunch.
///    Keeps Homebrew's record of the installed version correct.
///  - Otherwise: download the release zip, check its sha256 and bundle id, swap the app
///    bundle after Nook quits, relaunch. Files downloaded by the app itself aren't
///    quarantined, so Gatekeeper doesn't block the new version.
/// The swap runs in a detached shell script because the app has to quit first.
enum UpdateInstaller {
    enum Method { case homebrew(brew: URL), zip }

    enum Failure: Error {
        /// The tap hasn't picked up the release yet (it's bumped hourly).
        case notInHomebrewYet
        case notWritable
        case download
        case checksum
        case invalidBundle
    }

    static let caskToken = "nook-notch"
    static let tapCaskURL = URL(string: "https://raw.githubusercontent.com/siliconile/homebrew-tap/main/Casks/nook-notch.rb")!

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log")
    }

    /// Homebrew when this copy is the one the cask installed, otherwise the zip.
    static func method() -> Method {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inApplications = app == "/Applications/Nook.app" || app == "\(home)/Applications/Nook.app"
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let brew = "\(prefix)/bin/brew"
            if inApplications,
               FileManager.default.fileExists(atPath: "\(prefix)/Caskroom/\(caskToken)"),
               FileManager.default.isExecutableFile(atPath: brew) {
                return .homebrew(brew: URL(fileURLWithPath: brew))
            }
        }
        return .zip
    }

    /// Prepares the update, then quits Nook and hands over to the swap script.
    /// Throws before quitting if anything is wrong, so the running copy stays untouched.
    @MainActor
    static func install(_ release: Updater.Release) async throws {
        switch method() {
        case .homebrew(let brew):
            guard let tapVersion = await fetchTapVersion(),
                  !Updater.isNewer(release.version, than: tapVersion) else { throw Failure.notInHomebrewYet }
            let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            export PATH="$(dirname "$2"):/usr/bin:/bin:/usr/sbin:/sbin"
            {
              date
              "$2" update --quiet
              "$2" upgrade --cask \(caskToken)
            } >"$3" 2>&1
            open -b "$4" || open "$5"
            """
            try launchDetached(script, args: [
                "\(ProcessInfo.processInfo.processIdentifier)", brew.path, logURL.path,
                Bundle.main.bundleIdentifier ?? "", Bundle.main.bundlePath,
            ])

        case .zip:
            let target = Bundle.main.bundleURL
            let parent = target.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent),
                  FileManager.default.isWritableFile(atPath: target.path) else { throw Failure.notWritable }
            guard let zipURL = release.zipURL, let shaURL = release.shaURL else { throw Failure.download }

            let newApp = try await Task.detached { try await prepareZip(zipURL, shaURL, version: release.version) }.value
            let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            {
              date
              rm -rf "$3.old"
              if mv "$3" "$3.old" && mv "$2" "$3"; then
                rm -rf "$3.old"
              elif [ -d "$3.old" ] && [ ! -d "$3" ]; then
                mv "$3.old" "$3"
              fi
              xattr -dr com.apple.quarantine "$3"
            } >"$4" 2>&1
            open "$3"
            """
            try launchDetached(script, args: [
                "\(ProcessInfo.processInfo.processIdentifier)", newApp.path, target.path, logURL.path,
            ])
        }
        NSApp.terminate(nil)
    }

    // MARK: - Zip path

    /// Downloads and checks the release; returns the unpacked Nook.app in a temp folder.
    private static func prepareZip(_ zipURL: URL, _ shaURL: URL, version: String) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        guard let (shaData, shaResponse) = try? await URLSession.shared.data(from: shaURL),
              (shaResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(data: shaData, encoding: .utf8)?.split(separator: " ").first.map(String.init),
              expected.count == 64 else { throw Failure.download }

        guard let (tmp, response) = try? await URLSession.shared.download(from: zipURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        let zip = work.appendingPathComponent("Nook.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)

        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw Failure.checksum }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { throw Failure.invalidBundle }
        let app = unpacked.appendingPathComponent("Nook.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == version,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw Failure.invalidBundle }
        return app
    }

    // MARK: - Helpers

    /// Version in the tap's cask, so we don't quit for a `brew upgrade` that has nothing to do.
    private static func fetchTapVersion() async -> String? {
        var req = URLRequest(url: tapCaskURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Nook-Updater", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let text = String(data: data, encoding: .utf8),
              let regex = try? Regex(#"version "([^"]+)""#),
              let match = text.firstMatch(of: regex),
              let value = match.output[1].substring else { return nil }
        return String(value)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Starts `/bin/sh -c script` so it outlives Nook (it's reparented to launchd on quit).
    private static func launchDetached(_ script: String, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "nook-update"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
