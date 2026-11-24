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

    static let openSize = CGSize(width: 600, height: 250)
    static let sideWidth: CGFloat = 76

    private var activityTask: Task<Void, Never>?

    /// Pop a transient activity out of the notch. Ignored while the notch is open.
    func show(_ new: NookActivity) {
        activityTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { activity = new }
        let id = new.id
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(new.duration))
            guard !Task.isCancelled, let self, self.activity?.id == id else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self.activity = nil }
        }
    }

    func open(tab: NookTab? = nil) {
        if let tab { selectedTab = tab }
        guard !isOpen else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { isOpen = true }
    }

    func close() {
        guard isOpen else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { isOpen = false }
    }

    /// Whether something should be shown beside the closed notch.
    var hasClosedContent: Bool {
        activity != nil || PomodoroModel.shared.isRunning
            || (UserDefaults.standard.bool(forKey: Pref.nowPlaying) && NowPlayingModel.shared.isPlaying)
    }

    /// Size of the black notch shape for the current state (excluding shadow).
    var contentSize: CGSize {
        if isOpen { return Self.openSize }
        if hasClosedContent {
            return CGSize(width: notchSize.width + Self.sideWidth * 2, height: notchSize.height)
        }
        return notchSize
    }

    var enabledTabs: [NookTab] {
        NookTab.allCases.filter { UserDefaults.standard.bool(forKey: $0.prefKey) }
    }
}
