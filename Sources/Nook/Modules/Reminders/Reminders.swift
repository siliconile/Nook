import AppKit
import EventKit
import SwiftUI

struct ReminderItem: Identifiable, Equatable {
    let id: String
    var title: String
    var dueDate: Date?
    var hasDueTime: Bool = true
    var isOverdue: Bool
    var color: Color
    var listTitle: String
}

struct ReminderList: Identifiable, Equatable {
    let id: String
    var title: String
    var color: Color
}

@MainActor
final class RemindersModel: ObservableObject {
    static let shared = RemindersModel()

    @Published var reminders: [ReminderItem] = []
    @Published var lists: [ReminderList] = []
    @Published var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published var completingIDs: Set<String> = []

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    private let store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var completionTasks: [String: Task<Void, Never>] = [:]
    private var isRequestingAccess = false
    private var activeFetchRequest: Any?
    private var refreshGeneration: UInt64 = 0
    private var needsRefreshAfterCompletion = false

    private init() {}

    func start() {
        registerStoreObserverIfNeeded()
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

        if isAuthorized {
            refresh()
            return
        }

        guard !isRequestingAccess else { return }
        isRequestingAccess = true

        Task { @MainActor in
            defer { self.isRequestingAccess = false }
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            self.authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
            if granted || self.isAuthorized {
                self.refresh()
            }
        }
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if let activeFetchRequest {
            store.cancelFetchRequest(activeFetchRequest)
            self.activeFetchRequest = nil
        }

        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard isAuthorized else {
            reminders = []
            lists = []
            return
        }

        let calendars = store.calendars(for: .reminder)
        lists = calendars.map { cal in
            ReminderList(
                id: cal.calendarIdentifier,
                title: cal.title,
                color: Self.color(from: cal.cgColor)
            )
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars.isEmpty ? nil : calendars
        )

        activeFetchRequest = store.fetchReminders(matching: predicate) { [weak self] fetched in
            let now = Date()
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            let rawItems: [(item: ReminderItem, creationDate: Date?)] = (fetched ?? []).compactMap { rem in
                guard !rem.isCompleted else { return nil }
                let id = rem.calendarItemIdentifier
                let title = (rem.title?.isEmpty == false) ? rem.title! : String(localized: "Untitled")
                let hasTime = rem.dueDateComponents?.hour != nil
                let dueDate = rem.dueDateComponents.flatMap { calendar.date(from: $0) }
                let isOverdue: Bool
                if let dueDate {
                    isOverdue = hasTime ? (dueDate < now) : (calendar.startOfDay(for: dueDate) < startOfToday)
                } else {
                    isOverdue = false
                }
                let color = Self.color(from: rem.calendar?.cgColor)
                let listTitle = rem.calendar?.title ?? ""
                let item = ReminderItem(
                    id: id,
                    title: title,
                    dueDate: dueDate,
                    hasDueTime: hasTime,
                    isOverdue: isOverdue,
                    color: color,
                    listTitle: listTitle
                )
                return (item: item, creationDate: rem.creationDate)
            }

            let sorted = rawItems.sorted { lhs, rhs in
                switch (lhs.item.dueDate, rhs.item.dueDate) {
                case let (d1?, d2?):
                    if d1 != d2 { return d1 < d2 }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                let c1 = lhs.creationDate ?? .distantPast
                let c2 = rhs.creationDate ?? .distantPast
                if c1 != c2 { return c1 < c2 }
                return lhs.item.title < rhs.item.title
            }.map(\.item)

            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.activeFetchRequest = nil
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.reminders = sorted
                }
            }
        }
    }

    func toggleComplete(_ id: String) {
        if let existingTask = completionTasks[id] {
            existingTask.cancel()
            completionTasks.removeValue(forKey: id)
            completingIDs.remove(id)
            if completionTasks.isEmpty && needsRefreshAfterCompletion {
                needsRefreshAfterCompletion = false
                refresh()
            }
            return
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            _ = completingIDs.insert(id)
        }

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.completionTasks.removeValue(forKey: id)

            var didSave = false
            if let item = self.store.calendarItem(withIdentifier: id) as? EKReminder {
                item.isCompleted = true
                item.completionDate = Date()
                do {
                    try self.store.save(item, commit: true)
                    didSave = true
                } catch {
                    didSave = false
                }
            }

            withAnimation(.easeInOut(duration: 0.25)) {
                if didSave {
                    self.reminders.removeAll { $0.id == id }
                }
                self.completingIDs.remove(id)
            }

            if self.completionTasks.isEmpty && self.needsRefreshAfterCompletion {
                self.needsRefreshAfterCompletion = false
                self.refresh()
            }
        }
        completionTasks[id] = task
    }

    func toggleComplete(id: String) {
        toggleComplete(id)
    }

    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAuthorized else { return }
        guard let calendar = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first else {
            return
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = calendar

        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            // Ignore save failures if calendar is read-only
        }
    }

    func add(_ title: String) {
        add(title: title)
    }

    private func registerStoreObserverIfNeeded() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.completionTasks.isEmpty else {
                    self.needsRefreshAfterCompletion = true
                    return
                }
                self.refresh()
            }
        }
    }

    nonisolated private static func color(from cgColor: CGColor?) -> Color {
        if let cgColor, let nsColor = NSColor(cgColor: cgColor) {
            return Color(nsColor: nsColor)
        }
        return Color.blue
    }
}

