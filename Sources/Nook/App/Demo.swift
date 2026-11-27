import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Nook --demo-gif <file.gif>` renders the README demo from the real notch views with
/// sample data (a fictional track), on a desktop-like backdrop. No screen recording needed.
@MainActor
enum Demo {
    static let canvas = CGSize(width: 720, height: 330)
    static let scale: CGFloat = 1.5
    static let fps: Double = 24

    static func render(to url: URL) {
        let state = NookState.shared
        state.notchSize = CGSize(width: 185, height: 32)
        loadSampleData()

        var frames: [(CGImage, Double)] = []
        func add(_ view: some View, hold: Double = 1 / fps) {
            if let img = image(view) { frames.append((img, hold)) }
        }
        func transition(opening: Bool, seconds: Double) {
            let n = Int(seconds * fps)
            for i in 0...n {
                let t = Double(i) / Double(n)
                let p = opening ? springOut(t) : 1 - easeInOut(t)
                add(TransitionFrame(progress: p, reveal: opening ? max(0, (t - 0.45) / 0.4) : 0)
                        .environmentObject(state))
            }
        }

        // 1. Closed notch with music playing.
        state.isOpen = false
        add(NotchRootView().environmentObject(state), hold: 1.4)

        // 2. Opens on hover -> Now Playing.
        state.selectedTab = .home
        transition(opening: true, seconds: 0.55)
        state.isOpen = true
        add(NotchRootView().environmentObject(state), hold: 2.2)

        // 3. Focus tab.
        state.selectedTab = .pomodoro
        add(NotchRootView().environmentObject(state), hold: 1.6)

        // 4. Close.
        state.isOpen = false
        state.selectedTab = .home
        transition(opening: false, seconds: 0.4)

        // 5. Volume keys -> HUD beside the notch.
        for i in 0...14 {
            let level = 0.35 + Double(i) * 0.03
            state.show(NookActivity(id: "hud.volume", symbol: level > 0.66 ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                                    progress: level, duration: 60))
            add(NotchRootView().environmentObject(state), hold: i == 14 ? 1.0 : 0.06)
        }

        // 6. Focus timer running in the closed notch.
        state.show(NookActivity(id: "x", symbol: "x", duration: 0.01))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let pomodoro = PomodoroModel.shared
        pomodoro.isRunning = true
        pomodoro.remaining = 24 * 60 + 9
        add(NotchRootView().environmentObject(state), hold: 1.6)
        pomodoro.isRunning = false

        writeGIF(frames, to: url)
    }

    /// `Nook --demo-shots <dir>` writes still PNGs of the same sample states at 2x
    /// (for the website and the social preview), with no backdrop or menu bar.
    static func renderShots(to dir: URL) {
        let state = NookState.shared
        state.notchSize = CGSize(width: 185, height: 32)
        loadSampleData()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        /// `zoom` renders at 2 x zoom and keeps the top-centre crop of the canvas's size,
        /// so a thin closed notch fills the picture without re-laying out the menu bar.
        func save(_ name: String, _ view: some View, size: CGSize, zoom: CGFloat = 1) {
            let r = ImageRenderer(content: view.environmentObject(state)
                .frame(width: size.width, height: size.height))
            r.scale = 2 * zoom
            let full = r.cgImage
            let crop = CGRect(x: (size.width * 2 * zoom - size.width * 2) / 2, y: 0,
                              width: size.width * 2, height: size.height * 2)
            guard let img = zoom == 1 ? full : full?.cropping(to: crop),
                  let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(name).png") as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            print("Wrote \(name).png")
        }
        let wide = CGSize(width: canvas.width, height: canvas.height)

        state.isOpen = true
        for (name, tab) in [("home", NookTab.home), ("focus", .pomodoro)] {
            state.selectedTab = tab
            save("open-\(name)", ZStack(alignment: .top) { Backdrop(); NotchRootView() }, size: wide)
        }
        // A portrait screen for the website's hero frame.
        state.selectedTab = .home
        save("hero-home", ZStack(alignment: .top) { Backdrop(); NotchRootView() }, size: CGSize(width: 600, height: 700))

        // AI Usage with sample numbers.
        let hour: TimeInterval = 3600
        UsageStore.shared.showSample([
            .claude: [AgentUsage(status: .ok, fiveHour: UsageWindow(usedPercent: 38, resetsAt: Date().addingTimeInterval(2.4 * hour)),
                                 weekly: UsageWindow(usedPercent: 61, resetsAt: Date().addingTimeInterval(52 * hour)))],
            .codex: [AgentUsage(status: .ok, fiveHour: UsageWindow(usedPercent: 12, resetsAt: Date().addingTimeInterval(4.1 * hour)),
                                weekly: UsageWindow(usedPercent: 27, resetsAt: Date().addingTimeInterval(97 * hour)))],
            .antigravity: [AgentUsage(status: .ok, group: "Gemini", fiveHour: UsageWindow(usedPercent: 74, resetsAt: Date().addingTimeInterval(1.2 * hour)),
                                      weekly: UsageWindow(usedPercent: 45, resetsAt: Date().addingTimeInterval(70 * hour)))],
        ])
        state.selectedTab = .usage
        save("open-usage", ZStack(alignment: .top) { Backdrop(); NotchRootView() }, size: wide)

        // Closed states zoomed 2x on the top of the screen, so the thin notch fills the picture.
        state.isOpen = false
        state.selectedTab = .home
        save("closed-music", ZStack(alignment: .top) { Backdrop(); NotchRootView() }, size: wide, zoom: 2)
        state.show(NookActivity(id: "hud.volume", symbol: "speaker.wave.2.fill", progress: 0.62, duration: 60))
        save("closed-volume", ZStack(alignment: .top) { Backdrop(); NotchRootView() }, size: wide, zoom: 2)
        state.show(NookActivity(id: "x", symbol: "x", duration: 0.01))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let pomodoro = PomodoroModel.shared
        pomodoro.isRunning = true
        pomodoro.remaining = 24 * 60 + 9
        save("closed-focus", ZStack(alignment: .top) { Backdrop(); NotchRootView() }, size: wide, zoom: 2)
        pomodoro.isRunning = false
    }

    // MARK: Frames

    private struct TransitionFrame: View {
        @EnvironmentObject var state: NookState
        let progress: CGFloat
        let reveal: Double

        var body: some View {
            let closed = state.closedContentSize(hovering: false)
            let open = state.openSize
            let shape = NotchSilhouette(progress: progress, closedSize: closed, openSize: open)
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                ExpandedView()
                    .frame(width: open.width, height: open.height, alignment: .top)
                    .opacity(min(1, reveal))
                    .blur(radius: (1 - min(1, reveal)) * 6)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .clipShape(shape)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
        }
    }

    private static func image(_ notch: some View) -> CGImage? {
        let view = ZStack(alignment: .top) {
            Backdrop()
            notch
        }
        .frame(width: canvas.width, height: canvas.height)
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.cgImage
    }

    /// Wallpaper + menu bar, so the notch reads in context.
    private struct Backdrop: View {
        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.62),
                                        Color(red: 0.75, green: 0.42, blue: 0.55),
                                        Color(red: 0.98, green: 0.70, blue: 0.52)],
                               startPoint: .top, endPoint: .bottom)
                HStack(spacing: 18) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.bold)
                    Text("File"); Text("Edit"); Text("View"); Text("Go")
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Tue 9:41")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.black.opacity(0.18))
            }
        }
    }

    // MARK: Sample data

    private static func loadSampleData() {
        let np = NowPlayingModel.shared
        np.title = "Golden Hour Drive"
        np.artist = "Nook Sessions"
        np.album = "Demo"
        np.duration = 214
        np.elapsed = 67
        np.isPlaying = true
        np.artwork = sampleArtwork()
    }

    private static func sampleArtwork() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 1, green: 0.62, blue: 0.3, alpha: 1),
                                NSColor(srgbRed: 0.9, green: 0.25, blue: 0.5, alpha: 1),
                                NSColor(srgbRed: 0.35, green: 0.2, blue: 0.7, alpha: 1)])!
                .draw(in: rect, angle: -60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 88, y: 120, width: 80, height: 80)).fill()
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 256, height: 70)).fill()
            return true
        }
    }

    // MARK: Easing

    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    /// Ease-out with a small overshoot, like the app's open spring.
    private static func springOut(_ t: Double) -> CGFloat {
        let c1 = 1.2, c3 = c1 + 1
        return CGFloat(1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2))
    }

    // MARK: GIF

    private static func writeGIF(_ frames: [(CGImage, Double)], to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (img, delay) in frames {
            CGImageDestinationAddImage(dest, img, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        print("Wrote \(url.path) (\(frames.count) frames)")
    }
}
