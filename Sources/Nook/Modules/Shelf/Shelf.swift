import SwiftUI

// CONTRACT STUB — replace implementation, keep public API.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    /// Called from the notch-wide drop target with file-URL item providers.
    func add(providers: [NSItemProvider]) {}
}
struct ShelfView: View { var body: some View { Text("Shelf") } }
