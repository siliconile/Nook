import AppKit

// CONTRACT STUB — replace implementation, keep public API.
@MainActor
final class HUDController {
    static let shared = HUDController()
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestTrust() {}
    func start() {}
    func stop() {}
}
