import AppKit
import Combine
import SwiftUI

/// The three phases of a pomodoro cycle.
enum PomodoroPhase: String, CaseIterable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .shortBreak: String(localized: "Short break")
        case .longBreak: String(localized: "Long break")
        }
    }

    /// Compact label for the picker buttons.
    var shortTitle: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .shortBreak: String(localized: "Short")
        case .longBreak: String(localized: "Long")
        }
    }

    var symbol: String { self == .focus ? "brain.head.profile" : "cup.and.saucer.fill" }
    var tint: Color { self == .focus ? .orange : .green }
}

@MainActor
final class PomodoroModel: ObservableObject {
    static let shared = PomodoroModel()

    @Published var phase: PomodoroPhase = .focus
    @Published var isRunning = false
    @Published var remaining: TimeInterval = 25 * 60
    /// Focus sessions finished in the current cycle (resets after a long break).
    @Published private(set) var completedFocusSessions = 0

    /// End date of the running phase. Using a date (instead of tick counting)
    /// keeps the countdown accurate even if timers get delayed or the app sleeps briefly.
    private var endDate: Date?
    private var ticker: AnyCancellable?
    private var defaultsObserver: AnyCancellable?
    private var isIdle = true

    init() {
        remaining = duration(for: .focus)
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isRunning, self.isIdle else { return }
                let updated = self.duration(for: self.phase)
                if self.remaining != updated {
                    self.remaining = updated
                }
            }
    }

    /// Elapsed fraction of the current phase, 0...1.
    var progress: Double {
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    var remainingText: String { Self.formatted(remaining) }

    /// Number of focus sessions before a long break (from settings).
    var sessionsBeforeLong: Int {
        max(1, UserDefaults.standard.integer(forKey: Pref.sessionsBeforeLong))
    }

    /// m:ss formatting for a duration in seconds.
    static func formatted(_ interval: TimeInterval) -> String {
        let secs = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Controls

    func start() {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = duration(for: phase) }
        isIdle = false
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicker()
    }

    func pause() {
        guard isRunning else { return }
        if let endDate { remaining = max(0, endDate.timeIntervalSinceNow) }
        endDate = nil
        stopTicker()
        isRunning = false
    }

    func reset() {
        endDate = nil
        isIdle = true
        remaining = duration(for: phase)
        stopTicker()
        isRunning = false
    }

    /// Jump to the next phase without ringing.
    func skip() {
        phaseEnded(quiet: true)
    }

    /// Picker: switch phase and reset its duration.
    func select(_ newPhase: PomodoroPhase) {
        guard newPhase != phase else { return }
        if phase == .longBreak || (newPhase == .focus && completedFocusSessions >= sessionsBeforeLong) {
            completedFocusSessions = 0
        }
        phase = newPhase
        endDate = nil
        isIdle = true
        remaining = duration(for: phase)
        stopTicker()
        isRunning = false
    }

    /// Length of the current phase in whole minutes (what the wheel shows while idle).
    var selectedMinutes: Int { Int(duration(for: phase) / 60) }

    /// True before the phase has been started (or after a reset): the wheel can edit it.
    var canEditDuration: Bool { !isRunning }

    /// Wheel: sets the current phase's length (saved like the Settings steppers) and
    /// resets it. Ignored while the timer runs.
    func setMinutes(_ minutes: Int) {
        guard !isRunning else { return }
        let m = min(Self.wheelRange.upperBound, max(Self.wheelRange.lowerBound, minutes))
        let key: String
        switch phase {
        case .focus: key = Pref.focusMinutes
        case .shortBreak: key = Pref.breakMinutes
        case .longBreak: key = Pref.longBreakMinutes
        }
        endDate = nil
        isIdle = true
        if UserDefaults.standard.integer(forKey: key) != m { UserDefaults.standard.set(m, forKey: key) }
        remaining = TimeInterval(m * 60)
    }

    static let wheelRange = 1...120

    // MARK: - Internals

    private func duration(for phase: PomodoroPhase) -> TimeInterval {
        let d = UserDefaults.standard
        switch phase {
        case .focus: return TimeInterval(max(1, d.integer(forKey: Pref.focusMinutes))) * 60
        case .shortBreak: return TimeInterval(max(1, d.integer(forKey: Pref.breakMinutes))) * 60
        case .longBreak: return TimeInterval(max(1, d.integer(forKey: Pref.longBreakMinutes))) * 60
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard isRunning, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { phaseEnded(quiet: false) }
    }

    /// Advance to the next phase. When the clock ran out, ring and notify.
    private func phaseEnded(quiet: Bool) {
        stopTicker()
        endDate = nil
        isRunning = false
        remaining = 0

        if phase == .focus && !quiet {
            completedFocusSessions += 1
        }
        advancePhase()

        isIdle = true
        remaining = duration(for: phase)

        if !quiet {
            let message = phase == .focus ? String(localized: "Focus time") : String(localized: "Break time")
            NSSound(named: "Glass")?.play()
            NookState.shared.show(NookActivity(
                id: "pomodoro",
                symbol: phase.symbol,
                tint: phase.tint,
                title: message,
                trailingText: String(localized: "Done"),
                duration: 4
            ))
        }
    }

    private func advancePhase() {
        switch phase {
        case .focus:
            phase = completedFocusSessions >= sessionsBeforeLong ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            completedFocusSessions = 0
            phase = .focus
        }
    }
}

/// Focus timer: a ruler wheel of minutes (scroll or drag to set), the time, and controls.
struct PomodoroView: View {
    @ObservedObject private var model = PomodoroModel.shared

    var body: some View {
        VStack(spacing: 10) {
            WheelPicker(
                value: model.selectedMinutes, range: PomodoroModel.wheelRange, tint: model.phase.tint,
                enabled: model.canEditDuration, displayValue: rulerFollowsCountdown ? model.remaining / 60 : nil,
                label: { "\($0)" }, onCommit: { model.setMinutes($0) })
            .frame(height: 64)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .help(model.canEditDuration ? String(localized: "Scroll to set the time") : "")

            HStack(alignment: .center, spacing: 8) {
                primaryButton
                if !model.isRunning && model.remaining < Double(model.selectedMinutes * 60) {
                    IconButton(symbol: "arrow.counterclockwise", size: 12, frame: 30, tint: Theme.secondaryText,
                               help: String(localized: "Reset")) { model.reset() }
                }
                phaseMenu
                Spacer(minLength: 0)
                Text(model.remainingText)
                    .font(.system(size: 40, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(model.phase.tint)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.2), value: model.remainingText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Running or paused: the ruler follows the remaining time.
    private var rulerFollowsCountdown: Bool {
        model.isRunning || model.remaining < Double(model.selectedMinutes * 60) - 0.5
    }

    private var primaryButton: some View {
        let running = model.isRunning
        let paused = !running && model.remaining < Double(model.selectedMinutes * 60)
        let title = running ? String(localized: "Pause") : paused ? String(localized: "Resume") : String(localized: "Start Timer")
        return Button { running ? model.pause() : model.start() } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.phase.tint)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(model.phase.tint.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Phase chip: click to cycle Focus → Short → Long.
    private var phaseMenu: some View {
        Button {
            let all = PomodoroPhase.allCases
            let next = all[(all.firstIndex(of: model.phase)! + 1) % all.count]
            model.select(next)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.phase.symbol).font(.system(size: 10, weight: .semibold))
                Text(model.phase.shortTitle)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.4 : 1)
        .help(String(localized: "Switch phase"))
    }

}
