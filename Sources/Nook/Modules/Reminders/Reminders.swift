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
                let title = (rem.title?.isEmpty == false) ? rem.title! : "Untitled"
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.start()
        }
    }

    private var authorizedContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("Reminders")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(model.reminders.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }

                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("New reminder", text: $newReminderTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .onSubmit {
                            submitNewReminder()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )
            }

            if model.reminders.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No incomplete reminders")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(model.reminders) { item in
                            reminderRow(item)
                        }
                    }
                }
                .frame(maxHeight: 138)
            }
        }
    }

    private func reminderRow(_ item: ReminderItem) -> some View {
        let isCompleting = model.completingIDs.contains(item.id)
        return HStack(spacing: 8) {
            Button {
                model.toggleComplete(item.id)
            } label: {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCompleting ? item.color : .white.opacity(0.55))
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(.system(size: 12))
                .strikethrough(isCompleting, color: .white.opacity(0.5))
                .foregroundStyle(.white.opacity(isCompleting ? 0.45 : 0.92))
                .lineLimit(1)

            Spacer(minLength: 6)

            if let due = item.dueDate {
                Text(Self.formatRelativeDate(due, hasTime: item.hasDueTime))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.isOverdue ? Color.red : Color.white.opacity(0.5))
                    .lineLimit(1)
            }

            Circle()
                .fill(item.color)
                .frame(width: 7, height: 7)
                .help(item.listTitle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var unauthorizedContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.circle")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.5))

            Text("Allow access to Reminders to view and complete your items here.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button {
                if let url = Self.privacySettingsURL {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Privacy Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)
        }
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
            guard hasTime else { return "Today" }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Today, \(formatter.string(from: date))"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }
}
