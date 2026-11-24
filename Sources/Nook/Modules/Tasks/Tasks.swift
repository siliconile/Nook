import SwiftUI

/// A single todo item. Persisted as JSON.
struct TaskItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var isDone = false
    var createdAt = Date()
    var doneAt: Date? = nil
}

@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    /// Pending items first, done items last (kept in this order at all times).
    @Published private(set) var items: [TaskItem] = []

    private let fileURL = Pref.dataDirectory.appendingPathComponent("tasks.json")
    private var saveTask: Task<Void, Never>?

    var pendingCount: Int { items.lazy.filter { !$0.isDone }.count }
    var hasCompleted: Bool { items.contains { $0.isDone } }

    init() { load() }

    // MARK: - Mutations

    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(TaskItem(title: trimmed), at: 0)
        resort()
        scheduleSave()
    }

    func toggle(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        items[index].doneAt = items[index].isDone ? Date() : nil
        resort()
        scheduleSave()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearCompleted() {
        guard hasCompleted else { return }
        items.removeAll { $0.isDone }
        scheduleSave()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
        scheduleSave()
    }

    // MARK: - Persistence (atomic, debounced)

    private func resort() {
        items.sort { a, b in
            switch (a.isDone, b.isDone) {
            case (false, true): return true
            case (true, false): return false
            default: return a.createdAt > b.createdAt
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TaskItem].self, from: data) else { return }
        items = decoded
        resort()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.save()
        }
    }

    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct TasksView: View {
    @ObservedObject private var store = TasksStore.shared
    @State private var draft = ""
    @State private var clearHovered = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addField

            Spacer()
                .frame(height: NookState.ListMetrics.gap)

            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            TaskRow(item: item) {
                                store.toggle(id: item.id)
                            } onDelete: {
                                store.delete(id: item.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Spacer()
                    .frame(height: NookState.ListMetrics.gap)

                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { fieldFocused = true }
    }

    // MARK: - Pieces

    private var addField: some View {
        HStack(spacing: Theme.smallSpacing) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.tertiaryText)
            TextField("Add a task", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.primary)
                .focusEffectDisabled()
                .focused($fieldFocused)
                .onSubmit(addDraft)
            if !draft.isEmpty {
                Button(action: { draft = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.smallIcon))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NookState.ListMetrics.inputHeight)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: Theme.smallSpacing) {
            Text("\(store.pendingCount) left")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            if store.hasCompleted {
                Button("Clear completed") { store.clearCompleted() }
                    .font(Theme.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(clearHovered ? Theme.primary : Theme.secondaryText)
                    .contentShape(Rectangle())
                    .onHover { clearHovered = $0 }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NookState.ListMetrics.footerHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checklist")
                .font(.system(size: 18))
                .foregroundStyle(Theme.tertiaryText)
            Text("No tasks yet")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NookState.ListMetrics.emptyHeight)
    }

    private func addDraft() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.add(title: draft)
        draft = ""
        fieldFocused = true
    }
}

private struct TaskRow: View {
    let item: TaskItem
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isDone ? Color.green : Theme.tertiaryText)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(Theme.body)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .strikethrough(item.isDone, color: Theme.tertiaryText)
                .foregroundStyle(item.isDone ? Theme.tertiaryText : Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hovered {
                IconButton(
                    symbol: "trash",
                    size: 12,
                    frame: 22,
                    tint: Theme.secondaryText,
                    help: String(localized: "Delete"),
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NookState.ListMetrics.rowHeight)
        .background(
            hovered ? Theme.fill : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
