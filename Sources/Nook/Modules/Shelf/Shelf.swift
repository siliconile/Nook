import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file parked on the shelf.
struct ShelfItem: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let icon: NSImage
    let addedAt: Date

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
        self.name = url.lastPathComponent
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// On-disk representation (plain paths; the app is not sandboxed).
private struct ShelfEntry: Codable {
    var id: UUID
    var path: String
    var addedAt: Date
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    private let fileURL = Pref.dataDirectory.appendingPathComponent("shelf.json")

    init() { load() }

    /// Called from drop targets with file-URL item providers (async; hops to main).
    func add(providers: [NSItemProvider]) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                var url: URL?
                if let data = data as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = data as? URL {
                    url = direct
                } else if let path = data as? String {
                    url = URL(fileURLWithPath: path)
                }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.insert(urls: urls)
        }
    }

    /// Add an array of file URLs directly (dedupes by path).
    func add(urls: [URL]) {
        insert(urls: urls)
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        save()
    }

    func open(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Internals

    private func insert(urls: [URL]) {
        let existing = Set(items.map { $0.url.path })
        var addedCount = 0
        for url in urls where !existing.contains(url.path) {
            items.append(ShelfItem(url: url))
            addedCount += 1
        }
        guard addedCount > 0 else { return }
        save()
        NookState.shared.show(NookActivity(
            id: "shelf",
            symbol: "tray.and.arrow.down.fill",
            tint: .blue,
            trailingText: "+\(addedCount)",
            duration: 1.5
        ))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([ShelfEntry].self, from: data) else { return }
        // Drop items whose file no longer exists.
        items = entries.compactMap { entry in
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ShelfItem(id: entry.id, url: url, addedAt: entry.addedAt)
        }
    }

    private func save() {
        let entries = items.map { ShelfEntry(id: $0.id, path: $0.url.path, addedAt: $0.addedAt) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct ShelfView: View {
    @ObservedObject private var store = ShelfStore.shared
    @ObservedObject private var state = NookState.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(state.isDropTargeted ? Color.blue.opacity(0.12) : Color.white.opacity(0.04))
            content
                .padding(8)
        }
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(state.isDropTargeted ? Color.blue : Color.white.opacity(0.18)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $state.isDropTargeted) { providers in
            store.add(providers: providers)
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Drop files here")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.items) { item in
                            ShelfTile(item: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                VStack {
                    Spacer()
                    Button("Clear") { store.clear() }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                        .help("Remove all files from the shelf")
                    Spacer()
                }
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(.vertical, 8)
        .frame(width: 80, height: 74)
        .background(hovered ? Color.white.opacity(0.12) : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button { remove() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove")
            }
        }
        .onTapGesture(count: 2) { ShelfStore.shared.open(id: item.id) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { ShelfStore.shared.open(id: item.id) }
            Button("Show in Finder") { ShelfStore.shared.revealInFinder(id: item.id) }
            Divider()
            Button("Remove", role: .destructive) { remove() }
        }
        .onHover { hovered = $0 }
    }

    private func remove() {
        ShelfStore.shared.remove(id: item.id)
    }
}
