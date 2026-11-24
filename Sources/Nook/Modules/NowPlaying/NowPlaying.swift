import AppKit
import CoreImage
import Darwin
import SwiftUI

@MainActor
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var isPlaying = false
    @Published var duration: TimeInterval = 0
    @Published var elapsed: TimeInterval = 0
    @Published var sourceBundleID: String?

    @Published private(set) var artworkTint: Color = .white
    @Published private(set) var lastElapsedUpdate: Date = Date()

    private enum PlaybackSource {
        case none
        case mediaRemote
        case appleScript(bundleID: String)
    }

    private var activeSource: PlaybackSource = .none
    private var pollTimer: Timer?
    private var isPolling = false

    // MediaRemote dynamic symbols
    private typealias MRGetNowPlayingInfoFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) ([String: Any]?) -> Void
    ) -> Void

    private typealias MRGetNowPlayingApplicationIsPlayingFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private typealias MRSendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private var mrHandle: UnsafeMutableRawPointer?
    private var mrGetNowPlayingInfo: MRGetNowPlayingInfoFn?
    private var mrGetIsPlaying: MRGetNowPlayingApplicationIsPlayingFn?
    private var mrSendCommand: MRSendCommandFn?
    private var didAttemptLoadMR = false

    // Serial queue for AppleScript execution
    private let scriptQueue = DispatchQueue(label: "com.nook.nowplaying.applescript", qos: .userInitiated)

    // Caching to avoid unnecessary artwork work every second
    private var artworkURLCache: [String: NSImage] = [:]
    private var currentArtworkKey: String = ""
    private var inFlightArtworkURL: String?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated private static let spotifyBundleID = "com.spotify.client"
    nonisolated private static let musicBundleID = "com.apple.Music"

    private init() {}

    /// System-wide source (works for browsers too); preferred when available.
    private lazy var bridge = MediaBridge { [weak self] update in self?.applyBridge(update) }
    private var bridgeDelivered = false

    func start() {
        loadMediaRemoteIfNeeded()
        if MediaBridge.isAvailable { bridge.start() }
        guard pollTimer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        bridge.stop()
        bridgeDelivered = false
        pollTimer?.invalidate()
        pollTimer = nil
        isPolling = false
    }

    func playPause() {
        let newPlaying = !isPlaying
        isPlaying = newPlaying
        lastElapsedUpdate = Date()

        switch activeSource {
        case .mediaRemote:
            sendMR(2)
        case .appleScript(let bundleID):
            runAppleScriptCommand(bundleID: bundleID, command: "playpause")
        case .none:
            sendMR(2)
        }
        scheduleQuickPoll()
    }

    func next() {
        elapsed = 0
        lastElapsedUpdate = Date()

        switch activeSource {
        case .mediaRemote:
            sendMR(4)
        case .appleScript(let bundleID):
            runAppleScriptCommand(bundleID: bundleID, command: "next track")
        case .none:
            sendMR(4)
        }
        scheduleQuickPoll()
    }

    func previous() {
        elapsed = 0
        lastElapsedUpdate = Date()

        switch activeSource {
        case .mediaRemote:
            sendMR(5)
        case .appleScript(let bundleID):
            runAppleScriptCommand(bundleID: bundleID, command: "previous track")
        case .none:
            sendMR(5)
        }
        scheduleQuickPoll()
    }

    private func sendMR(_ command: Int) {
        if bridge.isRunning {
            MediaBridge.send(command: command)
        } else if let send = mrSendCommand {
            _ = send(UInt32(command), nil)
        }
    }

    private func applyBridge(_ u: MediaBridge.Update) {
        bridgeDelivered = true
        guard !u.title.isEmpty else {
            // Nothing reported system-wide: let the AppleScript path decide.
            if case .mediaRemote = activeSource { clearState() }
            return
        }
        activeSource = .mediaRemote
        if sourceBundleID != u.bundleID { sourceBundleID = u.bundleID }
        let rate = u.rate > 0 ? u.rate : (u.isPlaying ? 1 : 0)
        var e = u.elapsed
        if let ts = u.timestamp, u.isPlaying { e += max(0, Date().timeIntervalSince(ts)) * rate }
        if u.duration > 0 { e = min(e, u.duration) }

        let trackKey = "bridge:\(u.title)|\(u.artist)|\(u.album)"
        if title != u.title { title = u.title }
        if artist != u.artist { artist = u.artist }
        if album != u.album { album = u.album }
        if isPlaying != u.isPlaying { isPlaying = u.isPlaying }
        if abs(duration - u.duration) > 0.01 { duration = u.duration }
        elapsed = e
        lastElapsedUpdate = Date()

        if let data = u.artwork {
            currentArtworkKey = trackKey
            updateArtwork(NSImage(data: data))
        } else if currentArtworkKey != trackKey {
            // New track without artwork data.
            currentArtworkKey = trackKey
            updateArtwork(nil)
        }
    }

    private func scheduleQuickPoll() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.poll()
        }
    }

    // MARK: - MediaRemote Loader

    private func loadMediaRemoteIfNeeded() {
        guard !didAttemptLoadMR else { return }
        didAttemptLoadMR = true

        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        ) else {
            return
        }
        mrHandle = handle

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            mrGetNowPlayingInfo = unsafeBitCast(sym, to: MRGetNowPlayingInfoFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            mrGetIsPlaying = unsafeBitCast(sym, to: MRGetNowPlayingApplicationIsPlayingFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            mrSendCommand = unsafeBitCast(sym, to: MRSendCommandFn.self)
        }
    }

    // MARK: - Polling Pipeline

    private func poll() {
        // The bridge pushes updates itself; only poll when it isn't working.
        // (Skipping AppleScript also avoids needless Automation prompts.)
        if bridge.isRunning && bridgeDelivered { return }
        guard !isPolling else { return }
        isPolling = true

        if let getInfo = mrGetNowPlayingInfo {
            getInfo(DispatchQueue.main) { [weak self] info in
                guard let self else { return }
                let dict = info ?? [:]
                let mrTitle = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !mrTitle.isEmpty {
                    if let getPlaying = self.mrGetIsPlaying {
                        getPlaying(DispatchQueue.main) { [weak self] playing in
                            guard let self else { return }
                            Task { @MainActor in
                                self.applyMediaRemote(info: dict, isPlayingFlag: playing)
                                self.isPolling = false
                            }
                        }
                    } else {
                        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                        Task { @MainActor in
                            self.applyMediaRemote(info: dict, isPlayingFlag: rate > 0.01)
                            self.isPolling = false
                        }
                    }
                } else {
                    self.pollAppleScriptFallback()
                }
            }
        } else {
            pollAppleScriptFallback()
        }
    }

    private func applyMediaRemote(info: [String: Any], isPlayingFlag: Bool) {
        let newTitle = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
        let newArtist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
        let newAlbum = (info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
        let newDuration = max(0, (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0)
        let rawElapsed = max(0, (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0)
        let rateNumber = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        // Players often leave PlaybackRate at 1 while paused; the isPlaying flag is authoritative.
        let playing = isPlayingFlag
        let effectiveRate = playing ? (rateNumber ?? 1.0) : 0.0

        let computedElapsed: TimeInterval
        if let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
            let delta = max(0, Date().timeIntervalSince(timestamp)) * effectiveRate
            computedElapsed = rawElapsed + delta
        } else {
            computedElapsed = rawElapsed
        }
        let clampedElapsed = newDuration > 0 ? min(newDuration, max(0, computedElapsed)) : max(0, computedElapsed)

        activeSource = .mediaRemote
        if sourceBundleID == nil {
            sourceBundleID = "com.apple.MediaRemote"
        }

        if title != newTitle { title = newTitle }
        if artist != newArtist { artist = newArtist }
        if album != newAlbum { album = newAlbum }
        if isPlaying != playing { isPlaying = playing }
        if abs(duration - newDuration) > 0.01 { duration = newDuration }
        elapsed = clampedElapsed
        lastElapsedUpdate = Date()

        if let artData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, !artData.isEmpty {
            let artKey = "mr:\(newTitle)|\(newArtist)|\(newAlbum)|\(artData.count)"
            if artKey != currentArtworkKey {
                currentArtworkKey = artKey
                if let img = NSImage(data: artData) {
                    updateArtwork(img)
                } else {
                    updateArtwork(nil)
                }
            }
        } else {
            let artKey = "mr-nil:\(newTitle)|\(newArtist)|\(newAlbum)"
            if artKey != currentArtworkKey {
                currentArtworkKey = artKey
                updateArtwork(nil)
            }
        }
    }

    // MARK: - AppleScript Fallback

    private struct ScriptPollResult: Sendable {
        let bundleID: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let elapsed: TimeInterval
        let isPlaying: Bool
        let spotifyArtworkURL: String?
        let musicArtworkData: Data?
    }

    private func pollAppleScriptFallback() {
        let spotifyRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.spotifyBundleID
        ).isEmpty
        let musicRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.musicBundleID
        ).isEmpty

        guard spotifyRunning || musicRunning else {
            clearState()
            isPolling = false
            return
        }

        let previousKey = currentArtworkKey

        scriptQueue.async { [weak self] in
            var chosen: ScriptPollResult?

            let spotifyResult = spotifyRunning ? Self.querySpotify() : nil
            let musicResult: ScriptPollResult?
            if let s = spotifyResult, s.isPlaying, !s.title.isEmpty {
                chosen = s
                musicResult = nil
            } else {
                musicResult = musicRunning ? Self.queryMusic(previousArtworkKey: previousKey) : nil
                if let m = musicResult, m.isPlaying, !m.title.isEmpty {
                    chosen = m
                } else if let s = spotifyResult, !s.title.isEmpty {
                    chosen = s
                } else if let m = musicResult, !m.title.isEmpty {
                    chosen = m
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let chosen {
                    self.applyScriptResult(chosen)
                } else {
                    self.clearState()
                }
                self.isPolling = false
            }
        }
    }

    nonisolated private static func querySpotify() -> ScriptPollResult? {
        let source = """
        tell application id "com.spotify.client"
            if player state is stopped then
                return {"stopped", "", "", "", 0, 0, ""}
            end if
            set pState to (player state as string)
            set tName to (name of current track as string)
            set tArtist to (artist of current track as string)
            set tAlbum to (album of current track as string)
            set tDur to (duration of current track as real)
            set pPos to (player position as real)
            set artURL to ""
            try
                set artURL to (artwork url of current track as string)
            end try
            return {pState, tName, tArtist, tAlbum, tDur, pPos, artURL}
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let desc = script.executeAndReturnError(&err)
        guard err == nil, desc.numberOfItems >= 6 else { return nil }

        let state = desc.atIndex(1)?.stringValue?.lowercased() ?? "stopped"
        guard state != "stopped" else { return nil }

        let title = desc.atIndex(2)?.stringValue ?? ""
        let artist = desc.atIndex(3)?.stringValue ?? ""
        let album = desc.atIndex(4)?.stringValue ?? ""
        let rawDur = desc.atIndex(5)?.doubleValue ?? 0
        // Spotify returns track duration in milliseconds
        let duration = rawDur > 1000 ? (rawDur / 1000.0) : max(0, rawDur)
        let elapsed = max(0, desc.atIndex(6)?.doubleValue ?? 0)
        let artURL = desc.atIndex(7)?.stringValue

        return ScriptPollResult(
            bundleID: spotifyBundleID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: duration > 0 ? min(duration, elapsed) : elapsed,
            isPlaying: state == "playing",
            spotifyArtworkURL: (artURL?.isEmpty == false) ? artURL : nil,
            musicArtworkData: nil
        )
    }

    nonisolated private static func queryMusic(previousArtworkKey: String) -> ScriptPollResult? {
        let source = """
        tell application id "com.apple.Music"
            if player state is stopped then
                return {"stopped", "", "", "", 0, 0}
            end if
            set pState to (player state as string)
            set tName to (name of current track as string)
            set tArtist to (artist of current track as string)
            set tAlbum to (album of current track as string)
            set tDur to (duration of current track as real)
            set pPos to (player position as real)
            return {pState, tName, tArtist, tAlbum, tDur, pPos}
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let desc = script.executeAndReturnError(&err)
        guard err == nil, desc.numberOfItems >= 6 else { return nil }

        let state = desc.atIndex(1)?.stringValue?.lowercased() ?? "stopped"
        guard state != "stopped" else { return nil }

        let title = desc.atIndex(2)?.stringValue ?? ""
        let artist = desc.atIndex(3)?.stringValue ?? ""
        let album = desc.atIndex(4)?.stringValue ?? ""
        let duration = max(0, desc.atIndex(5)?.doubleValue ?? 0)
        let elapsed = max(0, desc.atIndex(6)?.doubleValue ?? 0)

        let expectedKey = "music:\(title)|\(artist)|\(album)"
        var artData: Data? = nil
        if !title.isEmpty && expectedKey != previousArtworkKey {
            let artSource = """
            tell application id "com.apple.Music"
                try
                    return data of artwork 1 of current track
                end try
            end tell
            """
            if let artScript = NSAppleScript(source: artSource) {
                var artErr: NSDictionary?
                let artDesc = artScript.executeAndReturnError(&artErr)
                if artErr == nil {
                    let data = artDesc.data
                    if !data.isEmpty {
                        artData = data
                    }
                }
            }
        }

        return ScriptPollResult(
            bundleID: musicBundleID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: duration > 0 ? min(duration, elapsed) : elapsed,
            isPlaying: state == "playing",
            spotifyArtworkURL: nil,
            musicArtworkData: artData
        )
    }

    private func applyScriptResult(_ result: ScriptPollResult) {
        activeSource = .appleScript(bundleID: result.bundleID)
        if sourceBundleID != result.bundleID {
            sourceBundleID = result.bundleID
        }
        if title != result.title { title = result.title }
        if artist != result.artist { artist = result.artist }
        if album != result.album { album = result.album }
        if isPlaying != result.isPlaying { isPlaying = result.isPlaying }
        if abs(duration - result.duration) > 0.01 { duration = result.duration }
        elapsed = result.elapsed
        lastElapsedUpdate = Date()

        if result.bundleID == Self.spotifyBundleID {
            if let urlStr = result.spotifyArtworkURL, !urlStr.isEmpty {
                let key = "spotify:\(urlStr)"
                if currentArtworkKey != key {
                    currentArtworkKey = key
                    if let cached = artworkURLCache[urlStr] {
                        updateArtwork(cached)
                    } else {
                        updateArtwork(nil)
                        fetchSpotifyArtwork(urlString: urlStr, expectedKey: key)
                    }
                }
            } else {
                currentArtworkKey = ""
                updateArtwork(nil)
            }
        } else if result.bundleID == Self.musicBundleID {
            let key = "music:\(result.title)|\(result.artist)|\(result.album)"
            if currentArtworkKey != key {
                currentArtworkKey = key
                if let data = result.musicArtworkData, let img = NSImage(data: data) {
                    updateArtwork(img)
                } else {
                    updateArtwork(nil)
                }
            }
        }
    }

    private func fetchSpotifyArtwork(urlString: String, expectedKey: String) {
        guard inFlightArtworkURL != urlString, let url = URL(string: urlString) else { return }
        inFlightArtworkURL = urlString

        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    if self?.inFlightArtworkURL == urlString {
                        self?.inFlightArtworkURL = nil
                    }
                }
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.artworkURLCache[urlString] = image
                if self.currentArtworkKey == expectedKey {
                    self.updateArtwork(image)
                }
            }
        }
    }

    private func runAppleScriptCommand(bundleID: String, command: String) {
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        guard isRunning else { return }
        let source = """
        tell application id "\(bundleID)"
            try
                \(command)
            end try
        end tell
        """
        scriptQueue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var err: NSDictionary?
            _ = script.executeAndReturnError(&err)
        }
    }

    private func clearState() {
        activeSource = .none
        if !title.isEmpty { title = "" }
        if !artist.isEmpty { artist = "" }
        if !album.isEmpty { album = "" }
        if isPlaying { isPlaying = false }
        if duration != 0 { duration = 0 }
        if elapsed != 0 { elapsed = 0 }
        if sourceBundleID != nil { sourceBundleID = nil }
        if artwork != nil {
            currentArtworkKey = ""
            updateArtwork(nil)
        }
    }

    // MARK: - Artwork & Average Color

    private func updateArtwork(_ newImage: NSImage?) {
        artwork = newImage
        artworkTint = computeAverageColor(of: newImage)
    }

    private func computeAverageColor(of image: NSImage?) -> Color {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .white
        }

        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard !extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage") else {
            return .white
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return .white }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        var r = Double(bitmap[0]) / 255.0
        var g = Double(bitmap[1]) / 255.0
        var b = Double(bitmap[2]) / 255.0

        // Ensure visibility against the black notch background
        let maxComponent = max(r, max(g, b))
        if maxComponent < 0.05 {
            return .white
        } else if maxComponent < 0.55 {
            let scale = 0.55 / maxComponent
            r = min(1.0, r * scale)
            g = min(1.0, g * scale)
            b = min(1.0, b * scale)
        }

        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Expanded View

