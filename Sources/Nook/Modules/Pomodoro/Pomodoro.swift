import SwiftUI

// CONTRACT STUB — replace implementation, keep public API.
enum PomodoroPhase: String {
    case focus, shortBreak, longBreak
    var symbol: String { self == .focus ? "brain.head.profile" : "cup.and.saucer.fill" }
    var tint: Color { self == .focus ? .orange : .green }
}

@MainActor
final class PomodoroModel: ObservableObject {
    static let shared = PomodoroModel()
    @Published var phase: PomodoroPhase = .focus
    @Published var isRunning = false
    @Published var remaining: TimeInterval = 25 * 60
    var remainingText: String { String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60) }
    func start() {}
    func pause() {}
    func reset() {}
    func skip() {}
}

struct PomodoroView: View { var body: some View { Text("Focus") } }