struct RemindersView: View {
    @ObservedObject private var model = RemindersModel.shared
    @State private var newReminderTitle = ""
    @State private var hoveredID: String?
    @FocusState private var fieldFocused: Bool

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
    )

    var body: some View {
        Group {
            if model.isAuthorized {
                authorizedContent
            } else {
                unauthorizedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.start()
        }
    }

    private var authorizedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.smallSpacing) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Add a reminder", text: $newReminderTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.primary)
                    .focusEffectDisabled()
                    .focused($fieldFocused)
                    .onSubmit {
                        submitNewReminder()
                    }
                if !newReminderTitle.isEmpty {
                    Button(action: { newReminderTitle = "" }) {
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

            Spacer()
                .frame(height: NookState.ListMetrics.gap)

            if model.reminders.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("No reminders")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: NookState.ListMetrics.emptyHeight)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.reminders) { item in
                            reminderRow(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Spacer()
                    .frame(height: NookState.ListMetrics.gap)

                HStack(spacing: Theme.smallSpacing) {
                    Text("\(model.reminders.count) reminders")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: NookState.ListMetrics.footerHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func reminderRow(_ item: ReminderItem) -> some View {
        let isCompleting = model.completingIDs.contains(item.id)
        let isHovered = hoveredID == item.id
        return HStack(spacing: 10) {
            Button {
                model.toggleComplete(item.id)
            } label: {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isCompleting ? Color.green : Theme.tertiaryText)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(Theme.body)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .strikethrough(isCompleting, color: Theme.tertiaryText)
                .foregroundStyle(isCompleting ? Theme.tertiaryText : Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let due = item.dueDate {
                Text(Self.formatRelativeDate(due, hasTime: item.hasDueTime))
                    .font(Theme.caption)
                    .foregroundStyle(item.isOverdue ? Color.red : Theme.tertiaryText)
                    .lineLimit(1)
            }

            Circle()
                .fill(item.color)
                .frame(width: 7, height: 7)
                .help(item.listTitle)
        }
        .padding(.horizontal, 10)
        .frame(height: NookState.ListMetrics.rowHeight)
        .background(
            isHovered ? Theme.fill : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var unauthorizedContent: some View {
        VStack(spacing: Theme.smallSpacing) {
            Image(systemName: "list.bullet.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.tertiaryText)

            Text("Reminders access required")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)

            Button {
                if let url = Self.privacySettingsURL {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, Theme.spacing)
                    .frame(height: 24)
                    .background(Theme.fillStrong, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitNewReminder() {
        let trimmed = newReminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.add(title: trimmed)
        newReminderTitle = ""
    }

    private static func formatRelativeDate(_ date: Date, hasTime: Bool = true) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            guard hasTime else { return String(localized: "Today") }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return String(localized: "Today, \(formatter.string(from: date))")
        } else if calendar.isDateInTomorrow(date) {
            return String(localized: "Tomorrow")
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }
}
