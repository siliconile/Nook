import Foundation

/// Reads system-wide Now Playing info (any app, including browsers such as Chrome)
/// through `/usr/bin/perl` + NookMediaBridge.dylib.
///
/// Since macOS 15.4 MediaRemote only answers Apple-signed processes, so a third-party
/// app sees nothing. `/usr/bin/perl` is a platform binary that is still allowed; it loads
/// our dylib (see Helper/NookMediaBridge.m), which streams one JSON object per change.
@MainActor
final class MediaBridge {
    struct Update {
        var title = "", artist = "", album = ""
        var duration: TimeInterval = 0, elapsed: TimeInterval = 0, rate: Double = 0
        var timestamp: Date?
        var isPlaying = false
        var bundleID: String?
        /// MediaRemote shuffle / repeat modes; nil when the player doesn't report them
        /// (browsers don't), which means the player can't be shuffled from here either.
        var shuffleMode: Int?
        var repeatMode: Int?
        /// Present only when the track (and therefore the artwork) changed.
        var artwork: Data?
    }

    nonisolated static let perlPath = "/usr/bin/perl"

    private let onUpdate: (Update) -> Void
    private var process: Process?
    private var buffer = Data()
    private var wantRunning = false
    private var restartDelay: TimeInterval = 1

    /// Whether the bridge is usable on this machine (perl + dylib present).
    static var isAvailable: Bool { dylibPath != nil && FileManager.default.isExecutableFile(atPath: perlPath) }
    private(set) var isRunning = false

    nonisolated static var dylibPath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("NookMediaBridge.dylib").path,
            // `swift run` / debug builds: dylib next to the executable.
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("NookMediaBridge.dylib").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    init(onUpdate: @escaping (Update) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        wantRunning = true
        launch()
    }

    func stop() {
        wantRunning = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// MediaRemote command numbers: 2 toggle play/pause, 4 next, 5 previous,
    /// 6 toggle shuffle, 7 toggle (cycle) repeat.
    nonisolated static func send(command: Int) {
        guard let dylib = dylibPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: perlPath)
        p.arguments = ["-e", script(symbol: "nook_send"), dylib]
        var env = ProcessInfo.processInfo.environment
        env["NOOK_MR_COMMAND"] = String(command)
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    nonisolated private static func script(symbol: String) -> String {
        """
        use DynaLoader;
        my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $s = DynaLoader::dl_find_symbol($l, "\(symbol)") or die "missing symbol";
        DynaLoader::dl_install_xsub("main::\(symbol)", $s);
        \(symbol)();
        """
    }

    private func launch() {
        guard wantRunning, process == nil, let dylib = Self.dylibPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.perlPath)
        p.arguments = ["-e", Self.script(symbol: "nook_stream"), dylib]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.processExited() }
        }
        do {
            try p.run()
            process = p
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    private func processExited() {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        isRunning = false
        buffer.removeAll()
        guard wantRunning else { return }
        // Restart with backoff (e.g. after sleep or a crash).
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.launch()
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            restartDelay = 1
            onUpdate(Self.parse(obj))
        }
    }

    private static func parse(_ o: [String: Any]) -> Update {
        var u = Update()
        u.title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        u.artist = o["artist"] as? String ?? ""
        u.album = o["album"] as? String ?? ""
        u.duration = max(0, (o["duration"] as? NSNumber)?.doubleValue ?? 0)
        u.elapsed = max(0, (o["elapsed"] as? NSNumber)?.doubleValue ?? 0)
        u.rate = (o["rate"] as? NSNumber)?.doubleValue ?? 0
        if let ts = (o["timestamp"] as? NSNumber)?.doubleValue { u.timestamp = Date(timeIntervalSince1970: ts) }
        u.isPlaying = (o["playing"] as? Bool) ?? (u.rate > 0.01)
        u.bundleID = o["bundle"] as? String
        u.shuffleMode = (o["shuffle"] as? NSNumber)?.intValue
        u.repeatMode = (o["repeat"] as? NSNumber)?.intValue
        if let b64 = o["artwork"] as? String { u.artwork = Data(base64Encoded: b64) }
        return u
    }
}
