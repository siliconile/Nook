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
        VStack(spacing: 8) {
            addField

            if store.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(store.items) { item in
                            TaskRow(item: item) {
                                store.toggle(id: item.id)
                            } onDelete: {
                                store.delete(id: item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                footer
            }
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Pieces

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            TextField("Add a task…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(addDraft)
            if !draft.isEmpty {
                Button(action: { draft = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(store.pendingCount) left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if store.hasCompleted {
                Button("Clear completed") { store.clearCompleted() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text("No tasks yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
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
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.isDone ? Color.blue : .white.opacity(0.4))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .strikethrough(item.isDone, color: .white.opacity(0.5))
                .foregroundStyle(item.isDone ? .white.opacity(0.45) : .white)

            Spacer(minLength: 4)

            if hovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(hovered ? Color.white.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 }
    }
}
