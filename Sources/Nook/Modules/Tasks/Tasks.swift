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
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: Theme.smallSpacing) {
            addField

            if store.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(store.items) { item in
                            TaskRow(item: item) {
                                store.toggle(id: item.id)
                            } onDelete: {
                                store.delete(id: item.id)
                            }
                        }
                    }
                }

                footer
            }
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Pieces

    private var addField: some View {
        HStack(spacing: Theme.smallSpacing) {
            Image(systemName: "plus.circle")
                .font(.system(size: Theme.rowIcon))
                .foregroundStyle(Theme.tertiaryText)
            TextField("Add a task", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.primary)
                .focused($fieldFocused)
                .onSubmit(addDraft)
            if !draft.isEmpty {
                Button(action: { draft = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.smallIcon))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.spacing)
        .frame(height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
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
                    .foregroundStyle(Theme.secondaryText)
                    .contentShape(Rectangle())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.smallSpacing) {
            Image(systemName: "checklist")
                .font(.system(size: Theme.controlIcon))
                .foregroundStyle(Theme.tertiaryText)
            Text("No tasks yet")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
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
        HStack(spacing: Theme.smallSpacing) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.rowIcon))
                    .foregroundStyle(item.isDone ? Color.green : Theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(Theme.body)
                .lineLimit(1)
                .strikethrough(item.isDone, color: Theme.tertiaryText)
                .foregroundStyle(item.isDone ? Theme.tertiaryText : Theme.primary)

            Spacer(minLength: Theme.smallSpacing)

            if hovered {
                IconButton(
                    symbol: "trash",
                    size: Theme.rowIcon,
                    frame: 24,
                    tint: Theme.secondaryText,
                    help: "Delete",
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, Theme.smallSpacing)
        .frame(height: 28)
        .background(
            hovered ? Theme.fill : .clear,
            in: RoundedRectangle(cornerRadius: Theme.controlRadius)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
