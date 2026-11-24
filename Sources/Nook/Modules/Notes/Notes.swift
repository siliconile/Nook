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
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                TextField("Start typing…", text: $store.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.primary)
                    .lineSpacing(NookState.ListMetrics.noteLineHeight - 16)
                    .multilineTextAlignment(.leading)
                    .focusEffectDisabled()
                    .focused($isFocused)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: NookState.ListMetrics.noteLineHeight * 4,
                        alignment: .topLeading
                    )
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            Spacer()
                .frame(height: NookState.ListMetrics.gap)

            HStack(spacing: Theme.smallSpacing) {
                Text("\(store.characterCount) characters")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                IconButton(
                    symbol: copied ? "checkmark" : "doc.on.doc",
                    size: 11,
                    frame: 20,
                    tint: copied ? .green : Theme.tertiaryText,
                    help: copied ? "Copied" : "Copy"
                ) {
                    copyAll()
                }
                .disabled(store.text.isEmpty)
                .opacity(store.text.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 10)
            .frame(height: NookState.ListMetrics.footerHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { isFocused = true }
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
