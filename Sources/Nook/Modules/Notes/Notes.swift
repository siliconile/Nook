import Combine
import SwiftUI

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    /// The single scratchpad document (Markdown).
    @Published var text: String = ""
    /// Laid-out text height reported by the editor (drives the notch height; not saved).
    @Published var contentHeight: CGFloat = 0

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
    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }

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
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MarkdownEditor(text: $store.text) { height in
                    if abs(store.contentHeight - height) > 0.5 { store.contentHeight = height }
                }
                if store.text.isEmpty {
                    Text("Start typing… Markdown works: # heading, **bold**, - [ ] todo")
                        .font(Theme.body)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

            Spacer().frame(height: NookState.ListMetrics.gap)

            HStack(spacing: Theme.smallSpacing) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Markdown")
                Text("·")
                Text("\(store.wordCount) words")
                Spacer()
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", size: 11, frame: 20,
                           tint: copied ? .green : Theme.tertiaryText, help: copied ? "Copied" : "Copy as Markdown") {
                    copyAll()
                }
                .disabled(store.text.isEmpty)
                .opacity(store.text.isEmpty ? 0.4 : 1)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 6)
            .frame(height: NookState.ListMetrics.footerHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
