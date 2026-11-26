import AppKit
import SwiftUI

/// Debug aid: `Nook --snapshot <dir>` renders each notch state to PNG and exits.
/// Lets layouts be checked without Screen Recording permission.
@MainActor
enum Snapshot {
    /// True while rendering PNGs (native views such as the blur can't be captured).
    static var isRendering = false

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let g = args.firstIndex(of: "--demo-gif"), g + 1 < args.count {
            Pref.registerDefaults()
            isRendering = true
            Demo.render(to: URL(fileURLWithPath: args[g + 1]))
            return true
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Pref.registerDefaults()
        isRendering = true

        let state = NookState.shared
        state.notchSize = CGSize(width: 185, height: 32)
        let size = CGSize(width: NookState.openSize.width + 2 * (Theme.blurOutset + Theme.blurFeather * 2), height: NookState.maxOpenHeight + Theme.blurOutset + Theme.blurFeather * 2)

        func render(_ name: String) {
            let view = NotchRootView().environmentObject(state)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.55))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }

        render("closed")
        state.show(NookActivity(id: "hud.volume", symbol: "speaker.wave.2.fill", progress: 0.6, duration: 60))
        render("closed-volume")
        state.show(NookActivity(id: "battery", symbol: "bolt.fill", tint: .green, progress: 0.8, trailingText: "80%", duration: 60))
        render("closed-battery")
        // Let the real Now Playing pipeline run briefly so `open-home` shows live data.
        NowPlayingModel.shared.start()
        RemindersModel.shared.start() // read-only fetch, so list heights can be checked
        UsageStore.shared.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        state.isOpen = true
        render("open-home-live")
        NowPlayingModel.shared.stop()
        for tab in NookTab.allCases {
            state.selectedTab = tab
            render("open-\(tab.rawValue)")
        }
        return true
    }
}
