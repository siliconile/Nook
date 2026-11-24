import AppKit
import Combine
import SwiftUI

/// The three phases of a pomodoro cycle.
enum PomodoroPhase: String, CaseIterable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    /// Compact label for the picker buttons.
    var shortTitle: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short"
        case .longBreak: "Long"
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
            let message = phase == .focus ? "Focus time" : "Break time"
            NSSound(named: "Glass")?.play()
            NookState.shared.show(NookActivity(
                id: "pomodoro",
                symbol: phase.symbol,
                tint: phase.tint,
                title: message,
                trailingText: "Done",
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

struct PomodoroView: View {
    @ObservedObject private var model = PomodoroModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            ring
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Ring

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Theme.fill, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.003, model.progress))
                .stroke(
                    model.phase.tint,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: model.progress)
            VStack(spacing: 2) {
                Text(model.remainingText)
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, Theme.spacing)
                Text(model.phase.title)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: 104, height: 104)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            // Phase picker.
            HStack(spacing: Theme.smallSpacing) {
                ForEach(PomodoroPhase.allCases, id: \.rawValue) { phase in
                    Button { model.select(phase) } label: {
                        Text(phase.shortTitle)
                            .font(Theme.caption)
                            .foregroundStyle(model.phase == phase ? Theme.primary : Theme.secondaryText)
                            .padding(.horizontal, Theme.spacing)
                            .frame(height: 24)
                            .background(
                                model.phase == phase ? Theme.fillStrong : Theme.fill,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Session dots for the current cycle.
            HStack(spacing: Theme.smallSpacing) {
                ForEach(0..<model.sessionsBeforeLong, id: \.self) { index in
                    Capsule()
                        .fill(index < model.completedFocusSessions
                              ? Color.orange
                              : Theme.fillStrong)
                        .frame(width: 14, height: 4)
                }
            }

            // Transport buttons.
            HStack(spacing: Theme.spacing) {
                Button { model.isRunning ? model.pause() : model.start() } label: {
                    Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: Theme.rowIcon, weight: .semibold))
                        .foregroundStyle(model.phase.tint)
                        .frame(width: 36, height: 36)
                        .background(model.phase.tint.opacity(0.2), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.isRunning ? "Pause" : "Start")

                IconButton(
                    symbol: "arrow.counterclockwise",
                    size: Theme.rowIcon,
                    frame: 32,
                    tint: Theme.secondaryText,
                    help: "Reset"
                ) {
                    model.reset()
                }

                IconButton(
                    symbol: "forward.end.fill",
                    size: Theme.rowIcon,
                    frame: 32,
                    tint: Theme.secondaryText,
                    help: "Skip phase"
                ) {
                    model.skip()
                }
            }
        }
    }
}
