import SwiftUI

/// Tabs shown when the notch is expanded.
enum NookTab: String, CaseIterable, Identifiable {
    case home, tasks, notes, reminders, pomodoro, shelf
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Now Playing"
        case .tasks: "Tasks"
        case .notes: "Notes"
        case .reminders: "Reminders"
        case .pomodoro: "Focus"
        case .shelf: "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .home: "music.note"
        case .tasks: "checklist"
        case .notes: "note.text"
        case .reminders: "list.bullet.circle"
        case .pomodoro: "timer"
        case .shelf: "tray.full"
        }
    }

    /// UserDefaults key that enables/disables the tab.
    var prefKey: String {
        switch self {
        case .home: Pref.nowPlaying
        case .tasks: Pref.tasks
        case .notes: Pref.notes
        case .reminders: Pref.reminders
        case .pomodoro: Pref.pomodoro
        case .shelf: Pref.shelf
        }
    }
}

/// A short-lived notification that pops out of the closed notch
/// (volume/brightness HUD, charging, timer finished, file added...).
struct NookActivity: Identifiable, Equatable {
    /// Coalescing key: posting an activity with the same id replaces the current one
    /// and restarts its timer (e.g. "hud.volume").
    let id: String
    var symbol: String
    var tint: Color = .white
    var title: String? = nil
    /// 0...1, drawn as a bar on the trailing side when non-nil.
    var progress: Double? = nil
    var trailingText: String? = nil
    var duration: TimeInterval = 1.8
}

/// Single source of truth for the notch UI.
@MainActor
final class NookState: ObservableObject {
    static let shared = NookState()

    @Published var isOpen = false
    @Published var selectedTab: NookTab = .home
    @Published private(set) var activity: NookActivity?
    /// True while a file drag hovers the notch, so the shelf can highlight.
    @Published var isDropTargeted = false
    /// Pointer is over the closed notch (drives the hover "lift").
    @Published var isHovering = false
    /// Physical notch size of the target screen (set by the window controller).
    @Published var notchSize = CGSize(width: 200, height: 32)

    static let openSize = CGSize(width: 500, height: 192)
    static let sideWidth: CGFloat = 76
    /// Narrow wings while only music is playing, so menu-bar items stay visible.
    static let compactSideWidth: CGFloat = 36

    private var activityTask: Task<Void, Never>?

    /// Pop a transient activity out of the notch. Ignored while the notch is open.
    func show(_ new: NookActivity) {
        activityTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) { activity = new }
        let id = new.id
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(new.duration))
            guard !Task.isCancelled, let self, self.activity?.id == id else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self.activity = nil }
        }
    }

    func open(tab: NookTab? = nil) {
        if let tab {
            selectedTab = tab
        } else if !isOpen {
            selectedTab = defaultTab
        }
        guard !isOpen else { return }
        withAnimation(Theme.shapeSpring) { isOpen = true }
    }

    func close() {
        guard isOpen else { return }
        withAnimation(Theme.closeSpring) { isOpen = false }
    }

    /// Whether something should be shown beside the closed notch.
    var hasClosedContent: Bool {
        activity != nil || PomodoroModel.shared.isRunning
            || (UserDefaults.standard.bool(forKey: Pref.nowPlaying) && NowPlayingModel.shared.isPlaying)
    }

    /// Width of each wing beside the hardware notch while closed (0 = no wings).
    var closedSideWidth: CGFloat {
        if isLevelActivity { return Self.levelSideWidth }
        if activity != nil || PomodoroModel.shared.isRunning { return Self.sideWidth }
        if UserDefaults.standard.bool(forKey: Pref.nowPlaying) && NowPlayingModel.shared.isPlaying {
            return Self.compactSideWidth
        }
        return 0
    }

    /// Size of the black notch shape for the current state (excluding shadow).
    var contentSize: CGSize {
        if isOpen { return Self.openSize }
        return closedContentSize(hovering: false)
    }

    /// Level-style activity (volume, brightness, charging): shown in wider wings beside
    /// the hardware notch.
    var isLevelActivity: Bool { activity?.progress != nil }
    static let levelSideWidth: CGFloat = 92

    /// Closed outline size; hovering lifts it a little in every direction.
    func closedContentSize(hovering: Bool) -> CGSize {
        let base = CGSize(width: notchSize.width + closedSideWidth * 2,
                          height: notchSize.height)
        _ = hovering // hover is applied as a scale of the whole notch in NotchRootView
        return base
    }

    /// Tab shown on open: Now Playing while something plays, otherwise the user's choice.
    var defaultTab: NookTab {
        let enabled = enabledTabs
        if enabled.contains(.home), UserDefaults.standard.bool(forKey: Pref.nowPlaying),
           NowPlayingModel.shared.isPlaying {
            return .home
        }
        let chosen = NookTab(rawValue: UserDefaults.standard.string(forKey: Pref.defaultTab) ?? "") ?? .home
        return enabled.contains(chosen) ? chosen : (enabled.first ?? .home)
    }

    var enabledTabs: [NookTab] {
        NookTab.allCases.filter { UserDefaults.standard.bool(forKey: $0.prefKey) }
    }
}
