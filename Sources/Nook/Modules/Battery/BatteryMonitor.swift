import Foundation
import IOKit.ps
import SwiftUI

private func batteryPowerSourceCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        monitor.handlePowerSourceUpdate(isInitial: false)
    }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published var level: Int = 100
    @Published var isCharging = false
    @Published var isPluggedIn = false

    private var runLoopSource: CFRunLoopSource?
    private var hasBattery = false
    private var didWarnLowBattery = false

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }

        handlePowerSourceUpdate(isInitial: true)
        guard hasBattery else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(batteryPowerSourceCallback, selfPtr)?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
    }

    fileprivate func handlePowerSourceUpdate(isInitial: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            hasBattery = false
            return
        }

        var foundBattery = false
        var newLevel = level
        var newCharging = isCharging
        var newPluggedIn = isPluggedIn

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let currentCap = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int,
                  maxCap > 0 else {
                continue
            }

            foundBattery = true
            newLevel = max(0, min(100, Int((Double(currentCap) / Double(maxCap)) * 100.0 + 0.5)))
            newCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            let powerState = (desc[kIOPSPowerSourceStateKey as String] as? String) ?? ""
            newPluggedIn = (powerState == (kIOPSACPowerValue as String))
            break
        }

        hasBattery = foundBattery
        guard foundBattery else { return }

        let oldPluggedIn = isPluggedIn
        level = newLevel
        isCharging = newCharging
        isPluggedIn = newPluggedIn

        if newPluggedIn || newCharging {
            didWarnLowBattery = false
        }

        guard !isInitial else { return }

        if newPluggedIn != oldPluggedIn {
            if newPluggedIn {
                NookState.shared.show(
                    NookActivity(
                        id: "battery",
                        symbol: "bolt.fill",
                        tint: .green,
                        progress: Double(newLevel) / 100.0,
                        trailingText: "\(newLevel)%",
                        duration: 2.5
                    )
                )
            } else {
                NookState.shared.show(
                    NookActivity(
                        id: "battery",
                        symbol: Self.batterySymbol(for: newLevel),
                        tint: .white,
                        trailingText: "\(newLevel)%",
                        duration: 2.0
                    )
                )
            }
        }

        let threshold = UserDefaults.standard.integer(forKey: Pref.lowBatteryThreshold)
        let effectiveThreshold = threshold > 0 ? threshold : 20
        if !newCharging && !newPluggedIn && newLevel <= effectiveThreshold && !didWarnLowBattery {
            didWarnLowBattery = true
            NookState.shared.show(
                NookActivity(
                    id: "battery",
                    symbol: "battery.25percent",
                    tint: .red,
                    trailingText: "\(newLevel)%",
                    duration: 4.0
                )
            )
        }
    }

    private static func batterySymbol(for level: Int) -> String {
        switch level {
        case 88...100:
            return "battery.100percent"
        case 63..<88:
            return "battery.75percent"
        case 38..<63:
            return "battery.50percent"
        case 13..<38:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }
}
