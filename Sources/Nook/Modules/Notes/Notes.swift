import Combine
import SwiftUI

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    /// The single scratchpad document.
    @Published var text: String = ""

    private let fileURL = Pref.dataDirectory.appendingPathComponent("notes.md")
    private var autosave: AnyCancellable?

    init() {
        load()
        // Autosave 0.5s after typing stops.
        autosave = $text
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] value in self?.write(value) }
    }

    /// Write pending text to disk immediately (called on quit).
    func flush() {
        autosave?.cancel()
        autosave = nil
        write(text)
    }

    var characterCount: Int { text.count }

    // MARK: - Internals

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        text = String(data: data, encoding: .utf8) ?? ""
    }

    private func write(_ value: String) {
        try? value.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}

struct NotesView: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.text)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                if store.text.isEmpty {
                    Text("Start typing…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 8).padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                Text("\(store.characterCount) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    copyAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copied" : "Copy")
                    }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(store.text.isEmpty)
            }
        }
        .padding(.bottom, 2)
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
