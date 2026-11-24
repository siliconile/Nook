import Foundation

// CONTRACT STUB — replace implementation, keep public API.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    @Published var level: Int = 100
    @Published var isCharging = false
    @Published var isPluggedIn = false
    func start() {}
    func stop() {}
}
