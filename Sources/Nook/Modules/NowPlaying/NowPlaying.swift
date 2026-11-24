import AppKit
import SwiftUI

// CONTRACT STUB — replace implementation, keep public API.
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
    func start() {}
    func stop() {}
    func playPause() {}
    func next() {}
    func previous() {}
}

struct NowPlayingView: View { var body: some View { Text("Nothing playing") } }
struct NowPlayingCompactLeading: View { var body: some View { EmptyView() } }
struct NowPlayingCompactTrailing: View { var body: some View { EmptyView() } }
