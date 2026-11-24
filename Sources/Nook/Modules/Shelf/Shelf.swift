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
                } else if let str = data as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("file:"), let parsed = URL(string: trimmed) {
                        url = parsed
                    } else {
                        url = URL(fileURLWithPath: trimmed)
                    }
                }
                if let rawURL = url {
                    let normalized = (rawURL as NSURL).filePathURL?.standardizedFileURL ?? rawURL.standardizedFileURL
                    lock.lock(); urls.append(normalized); lock.unlock()
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
        var existing = Set(items.map { $0.url.standardizedFileURL.path })
        var addedCount = 0
        for rawURL in urls {
            let url = (rawURL as NSURL).filePathURL?.standardizedFileURL ?? rawURL.standardizedFileURL
            let path = url.path
            guard !path.isEmpty, !existing.contains(path) else { continue }
            existing.insert(path)
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
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(state.isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
            content
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(
                    state.isDropTargeted ? Color.accentColor : Theme.separator,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        )
        .overlay(alignment: .topTrailing) {
            if !store.items.isEmpty {
                Button("Clear") { store.clear() }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.smallSpacing)
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                    .help("Remove all files from the shelf")
                    .padding(.top, 4)
                    .padding(.trailing, Theme.smallSpacing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            VStack(spacing: Theme.smallSpacing) {
                Image(systemName: "tray")
                    .font(.system(size: Theme.controlIcon))
                    .foregroundStyle(Theme.tertiaryText)
                Text("Drop files here")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.smallSpacing) {
                    ForEach(store.items) { item in
                        ShelfTile(item: item)
                    }
                }
                .padding(.leading, Theme.spacing)
                .padding(.trailing, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @State private var hovered = false

    var body: some View {
        VStack(spacing: Theme.smallSpacing) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            Text(item.name)
                .font(Theme.caption)
                .foregroundStyle(Theme.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 4)
        .frame(width: 76, height: 92)
        .background(
            hovered ? Theme.fill : .clear,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button { remove() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.smallIcon))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .onTapGesture(count: 2) { ShelfStore.shared.open(id: item.id) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
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
