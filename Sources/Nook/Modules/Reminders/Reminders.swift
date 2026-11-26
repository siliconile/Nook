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
    /// Add-field state, published so the notch can size itself around the composer.
    @Published var composer: ComposerMode = .idle

    enum ComposerMode: Equatable {
        case idle
        /// Title typed: quick time chips are shown.
        case chips
        /// "Pick time…": day chips and the time wheel are shown.
        case picker
    }

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
    private var dueAlertTask: Task<Void, Never>?
    /// Reminders already announced in the notch, so a refresh doesn't repeat them.
    private var announcedIDs: Set<String> = []

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
                self.scheduleDueAlert()
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

    /// Adds a reminder to the default list. With `due`, it gets a date, a time and an alarm,
    /// so Reminders on every device notifies too.
    func add(title: String, due: Date? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAuthorized else { return }
        guard let calendar = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first else {
            return
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = calendar
        if let due { Self.setDue(reminder, due) }

        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            // Ignore save failures if calendar is read-only
        }
    }

    /// Moves a reminder to a new time (and its alarm with it).
    func snooze(_ id: String, to date: Date) {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        Self.setDue(item, date)
        announcedIDs.remove(id)
        do {
            try store.save(item, commit: true)
            refresh()
        } catch {}
    }

    private static func setDue(_ reminder: EKReminder, _ date: Date) {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: date)
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        reminder.addAlarm(EKAlarm(absoluteDate: date))
    }

    // MARK: - Due alerts in the notch

    /// Timed reminders, soonest first; overdue ones lead.
    var timed: [ReminderItem] { reminders.filter { $0.dueDate != nil && $0.hasDueTime } }

    /// What the "Next" card shows: the most overdue timed reminder, else the next upcoming one.
    var nextUp: ReminderItem? { timed.first }

    /// Sleeps until the next timed reminder is due, then pops it out of the closed notch.
    /// Clicking the notch then opens Reminders, where the Next card has Done / Snooze.
    private func scheduleDueAlert() {
        dueAlertTask?.cancel()
        let now = Date()
        guard let next = timed.first(where: { ($0.dueDate ?? now) > now && !announcedIDs.contains($0.id) }),
              let due = next.dueDate else { return }
        dueAlertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.announcedIDs.insert(next.id)
            NSSound(named: "Glass")?.play()
            NookState.shared.show(NookActivity(
                id: "reminder", symbol: "bell.fill", tint: .orange,
                title: next.title, trailingText: String(localized: "Now"), duration: 8))
            self.refresh() // marks it overdue and schedules the next one
        }
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

