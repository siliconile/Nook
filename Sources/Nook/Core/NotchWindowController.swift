import AppKit
import Combine
import SwiftUI

/// Borderless panel that floats over the menu bar on every Space.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    // Key only while open, so text fields (Tasks, Notes) can receive typing but a
    // closed notch never traps keystrokes meant for other apps.
    override var canBecomeKey: Bool { MainActor.assumeIsolated { NookState.shared.isOpen } }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, keeps it pinned to the notch, and decides when it opens/closes
/// from global mouse movement (no Accessibility permission required).
@MainActor
final class NotchWindowController {
    private let state = NookState.shared
    private var panel: NotchPanel!
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var hiddenForFullscreen = false
    /// Screen the panel is pinned to (resolved in `reposition`).
    private var screen: NSScreen?
    /// Pointer has been inside the open notch since it opened. Until then (e.g. opened
    /// from the menu bar item) moving elsewhere does not close it; a click outside does.
    private var pointerEnteredSinceOpen = false
    private var menuTracking = false

    /// Panel is bigger than the open notch so shadows/animations are not clipped.
    /// Room around the open notch for the shadow and the feathered backdrop blur.
    private let panelSize = CGSize(width: NookState.openSize.width + 2 * (Theme.blurOutset + Theme.blurFeather * 2),
                                   height: NookState.openSize.height + Theme.blurOutset + Theme.blurFeather * 2)

    func start() {
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: panelSize))
        let host = NSHostingView(rootView: NotchRootView().environmentObject(state))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        state.$isOpen
            .sink { [weak self] open in self?.openChanged(open) }
            .store(in: &bag)

        // Don't auto-close underneath an open context menu.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuTracking = true }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuTracking = false }.store(in: &bag)

        // Hide while a fullscreen app owns the notch screen.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.publisher(for: name)
                .delay(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.updateFullscreenVisibility() }
                .store(in: &bag)
        }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }

    /// Screen with a hardware notch if any, otherwise the primary screen. Deterministic
    /// (not `NSScreen.main`, which follows keyboard focus).
    private var targetScreen: NSScreen? { screen }

    private func reposition() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        guard let screen else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: f.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            // No notch: draw a pill of menu-bar height.
            let menuBar = max(24, f.maxY - screen.visibleFrame.maxY)
            state.notchSize = CGSize(width: 190, height: menuBar)
        }
        let origin = CGPoint(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    /// Rect (screen coordinates) currently covered by the visible notch shape.
    private func activeRect(padding: CGFloat) -> NSRect {
        guard let screen = targetScreen else { return .zero }
        let size = state.contentSize
        let f = screen.frame
        // Extends past the top edge so a pointer slammed against the screen edge
        // (y == maxY, which NSRect.contains excludes) still counts as inside.
        return NSRect(x: f.midX - size.width / 2 - padding, y: f.maxY - size.height - padding,
                      width: size.width + padding * 2, height: size.height + padding + 10)
    }

    private func handle(_ event: NSEvent) {
        guard !hiddenForFullscreen else { return }
        let p = NSEvent.mouseLocation
        let inside = activeRect(padding: state.isOpen ? 12 : 6).contains(p)

        switch event.type {
        case .leftMouseDragged:
            // File drag towards the notch -> open the shelf so it can receive the drop.
            if !state.isOpen, inside, UserDefaults.standard.bool(forKey: Pref.shelf), dragHasFiles() {
                state.open(tab: .shelf)
            }
            return
        case .leftMouseUp:
            // A drag released outside (or cancelled) must not leave the notch stuck open.
            if state.isOpen, !inside, !state.isDropTargeted, !menuTracking { state.close() }
            return
        case .leftMouseDown:
            if state.isOpen {
                if !inside, !menuTracking { state.close() }
            } else if inside, openMode == .click {
                state.open()
            }
            return
        default:
            break
        }

        if inside != state.isHovering {
            state.isHovering = inside
            if inside && !state.isOpen {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }

        if inside {
            if state.isOpen { pointerEnteredSinceOpen = true; return }
            guard openMode == .hover else { return }
            let delay = UserDefaults.standard.double(forKey: Pref.hoverDelay)
            if delay <= 0 { state.open(); return }
            guard hoverTask == nil else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.hoverTask = nil
                if self.activeRect(padding: 6).contains(NSEvent.mouseLocation) { self.state.open() }
            }
        } else {
            hoverTask?.cancel(); hoverTask = nil
            if state.isOpen, pointerEnteredSinceOpen, !state.isDropTargeted, !menuTracking { state.close() }
        }
    }

    private var openMode: OpenMode {
        OpenMode(rawValue: UserDefaults.standard.string(forKey: Pref.openMode) ?? "") ?? .hover
    }

    /// True when the menu bar is not on screen for the notch display, i.e. a fullscreen
    /// app (video, game, presentation) is frontmost there.
    private func menuBarHidden() -> Bool {
        guard let screen = targetScreen,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Convert screen frame to CG (top-left origin) coordinates.
        let f = screen.frame
        let cgRect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        // Window titles need Screen Recording permission, so identify the menu bar by
        // its window level + position instead: a thin main-menu-level strip at the top edge.
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let strips = list.filter { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
        if strips.isEmpty { return false } // can't tell -> stay visible
        let hasMenuBar = strips.contains { info in
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let h = b["Height"] else { return false }
            return h < 60 && abs(y - cgRect.minY) < 2 && cgRect.contains(CGPoint(x: x + 1, y: y + 1))
        }
        return !hasMenuBar
    }

    private func updateFullscreenVisibility() {
        let hide = menuBarHidden()
        hiddenForFullscreen = hide
        if hide { state.close() }
        panel.animator().alphaValue = hide ? 0 : 1
    }

    private func dragHasFiles() -> Bool {
        let pb = NSPasteboard(name: .drag)
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// The only place that toggles mouse handling, so a closed notch never steals clicks.
    private func openChanged(_ open: Bool) {
        panel.ignoresMouseEvents = !open
        if open {
            // Opened by hover counts as "entered"; opened from the menu does not.
            pointerEnteredSinceOpen = activeRect(padding: 12).contains(NSEvent.mouseLocation)
            // Don't grab keyboard focus on open: the panel becomes key only when the user
            // clicks inside it (e.g. into Notes), so most closes need no focus hand-back.
        } else {
            pointerEnteredSinceOpen = false
            panel.makeFirstResponder(nil)
            guard panel.isKeyWindow else { return }
            // Give key status back, but only after the close animation has finished:
            // re-ordering the window mid-animation caused a visible glitch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.state.isOpen, self.panel.isKeyWindow else { return }
                self.panel.orderOut(nil)
                self.panel.orderFrontRegardless()
            }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
