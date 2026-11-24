import SwiftUI

// CONTRACT STUB — replace implementation, keep public API.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    /// Write pending text to disk immediately (called on quit).
    func flush() {}
}
struct NotesView: View { var body: some View { Text("Notes") } }