/// Reminders, time-first: add with a time in one step, a "Next" card with a countdown,
/// and an agenda grouped Overdue / Today / Upcoming / Anytime with quick snooze.
struct RemindersView: View {
    @ObservedObject private var model = RemindersModel.shared
    @State private var title = ""
    @State private var hoveredID: String?
    @FocusState private var fieldFocused: Bool
    // Time picker ("Pick time…"): day offset from today and quarter-hour of the day.
    @State private var pickDay = 0
    @State private var pickQuarter = 0

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
    )

    // MARK: Layout metrics (shared with NookState for the notch height)

    static let inputHeight: CGFloat = 32
    static let chipsHeight: CGFloat = 26
    static let pickerHeight: CGFloat = 26 + 6 + 52
    static let gap: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 18
    static let minBodyHeight: CGFloat = 112

    static func contentHeight(_ model: RemindersModel) -> CGFloat {
        var h = inputHeight + gap
        switch model.composer {
        case .idle: break
        case .chips: h += chipsHeight + gap
        case .picker: h += pickerHeight + gap
        }
        let sections = agendaSections(model.reminders, excluding: model.nextUp?.id)
        let agenda = sections.reduce(CGFloat(0)) { $0 + headerHeight + CGFloat($1.items.count) * rowHeight }
        return h + max(minBodyHeight, agenda)
    }

    var body: some View {
        Group {
            if model.isAuthorized {
                authorizedContent
            } else {
                unauthorizedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if !Snapshot.isRendering { model.start() } }
        .onDisappear { if !Snapshot.isRendering { model.composer = .idle } }
    }

    private var authorizedContent: some View {
        VStack(spacing: Self.gap) {
            inputRow
            switch model.composer {
            case .idle: EmptyView()
            case .chips: chipsRow.transition(.opacity)
            case .picker: pickerPanel.transition(.opacity)
            }
            HStack(alignment: .top, spacing: 10) {
                NextCard(item: model.nextUp, completing: model.nextUp.map { model.completingIDs.contains($0.id) } ?? false)
                    .frame(width: 172)
                agenda
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: model.composer)
    }

    // MARK: Add

    private var inputRow: some View {
        HStack(spacing: Theme.smallSpacing) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.tertiaryText)
            TextField("Add a reminder", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.primary)
                .focusEffectDisabled()
                .focused($fieldFocused)
                .onSubmit { submit(due: model.composer == .picker ? pickedDate : nil) }
                .onExitCommand { clear() }
                .onChange(of: title) { _, t in
                    if t.isEmpty { model.composer = .idle }
                    else if model.composer == .idle { model.composer = .chips }
                }
            if !title.isEmpty {
                Text(model.composer == .picker ? "↩ \(Self.dayTime(pickedDate))" : String(localized: "↩ no time"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                Button(action: clear) {
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
        .frame(height: Self.inputHeight)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    /// One click adds the typed reminder at that time.
    private var chipsRow: some View {
        let now = Date()
        let cal = Calendar.current
        var chips: [(String, Date)] = [
            (String(localized: "In 15 min"), now.addingTimeInterval(15 * 60)),
            (String(localized: "In 1 hour"), now.addingTimeInterval(60 * 60)),
        ]
        if let tonight = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now), tonight.timeIntervalSince(now) > 30 * 60 {
            chips.append((String(localized: "Tonight \(Self.time(tonight))"), tonight))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            chips.append((String(localized: "Tomorrow \(Self.time(nine))"), nine))
        }
        return HStack(spacing: 6) {
            ForEach(chips, id: \.0) { label, date in
                Chip(label: label, symbol: "clock") { submit(due: date) }
            }
            Chip(label: String(localized: "Pick time…"), symbol: "dial.medium") { openPicker() }
            Spacer(minLength: 0)
        }
        .frame(height: Self.chipsHeight)
    }

    private var pickerPanel: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { offset in
                    let day = cal.date(byAdding: .day, value: offset, to: today)!
                    let label = offset == 0 ? String(localized: "Today")
                        : offset == 1 ? String(localized: "Tomorrow")
                        : day.formatted(.dateTime.weekday(.abbreviated))
                    Chip(label: label, selected: pickDay == offset) { pickDay = offset }
                }
                Spacer(minLength: 4)
                Button { submit(due: pickedDate) } label: {
                    Text("Add")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(pickedDate > Date() ? Color.orange : Theme.tertiaryText)
                        .padding(.horizontal, 12)
                        .frame(height: Self.chipsHeight)
                        .background(Color.orange.opacity(pickedDate > Date() ? 0.18 : 0.06), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(pickedDate <= Date())
            }
            .frame(height: Self.chipsHeight)

            WheelPicker(value: pickQuarter, range: 0...95, majorEvery: 4, tint: .orange, pointsPerStep: 11,
                        label: { Self.hourLabel($0 / 4) }, onCommit: { pickQuarter = $0 })
                .frame(height: 52)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(height: Self.pickerHeight)
    }

    private var pickedDate: Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: pickDay, to: cal.startOfDay(for: Date()))!
        return day.addingTimeInterval(TimeInterval(pickQuarter * 15 * 60))
    }

    private func openPicker() {
        // Start at the next quarter hour, one hour from now.
        let cal = Calendar.current
        let target = Date().addingTimeInterval(60 * 60)
        let minutes = cal.component(.hour, from: target) * 60 + cal.component(.minute, from: target)
        pickQuarter = min(95, (minutes + 14) / 15)
        pickDay = cal.isDateInToday(target) ? 0 : 1
        model.composer = .picker
        fieldFocused = true
    }

    private func submit(due: Date?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let due, due <= Date() { return }
        model.add(title: trimmed, due: due)
        clear()
    }

    private func clear() {
        title = ""
        model.composer = .idle
    }

    // MARK: Agenda

    struct Section: Identifiable {
        let id: String
        let title: String
        let tint: Color
        let items: [ReminderItem]
    }

    static func agendaSections(_ items: [ReminderItem], excluding excluded: String?) -> [Section] {
        let cal = Calendar.current
        let rest = items.filter { $0.id != excluded }
        let overdue = rest.filter(\.isOverdue)
        let today = rest.filter { !$0.isOverdue && $0.dueDate.map(cal.isDateInToday) == true }
        let upcoming = rest.filter { !$0.isOverdue && $0.dueDate != nil && $0.dueDate.map(cal.isDateInToday) == false }
        let anytime = rest.filter { $0.dueDate == nil }
        return [
            Section(id: "overdue", title: String(localized: "Overdue"), tint: .red, items: overdue),
            Section(id: "today", title: String(localized: "Today"), tint: Theme.secondaryText, items: today),
            Section(id: "upcoming", title: String(localized: "Upcoming"), tint: Theme.secondaryText, items: upcoming),
            Section(id: "anytime", title: String(localized: "Anytime"), tint: Theme.secondaryText, items: anytime),
        ].filter { !$0.items.isEmpty }
    }

    private var agenda: some View {
        let sections = Self.agendaSections(model.reminders, excluding: model.nextUp?.id)
        return Group {
            if sections.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(model.reminders.isEmpty ? String(localized: "No reminders") : String(localized: "Nothing else"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ImageRenderer can't draw a ScrollView, so snapshots get the plain list.
                if Snapshot.isRendering {
                    agendaList(sections)
                } else {
                    ScrollView(.vertical, showsIndicators: false) { agendaList(sections) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func agendaList(_ sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                Text(section.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(section.tint)
                    .frame(height: Self.headerHeight, alignment: .bottomLeading)
                    .padding(.leading, 8)
                ForEach(section.items) { row($0) }
            }
        }
    }

    private func row(_ item: ReminderItem) -> some View {
        let completing = model.completingIDs.contains(item.id)
        let hovered = hoveredID == item.id
        return HStack(spacing: 8) {
            Text(Self.agendaTime(item))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(item.isOverdue ? Color.red : item.color)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)
            Text(item.title)
                .font(Theme.secondary)
                .lineLimit(1)
                .strikethrough(completing, color: Theme.tertiaryText)
                .foregroundStyle(completing ? Theme.tertiaryText : Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovered || completing {
                SnoozeButtons(id: item.id, compact: true)
                RowIcon(symbol: completing ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: completing ? .green : Theme.secondaryText, help: String(localized: "Done")) {
                    model.toggleComplete(item.id)
                }
            } else {
                Circle().fill(item.color).frame(width: 6, height: 6).help(item.listTitle)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(hovered ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { h in
            if h { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
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

    // MARK: Formatting

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "Today 3:15 PM", "Tomorrow 9:00 AM", "Tue 9:00 AM".
    static func dayTime(_ date: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(date) ? String(localized: "Today")
            : cal.isDateInTomorrow(date) ? String(localized: "Tomorrow")
            : date.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) \(time(date))"
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// Left column of an agenda row.
    static func agendaTime(_ item: ReminderItem) -> String {
        guard let due = item.dueDate else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(due) { return item.hasDueTime ? time(due) : String(localized: "Today") }
        if cal.isDateInTomorrow(due) { return String(localized: "Tomorrow") }
        if cal.isDateInYesterday(due) { return String(localized: "Yesterday") }
        if abs(due.timeIntervalSinceNow) < 6 * 24 * 3600 { return due.formatted(.dateTime.weekday(.abbreviated)) }
        return due.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The soonest timed reminder (or the most overdue one), with a live countdown,
/// Done and Snooze.
private struct NextCard: View {
    let item: ReminderItem?
    let completing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item, let due = item.dueDate {
                Text(item.isOverdue ? String(localized: "OVERDUE") : String(localized: "NEXT"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(item.isOverdue ? Color.red : Color.orange)
                Text(Calendar.current.isDateInToday(due) ? RemindersView.time(due) : RemindersView.dayTime(due))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(item.isOverdue ? Color.red : Theme.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(item.title)
                    .font(Theme.secondary)
                    .foregroundStyle(completing ? Theme.tertiaryText : Theme.secondaryText)
                    .strikethrough(completing)
                    .lineLimit(2)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(due, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    RowIcon(symbol: completing ? "checkmark.circle.fill" : "checkmark.circle",
                            tint: completing ? .green : Theme.secondaryText, help: String(localized: "Done")) {
                        RemindersModel.shared.toggleComplete(item.id)
                    }
                    SnoozeButtons(id: item.id, compact: false)
                }
            } else {
                Spacer(minLength: 0)
                Image(systemName: "bell.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.tertiaryText)
                Text("Nothing scheduled")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: RemindersView.minBodyHeight)
        .background(
            (item?.isOverdue == true ? Color.red.opacity(0.12) : Theme.fill),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// +10m / +1h / Tomorrow 9.
private struct SnoozeButtons: View {
    let id: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 3) {
            snooze("+10m", String(localized: "Snooze 10 minutes")) { Date().addingTimeInterval(10 * 60) }
            snooze("+1h", String(localized: "Snooze 1 hour")) { Date().addingTimeInterval(60 * 60) }
            if !compact {
                snooze(String(localized: "Tmrw"), String(localized: "Tomorrow at 9")) {
                    let cal = Calendar.current
                    let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
                    return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
                }
            }
        }
    }

    private func snooze(_ label: String, _ help: String, _ date: @escaping () -> Date) -> some View {
        Button { RemindersModel.shared.snooze(id, to: date()) } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(Theme.fillStrong, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RowIcon: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct Chip: View {
    let label: String
    var symbol: String? = nil
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
                Text(label).lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? Color.orange : (hover ? Theme.primary : Theme.secondaryText))
            .padding(.horizontal, 9)
            .frame(height: RemindersView.chipsHeight)
            .background(selected ? Color.orange.opacity(0.18) : (hover ? Theme.fillStrong : Theme.fill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