struct NowPlayingView: View {
    @ObservedObject private var model = NowPlayingModel.shared

    var body: some View {
        if model.title.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                // Track row
                HStack(spacing: 12) {
                    Button(action: openSourceApp) { artworkView }
                        .buttonStyle(.plain)
                        .help("Open player")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title)
                            .font(Theme.title)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Text(model.artist.isEmpty ? (model.album.isEmpty ? "Unknown Artist" : model.album) : model.artist)
                            .font(Theme.secondary)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    NowPlayingCompactTrailing()
                        .scaleEffect(1.2)
                        .padding(.trailing, 6)
                }

                // Progress row
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let current = interpolatedElapsed(at: context.date)
                    let total = max(0, model.duration)
                    let progress = total > 0 ? min(1, max(0, current / total)) : 0
                    HStack(spacing: 10) {
                        Text(Self.formatTime(current))
                            .frame(width: 34, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Theme.fillStrong)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.85))
                                        .frame(width: max(0, geo.size.width * progress))
                                }
                        }
                        .frame(height: 4)
                        Text("-\(Self.formatTime(max(0, total - current)))")
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(Theme.mono)
                    .foregroundStyle(Theme.tertiaryText)
                }
                .frame(height: 14)
                .padding(.top, 12)

                // Transport row
                HStack(spacing: 28) {
                    IconButton(symbol: "backward.fill", size: 17, frame: 34, help: "Previous") { model.previous() }
                    IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 24, frame: 40,
                               help: model.isPlaying ? "Pause" : "Play") { model.playPause() }
                    IconButton(symbol: "forward.fill", size: 17, frame: 34, help: "Next") { model.next() }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func openSourceApp() {
        guard let id = model.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text("Nothing playing")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Theme.fillStrong)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)
                    }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }

    private func interpolatedElapsed(at now: Date) -> TimeInterval {
        var value = model.elapsed
        if model.isPlaying {
            let delta = max(0, now.timeIntervalSince(model.lastElapsedUpdate))
            value += delta
        }
        if model.duration > 0 {
            return min(model.duration, max(0, value))
        }
        return max(0, value)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Compact Notch Views

struct NowPlayingCompactLeading: View {
    @ObservedObject private var model = NowPlayingModel.shared

    var body: some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct NowPlayingCompactTrailing: View {
    @ObservedObject private var model = NowPlayingModel.shared

    private static let frequencies: [Double] = [4.1, 5.7, 4.8, 6.3]
    private static let phases: [Double] = [0.0, 1.4, 2.6, 0.9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !model.isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(model.artworkTint)
                        .frame(width: 2.5, height: barHeight(for: index, time: t))
                }
            }
            .frame(height: 14)
        }
    }

    private func barHeight(for index: Int, time: TimeInterval) -> CGFloat {
        guard model.isPlaying else { return 3 }
        let wave = (sin(time * Self.frequencies[index] + Self.phases[index]) + 1.0) * 0.5
        return CGFloat(3.0 + wave * 11.0)
    }
}
