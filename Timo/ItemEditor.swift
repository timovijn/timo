import SwiftUI

struct ItemEditor: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State var item: PlanItem
    @State private var locations: [ItemTextEntry]
    @State private var people: [ItemTextEntry]
    @State private var issue: String?
    /// An edited later day of a repeating item, waiting for the warning to be confirmed.
    @State private var pendingDetach: PlanItem?
    /// Opens another item's editor in place of this one, for Go to original item.
    var openItem: ((PlanItem) -> Void)? = nil
    @Environment(\.undoManager) private var undoManager
    @State private var requestingReminder = false
    @State private var needsNotificationSettings = false
    @State private var editingField: ScheduleField?
    /// Whether carry-over was set by hand. Until then a new item follows its schedule: Anytime
    /// items move on to the next day if unfinished, items with a time stay on their day.
    @State private var carryChosen = false
    /// A picker about to open, once its row has scrolled up to leave it room below.
    @State private var pendingField: ScheduleField?
    @State private var removedDuration: TimeInterval?
    /// Identities for `item.reminders`, kept in the same order, so a button follows its reminder when sorting.
    @State private var reminderIDs: [UUID]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var titleFocused: Bool
    /// Sections whose explanation is open. Explanations start closed, behind a small (i).
    @State private var openInfo: Set<String> = []
    private var existing: Bool { store.item(item.id) != nil }
    init(item: PlanItem, openItem: ((PlanItem) -> Void)? = nil) {
        self.openItem = openItem
        _item = State(initialValue: item)
        _locations = State(initialValue: item.locations.map { ItemTextEntry(text: $0) })
        _people = State(initialValue: item.people.map { ItemTextEntry(text: $0) })
        _reminderIDs = State(initialValue: item.reminders.map { _ in UUID() })
    }
    var body: some View {
        NavigationStack {
            // The reader lets a place or person row scroll well clear of the keyboard.
            ScrollViewReader { form in Form {
                itemStatusSection
                Section {
                    TextField("What’s on your day?", text: $item.title, axis: .vertical)
                        .font(.title3.weight(.medium)).focused($titleFocused)
                        .submitLabel(.done)
                        // The title wraps but stays one line: Return finishes editing instead of adding a break.
                        .onChange(of: item.title) { _, title in
                            guard title.contains(where: \.isNewline) else { return }
                            item.title = title.split(whereSeparator: \.isNewline).joined(separator: " ")
                            titleFocused = false
                        }
                }
                Section {
                    PersonaChips(selection: $item.personas)
                        .padding(.vertical, 2)
                        .sensoryFeedback(.selection, trigger: item.personas)
                } header: {
                    InfoHeader("Persona", isExpanded: infoBinding("persona"))
                } footer: {
                    InfoFooter(isExpanded: openInfo.contains("persona")) {
                        Text("Personas gather items by focus, such as health or work. An item can be in several, or none: tap a persona to add it and again to remove it. Choose one at the top left of your day to see everything in it, past and present."
                             + (item.repeatRule != .never || item.seriesID != nil ? " The original item and its linked items share their personas." : ""))
                    }
                }
                Section {
                    // One line of buttons: the day, then an optional start and duration, each removable.
                    FlowLayout(spacing: 8) {
                        SchedulePill(name: "Day", value: dayName(item.day),
                                     accessibilityValue: item.day.date().formatted(date: .complete, time: .omitted),
                                     isEditing: editing(.day)) {
                            VStack(alignment: .leading, spacing: 16) {
                                ScheduleChips(options: daySuggestions, selected: item.day) { setDay($0); editingField = nil }
                                DatePicker("Day", selection: Binding(get: { item.day.date() }, set: { setDay(Day($0)); editingField = nil }),
                                           displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                            }
                        }
                        SchedulePill(name: "Time", addTitle: "Add time", removeTitle: "Remove time",
                                     value: item.start()?.formatted(date: .omitted, time: .shortened), isEditing: editing(.time),
                                     onAdd: { animate(addTime) }, onRemove: { animate(removeTime) }) {
                            VStack(spacing: 12) {
                                ScheduleChips(options: timeSuggestions, selected: item.minute) { setMinute($0); editingField = nil }
                                DatePicker("Time", selection: Binding(get: { item.start() ?? item.day.date() }, set: { new in
                                    let c = Calendar.current.dateComponents([.hour, .minute], from: new)
                                    setMinute((c.hour ?? 0) * 60 + (c.minute ?? 0))
                                }), displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden()
                            }
                        }
                        if let start = item.start() {
                            SchedulePill(name: "End time", addTitle: "Add end time", addLabel: "End", removeTitle: "Remove end time",
                                         value: item.end.map { endText($0, start: start) },
                                         accessibilityValue: item.end.map { endAccessibilityText($0, start: start) },
                                         isEditing: editing(.end), onRemove: { animate { setEnd(nil) } }) {
                                VStack(alignment: .leading, spacing: 16) {
                                    ScheduleChips(options: durationOptions, selected: item.end.map { Int($0.timeIntervalSince(start) / 60) }, fillsWidth: true) { minutes in
                                        // Stay open so the end time below can be checked or fine-tuned.
                                        animate { setEnd(start.addingTimeInterval(Double(minutes) * 60)) }
                                    }
                                    DatePicker("Ends", selection: Binding(get: { item.end ?? start.addingTimeInterval(3600) }, set: { setEnd($0) }),
                                               in: start.addingTimeInterval(60)...)
                                }
                            }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 2)
                    .id(PickerRow.schedule)
                    .sensoryFeedback(.selection, trigger: "\(item.day) \(item.minute != nil) \(item.end != nil)")
                } header: {
                    if existing && item.isCarried(now: Date()) {
                        InfoHeader("Schedule", isExpanded: infoBinding("schedule"))
                    } else {
                        Text("Schedule")
                    }
                } footer: {
                    InfoFooter(isExpanded: openInfo.contains("schedule")) {
                        Text("The schedule stays as planned. Until it is done, the item is also shown on today. Tick it off on the day it actually happened to keep it there.")
                    }
                }
                repeatSection
                Section {
                    Toggle("Move to next day if unfinished", isOn: Binding(get: { item.movesToNextDay }, set: {
                        item.movesToNextDay = $0
                        carryChosen = true
                    }))
                } header: {
                    InfoHeader("Carry over", isExpanded: infoBinding("carryOver"))
                } footer: {
                    InfoFooter(isExpanded: openInfo.contains("carryOver")) {
                        Text(item.movesToNextDay
                             ? "Unfinished items move to today. A time range keeps its time and duration; a single time becomes any time."
                             : "This item stays on its scheduled day, even if unfinished.")
                    }
                }
                Section {
                    // Reminders follow the schedule's pattern: one button each, plus an add button.
                    FlowLayout(spacing: 8) {
                        ForEach(Array(zip(reminderIDs, item.reminders).enumerated()), id: \.element.0) { index, entry in
                            let reminder = entry.1
                            SchedulePill(name: "Reminder", removeTitle: "Remove reminder", value: reminderText(reminder),
                                         accessibilityValue: reminder.formatted(date: .abbreviated, time: .shortened),
                                         symbol: "alarm", tint: reminder <= Date() ? .gray : .blue, isEditing: editing(.reminder(index)),
                                         onRemove: { animate { removeReminder(at: index) } }) {
                                reminderPicker(at: index)
                            }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        SchedulePill(name: "Reminder", addTitle: "Add reminder", addLabel: "Reminder", value: nil,
                                     isEditing: .constant(false), onAdd: addReminder) { EmptyView() }
                            .disabled(requestingReminder)
                    }
                    .padding(.vertical, 2)
                    .id(PickerRow.reminders)
                    .sensoryFeedback(.selection, trigger: item.reminders.count)
                    .onChange(of: editingField) { old, new in
                        // Re-order once a reminder's popover closes, so its button doesn't move mid-edit.
                        if case .reminder = old, new != old, item.reminders != item.reminders.sorted() {
                            // Sort once the popover has gone, in a separate update: the dismissal's own
                            // update disables animations, which would make the buttons jump.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                sortReminders()
                            }
                        }
                    }
                } header: {
                    InfoHeader("Reminders", isExpanded: infoBinding("reminders"))
                } footer: {
                    InfoFooter(isExpanded: openInfo.contains("reminders")) {
                        Text("Upcoming reminders appear in the blue alarm filter and notify you at the chosen times."
                             + (item.reminders.contains(where: { $0 <= Date() }) ? " Grey reminders have passed and won’t notify you." : ""))
                    }
                }
                Section("Locations") {
                    TextPills(kind: .location, entries: $locations) { reveal("locations", in: form) }
                        .id("locations")
                }
                Section("People") {
                    TextPills(kind: .person, entries: $people) { reveal("people", in: form) }
                        .id("people")
                }
                Section("Notes") { TextField("Anything to remember", text: $item.notes, axis: .vertical).lineLimit(3...8) }
                if existing {
                    Section {
                        if item.seriesID == nil {
                            // No confirmation: the Undo that follows a deletion covers a mistaken tap.
                            Button(role: .destructive) {
                                store.delete(item, children: false, undoManager: undoManager); dismiss()
                            } label: {
                                Label("Delete item", systemImage: "trash").foregroundStyle(.red)
                            }
                        } else {
                            // The same choices as the long-press menu, opening from the button.
                            Menu {
                                RepeatDeletionButtons(item: item) { scope in
                                    store.delete(item, children: false, scope: scope, undoManager: undoManager); dismiss()
                                }
                            } label: {
                                Label { Text("Delete item") } icon: { Image(systemName: "trash") }
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .onChange(of: item.minute != nil) { _, timed in
                guard !existing, !carryChosen else { return }
                item.movesToNextDay = !timed
            }
            .onChange(of: pendingField) { _, field in
                guard let field else { return }
                // Pickers open below their button; lift the row first so a tall calendar
                // is never cut off by the bottom of the screen.
                let row: PickerRow = if case .reminder = field { .reminders } else { .schedule }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { form.scrollTo(row, anchor: .top) }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 280))
                    editingField = field
                    pendingField = nil
                }
            } }
            .navigationTitle(existing ? "Your item" : "New item").navigationBarTitleDisplayMode(.inline)
            .background(KeyboardDismissal())
            // A popover replaces the keyboard, whichever field was being typed in.
            .onChange(of: editingField) { _, field in
                if field != nil { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold).disabled(requestingReminder || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear { if !existing { titleFocused = true } }
            .alert("Check this item", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                if needsNotificationSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        issue = nil; needsNotificationSettings = false
                    }
                }
                Button("OK", role: .cancel) { issue = nil; needsNotificationSettings = false }
            } message: { Text(issue ?? "") }
            .alert("Unlink this item?",
                   isPresented: Binding(get: { pendingDetach != nil }, set: { if !$0 { pendingDetach = nil } }),
                   presenting: pendingDetach) { saved in
                Button("Unlink and Save") { saveDetached(saved) }
                if openItem != nil, let stored = linkedOccurrence {
                    Button("Edit Original Item") { goToOriginal(of: stored) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { saved in
                Text(unlinkMessage(saved))
            }
        }
    }
    /// Brings a row being typed in to the middle of the space above the keyboard, once the
    /// keyboard is up; the form's own scrolling only just uncovers the text cursor.
    private func reveal(_ row: String, in form: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { form.scrollTo(row, anchor: .center) }
        }
    }
    private func infoBinding(_ section: String) -> Binding<Bool> {
        Binding(get: { openInfo.contains(section) }, set: { open in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                if open { openInfo.insert(section) } else { openInfo.remove(section) }
            }
        })
    }
    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy) { change() }
    }
    private func editing(_ field: ScheduleField) -> Binding<Bool> {
        Binding(get: { editingField == field }, set: { open in
            if open { pendingField = field } else { editingField = nil }
        })
    }
    private func setDay(_ day: Day) { Planner.updateStart(&item, day: day, minute: item.minute) }
    private func setMinute(_ minute: Int) { Planner.updateStart(&item, day: item.day, minute: minute) }
    private func setEnd(_ end: Date?) { item.end = end; item.suggestionDismissed = false }
    /// Adds the suggested start, restoring the duration the time had before it was removed.
    private func addTime() {
        setMinute(suggestedStartMinute)
        if let removedDuration, let start = item.start() { setEnd(start.addingTimeInterval(removedDuration)) }
    }
    private func removeTime() {
        removedDuration = item.end.flatMap { end in item.start().map { end.timeIntervalSince($0) } }
        Planner.updateStart(&item, day: item.day, minute: nil)
    }
    /// Starts after the day's last timed item and not before now, rounded up to a quarter hour
    /// (a whole hour from now when nothing else is planned). Falls back to 9:00.
    private var suggestedStartMinute: Int {
        let dayStart = item.day.date()
        func minutes(_ date: Date, roundingTo step: Int) -> Int {
            let elapsed = Int(ceil(date.timeIntervalSince(dayStart) / 60))
            return (elapsed + step - 1) / step * step
        }
        var candidates: [Int] = []
        // Items running past midnight (or for days) leave no slot after them, so they don't count.
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let lastEnd = store.items.filter { $0.id != item.id && $0.appears(on: item.day) }
            .compactMap { $0.end ?? $0.start() }.filter { $0 < nextDay }.max()
        if let lastEnd { candidates.append(minutes(lastEnd, roundingTo: 15)) }
        if item.day == Day(Date()) { candidates.append(minutes(Date().addingTimeInterval(1), roundingTo: 60)) }
        guard let start = candidates.max(), (0..<24 * 60).contains(start) else { return 9 * 60 }
        return start
    }
    private var daySuggestions: [ScheduleOption<Day>] {
        let calendar = Calendar.current
        let today = Day(Date())
        func later(_ days: Int, from day: Day) -> Day { Day(calendar.date(byAdding: .day, value: days, to: day.date())!) }
        return [ScheduleOption(value: today, title: "Today"),
                ScheduleOption(value: later(1, from: today), title: "Tomorrow"),
                ScheduleOption(value: later(7, from: item.day), title: "Next week")]
    }
    private var timeSuggestions: [ScheduleOption<Int>] {
        let minutes = Array(Set([suggestedStartMinute, 9 * 60, 12 * 60, 18 * 60])).sorted()
        return minutes.map { ScheduleOption(value: $0, title: item.day.date().addingTimeInterval(Double($0) * 60).formatted(date: .omitted, time: .shortened)) }
    }
    private var durationOptions: [ScheduleOption<Int>] {
        // Short labels keep every choice on one line; VoiceOver reads the full duration.
        [15, 30, 45, 60, 120].map { minutes in
            let title = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
            return ScheduleOption(value: minutes, title: title, accessibilityLabel: durationText(Double(minutes) * 60, width: .wide))
        }
    }
    /// Quick reminder times: before the start when there is one, otherwise times on the day.
    private var reminderSuggestions: [ScheduleOption<Date>] {
        let options: [ScheduleOption<Date>]
        if let start = item.start() {
            options = [0, 5, 15, 30, 60].map { (minutes: Int) -> ScheduleOption<Date> in
                let seconds = TimeInterval(minutes * 60)
                guard minutes > 0 else { return ScheduleOption(value: start, title: "0m", accessibilityLabel: "At start") }
                return ScheduleOption(value: start.addingTimeInterval(-seconds), title: minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h",
                                      accessibilityLabel: durationText(seconds, width: .wide) + " before")
            }
        } else {
            options = [9, 12, 18].map { hour in
                let date = item.day.date().addingTimeInterval(Double(hour) * 3600)
                return ScheduleOption(value: date, title: date.formatted(date: .omitted, time: .shortened))
            }
        }
        return options
    }
    /// A suggested new reminder that the item does not have yet: an unused quick choice
    /// (15 minutes before the start first), or the next free whole hour from now.
    private var newReminder: Date {
        // Prefer 15 minutes before the start, then the other quick choices.
        let suggestions = reminderSuggestions.map(\.value)
        let preferred = suggestions.filter { date in item.start().map { $0.timeIntervalSince(date) == 15 * 60 } ?? false } + suggestions
        if let date = preferred.first(where: { !item.reminders.contains($0) }) {
            return date
        }
        let calendar = Calendar.current
        var date = calendar.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        while item.reminders.contains(date) { date.addTimeInterval(3600) }
        return date
    }
    private func addReminder() {
        requestingReminder = true
        Task { @MainActor in
            defer { requestingReminder = false }
            do {
                guard try await store.requestReminderPermission() else {
                    needsNotificationSettings = true
                    issue = "Allow notifications for timo in Settings to receive reminders."
                    return
                }
                animate { item.reminders.append(newReminder); reminderIDs.append(UUID()) }
                // Let the new button appear before anchoring its popover to it.
                try? await Task.sleep(for: .milliseconds(300))
                pendingField = .reminder(item.reminders.count - 1)
            } catch { issue = "Reminders could not be enabled. \(error.localizedDescription)" }
        }
    }
    /// Sorts reminders and their identities together, so each button slides to its new place.
    private func sortReminders() {
        guard editingField == nil, item.reminders.count == reminderIDs.count else { return }
        let order = item.reminders.indices.sorted { item.reminders[$0] < item.reminders[$1] }
        animate {
            item.reminders = order.map { item.reminders[$0] }
            reminderIDs = order.map { reminderIDs[$0] }
        }
    }
    private func removeReminder(at index: Int) {
        guard item.reminders.indices.contains(index) else { return }
        editingField = nil
        item.reminders.remove(at: index)
        if reminderIDs.indices.contains(index) { reminderIDs.remove(at: index) }
    }
    private func reminderPicker(at index: Int) -> some View {
        let reminder = Binding(get: { item.reminders.indices.contains(index) ? item.reminders[index] : Date() },
                               set: { if item.reminders.indices.contains(index) { item.reminders[index] = $0 } })
        return VStack(alignment: .leading, spacing: 12) {
            if !reminderSuggestions.isEmpty {
                ScheduleChips(options: reminderSuggestions, selected: reminder.wrappedValue, fillsWidth: item.start() != nil) { reminder.wrappedValue = $0 }
            }
            DatePicker("Remind me at", selection: reminder)
        }
    }
    /// Relative to the start when it is a little before it, otherwise the time (and day when different).
    private func reminderText(_ date: Date) -> String {
        if let start = item.start() {
            let before = start.timeIntervalSince(date)
            if before == 0 { return "At start" }
            if before > 0, before < 24 * 3600, before.truncatingRemainder(dividingBy: 60) == 0 { return durationText(before) + " before" }
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        return Day(date) == item.day ? time : "\(dayName(Day(date))), \(time)"
    }
    /// Today, Tomorrow or Yesterday, a weekday within the coming week, otherwise a short date.
    private func dayName(_ day: Day) -> String {
        let offset = Calendar.current.dateComponents([.day], from: Day(Date()).date(), to: day.date()).day ?? 0
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return day.date().formatted(.dateTime.weekday(.wide))
        default: return day.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }
    private func durationText(_ seconds: TimeInterval, width: Duration.UnitsFormatStyle.UnitWidth = .narrow) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: width))
    }
    /// When the item ends, with the day when it falls after the start's day.
    private func endText(_ end: Date, start: Date) -> String {
        let time = end.formatted(date: .omitted, time: .shortened)
        guard Calendar.current.isDate(end, inSameDayAs: start) else { return "until \(dayName(Day(end))), \(time)" }
        return "until \(time)"
    }
    private func endAccessibilityText(_ end: Date, start: Date) -> String {
        "Ends " + end.formatted(date: .abbreviated, time: .shortened) + ", " + durationText(end.timeIntervalSince(start), width: .wide)
    }
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
    private var repeatSection: some View {
        Section {
            Picker("Repeat", selection: $item.repeatRule) {
                ForEach(RepeatRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            if item.repeatRule == .custom {
                ForEach(orderedWeekdays, id: \.self) { weekday in
                    Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(
                        get: { item.repeatWeekdays.contains(weekday) },
                        set: { selected in
                            if selected { item.repeatWeekdays.append(weekday) }
                            else { item.repeatWeekdays.removeAll { $0 == weekday } }
                        }))
                }
            }
            if item.repeatRule == .weekly {
                Text("Every " + item.day.date().formatted(.dateTime.weekday(.wide)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            InfoHeader("Repeat", isExpanded: infoBinding("repeat"))
        } footer: {
            InfoFooter(isExpanded: openInfo.contains("repeat")) {
                Text(item.repeatRule != .never || item.seriesID != nil
                     ? "Starts on the first matching day on or after the selected date. Changes to the original item, including how it repeats, apply to all its linked items. Changing how a linked item repeats unlinks it and makes it a new original item. Completion is separate for each item. The Carry over setting controls whether unfinished items move to the next day."
                     : "Repeat this item every day, every weekday, every week or on days you choose. Each occurrence is completed separately. The Carry over setting controls whether unfinished items move to the next day.")
            }
        }
        .onChange(of: item.repeatRule) { _, rule in
            if rule == .custom && item.repeatWeekdays.isEmpty {
                item.repeatWeekdays = [Calendar.current.component(.weekday, from: item.day.date())]
            }
        }
    }
    /// Keep carried and linked status together above the editable fields. Use the saved
    /// item so changing its draft schedule doesn't rewrite what happened to it.
    @ViewBuilder private var itemStatusSection: some View {
        if let stored = store.item(item.id) {
            let now = Date()
            let carried = stored.isCarried(now: now)
            let original = stored.seriesID == nil ? nil : store.originalDay(of: stored)
            if carried || original != nil {
                Section {
                    if carried {
                        let destination = stored.liveDay(now: now)
                        let destinationText = destination == Day(now) ? "today" : dayText(destination)
                        Label("Moved from \(dayText(stored.day)) to \(destinationText)", systemImage: "arrow.right.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let start = original {
                        if store.isOriginal(stored) {
                            Label(originalText(stored), systemImage: "repeat")
                                .foregroundStyle(.secondary)
                        } else {
                            Label {
                                Text(linkedToText(stored, start: start))
                                    .foregroundStyle(.secondary)
                                    .tint(.blue)
                                    .environment(\.openURL, OpenURLAction { _ in
                                        goToOriginal(of: stored)
                                        return .handled
                                    })
                                    .accessibilityHint(openItem == nil ? "" : "Goes to the original item")
                            } icon: {
                                Image(systemName: "repeat").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
    private func originalText(_ stored: PlanItem) -> String {
        guard let linked = store.linkedCount(of: stored) else { return "Original item" }
        let items = linked.count == 1 ? "1 item" : "\(linked.count) items"
        if linked.isTotal { return "Original item, linked to \(items)" }
        return linked.count == 0 ? "Original item, no linked items yet" : "Original item, linked to \(items) so far"
    }
    private func linkedToText(_ stored: PlanItem, start: Day) -> AttributedString {
        let text = AttributedString("Linked item, linked to ")
        var original = AttributedString("\(stored.title), \(dayText(start))")
        if openItem != nil { original.link = URL(string: "timo-original:") }
        return text + original
    }
    private func goToOriginal(of stored: PlanItem) {
        guard let original = store.original(of: stored) else { return }
        openItem?(original)
    }
    private func dayText(_ day: Day) -> String {
        day.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
    /// The stored item when it is a linked item of a repeating item rather than its original.
    private var linkedOccurrence: PlanItem? {
        guard let stored = store.item(item.id), stored.seriesID != nil, !store.isOriginal(stored) else { return nil }
        return stored
    }
    private func repeatSummary(_ item: PlanItem) -> String {
        switch item.repeatRule {
        case .weekly: return "Every " + item.day.date().formatted(.dateTime.weekday(.wide))
        case .custom:
            let symbols = Calendar.current.shortWeekdaySymbols
            return orderedWeekdays.filter(item.repeatWeekdays.contains).map { symbols[$0 - 1] }.joined(separator: ", ")
        default: return item.repeatRule.title
        }
    }
    private func save() {
        item.locations = locations.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        item.people = people.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Retain existing relationships unless their saved parent no longer exists.
        if let parentID = item.parentID, store.item(parentID) == nil { item.parentID = nil }
        // Deduplicate a copy, so the editor's reminders keep matching their button identities.
        var saved = item
        saved.reminders = Array(Set(item.reminders)).sorted()
        if let stored = linkedOccurrence {
            // A linked item is only changed after a warning that saving unlinks it.
            var unchanged = stored
            unchanged.reminders = Array(Set(stored.reminders)).sorted()
            guard saved != unchanged else { dismiss(); return }
            pendingDetach = saved
            return
        }
        do { try store.save(saved); if store.errorMessage == nil { dismiss() } }
        catch { issue = error.localizedDescription }
    }
    /// Saves a changed later day once the warning is confirmed: it leaves its repeating item,
    /// and with a repeat pattern of its own it becomes the master of a new one.
    private func saveDetached(_ saved: PlanItem) {
        do { try store.saveDetached(saved); if store.errorMessage == nil { dismiss() } }
        catch { issue = error.localizedDescription }
    }
    /// Says plainly what unlinking does to this item and what it leaves alone.
    private func unlinkMessage(_ saved: PlanItem) -> String {
        guard let stored = linkedOccurrence else { return "" }
        guard saved.repeatRule != .never, Planner.changesPattern(stored, to: saved) else {
            return "This item will be unlinked. The original item and other linked items won’t change. To change all of them, edit the original item."
        }
        return "This item will be unlinked and become a new original item, repeating \(lowercasedFirst(repeatSummary(saved))). The original item and other linked items won’t change."
    }
    private func lowercasedFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }
}

/// A section title with a small (i) beside it that shows or hides the section's explanation,
/// which appears beneath the section's content.
private struct InfoHeader: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 15

    init(_ title: LocalizedStringKey, isExpanded: Binding<Bool>) {
        self.title = title; _isExpanded = isExpanded
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(title).accessibilityAddTraits(.isHeader)
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.secondary)
                    // Reach a 44-point target without making the header taller.
                    .frame(width: 28, height: 22)
                    .contentShape(.rect.inset(by: -11))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("About \(Text(title))"))
            .accessibilityValue(isExpanded ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides an explanation below this section")
        }
    }
}

/// A section's explanation, shown in its footer while its (i) is on.
private struct InfoFooter<Info: View>: View {
    let isExpanded: Bool
    @ViewBuilder let info: () -> Info
    var body: some View {
        if isExpanded {
            info()
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

private enum PickerRow: Hashable { case schedule, reminders }

private enum ScheduleField: Equatable { case day, time, end, reminder(Int) }

/// A capsule showing a schedule value, or an add button while it is unset. Tapping it opens
/// its picker in a popover; a set value that can be cleared carries its own remove button.
private struct SchedulePill<Picker: View>: View {
    let name: LocalizedStringKey
    var addTitle: LocalizedStringKey = ""
    var addLabel: LocalizedStringKey? = nil
    var removeTitle: LocalizedStringKey = ""
    let value: String?
    var accessibilityValue: String? = nil
    var symbol: String? = nil
    /// Colours the capsule and its text, so a kind of value (reminders) stands out.
    var tint: Color? = nil
    @Binding var isEditing: Bool
    var onAdd: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @ViewBuilder let picker: () -> Picker

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if value == nil { onAdd?() }
                isEditing = true
            } label: {
                Group {
                    if let value {
                        HStack(spacing: 6) {
                            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                            Text(value)
                        }
                        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    } else {
                        HStack(spacing: 6) { Image(systemName: "plus").accessibilityHidden(true); Text(addLabel ?? addTitle) }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12).padding(.trailing, value != nil && onRemove != nil ? 2 : 12)
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .accessibilityLabel(value == nil ? addTitle : name)
            .accessibilityValue(accessibilityValue ?? value ?? "")
            if value != nil, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        // A tinted pill (a reminder) tints its remove button to match.
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .padding(.leading, 4).padding(.trailing, 8)
                        .frame(minHeight: 36)
                        // Reach a 44-point target without making the capsule taller.
                        .contentShape(.rect.inset(by: -4))
                }
                .accessibilityLabel(removeTitle)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        // A set value is a filled capsule; an add button is a dashed outline, like AddPillLabel.
        .background(value == nil ? AnyShapeStyle(.clear)
                    : tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.fill.tertiary), in: .capsule)
        .overlay {
            if value == nil {
                Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
        }
        // Keep the arrow on top so the popover opens below the button at full width,
        // rather than beside it where a calendar would be clipped.
        .popover(isPresented: $isEditing, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            // A fixed width lets the chips wrap before the popover measures its height.
            picker().frame(width: 320).padding().presentationCompactAdaptation(.popover)
        }
    }
}

private struct ScheduleOption<Value: Hashable>: Hashable {
    let value: Value
    let title: String
    var accessibilityLabel: String? = nil
}

/// Quick choices shown above a schedule picker; the current value is filled.
private struct ScheduleChips<Value: Hashable>: View {
    let options: [ScheduleOption<Value>]
    let selected: Value?
    var fillsWidth = false
    let choose: (Value) -> Void

    var body: some View {
        if fillsWidth {
            // One evenly divided line, wrapping only when the text is too large to fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips(padding: 8, flexible: true) }
                FlowLayout(spacing: 8) { chips(padding: 12, flexible: false) }
            }
        } else {
            FlowLayout(spacing: 8) { chips(padding: 12, flexible: false) }
        }
    }

    private func chips(padding: CGFloat, flexible: Bool) -> some View {
        ForEach(options, id: \.self) { option in
            let isSelected = option.value == selected
            Button { choose(option.value) } label: {
                Text(option.title)
                    // Never truncate; a line that can't fit falls back to wrapping instead.
                    .fixedSize()
                    .padding(.horizontal, padding).frame(minHeight: 34)
                    .frame(maxWidth: flexible ? .infinity : nil)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                    .background(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.fill.tertiary), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.accessibilityLabel ?? option.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// The personas an item belongs to. Tap one to add it and again to remove it; an item can be in
/// several, or none.
private struct PersonaChips: View {
    @Binding var selection: [Persona]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var orbSize: CGFloat = 14

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Persona.allCases) { chip($0) }
        }
    }
    private func chip(_ persona: Persona) -> some View {
        let isSelected = selection.contains(persona)
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                selection = Persona.ordered(isSelected ? selection.filter { $0 != persona } : selection + [persona])
            }
        } label: {
            HStack(spacing: 6) {
                PersonaOrb(persona: persona, size: orbSize, glows: false)
                Text(persona.title).fixedSize()
            }
            .padding(.leading, 8).padding(.trailing, 12).frame(minHeight: 34)
            // Chosen, it reads like a reminder pill in the persona's colour; the rest stay quiet.
            .foregroundStyle(isSelected ? AnyShapeStyle(persona.color) : AnyShapeStyle(.secondary))
            .background(isSelected ? AnyShapeStyle(persona.color.opacity(0.14)) : AnyShapeStyle(.fill.tertiary), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(persona.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Removes this persona" : "Adds this persona")
    }
}

/// Places views left to right, wrapping onto further lines when they do not fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Take the full offered width: reporting only the content's width let the parent place
        // the layout in that narrower width, wrapping a button onto a line it hadn't sized for.
        let size = arrange(proposal.width ?? .infinity, subviews).size
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : size.width } ?? size.width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0 && x + size.width > width + 0.5 { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; lineHeight = max(lineHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + lineHeight))
    }
}

private struct ItemTextEntry: Identifiable {
    let id = UUID()
    var text: String
}

private enum TextKind: Equatable {
    case location, person
    var name: LocalizedStringKey { self == .location ? "Location" : "Person" }
    var addTitle: LocalizedStringKey { self == .location ? "Add location" : "Add person" }
    var removeTitle: LocalizedStringKey { self == .location ? "Remove location" : "Remove person" }
    var placeholder: String { self == .location ? "Location" : "Person" }
    var symbol: String { self == .location ? "mappin.and.ellipse" : "person" }
}

/// Places or people as one line of pills that you type in directly. Each pill is its own small
/// field with a remove button; the dashed pill at the end turns into a new field.
private struct TextPills: View {
    let kind: TextKind
    @Binding var entries: [ItemTextEntry]
    /// Called when one of the pills starts being typed in.
    var onEditing: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Field?
    @State private var adding = false
    @State private var draft = ""
    private enum Field: Hashable { case entry(UUID), new }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach($entries) { $entry in
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                    field(text: $entry.text, focusedAs: .entry(entry.id))
                    Button { animate { entries.removeAll { $0.id == entry.id } } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                            .frame(minHeight: 36)
                            // Reach a 44-point target without making the pill taller.
                            .contentShape(.rect.inset(by: -6))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("\(Text(kind.removeTitle)): \(entry.text)"))
                }
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(minHeight: 36)
                .background(.fill.tertiary, in: .capsule)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if adding {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                    field(text: $draft, focusedAs: .new)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(.fill.tertiary, in: .capsule)
            } else {
                Button {
                    adding = true
                    // Focus once the field exists.
                    Task { @MainActor in focus = .new }
                } label: {
                    AddPillLabel(title: kind.name)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(kind.addTitle)
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: entries.count)
        .onChange(of: focus) { old, new in
            if new != nil { onEditing() }
            // Settle a pill once its field loses focus: keep new text, and drop any left empty.
            if old == .new {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = ""
                animate {
                    if !text.isEmpty { entries.append(ItemTextEntry(text: text)) }
                    adding = false
                }
            }
            if case .entry(let id) = old, let index = entries.firstIndex(where: { $0.id == id }) {
                let text = entries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { animate { entries.remove(at: index) } } else { entries[index].text = text }
            }
        }
    }
    private func field(text: Binding<String>, focusedAs field: Field) -> some View {
        TextField(kind.placeholder, text: text)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .onSubmit { focus = nil }
            .focused($focus, equals: field)
            // The pill grows with what is typed, from a small minimum.
            .fixedSize()
            .frame(minWidth: 48, alignment: .leading)
            .accessibilityLabel(kind.name)
    }
    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25), change)
    }
}

/// An add button in the editor's pill rows: a dashed outline with a plus, so it reads as
/// a place for something new rather than a value already set.
private struct AddPillLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").accessibilityHidden(true)
            Text(title)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(.capsule)
    }
}

/// Closes the keyboard when a tap lands anywhere except a text field, without taking the tap
/// from the button or row underneath.
private struct KeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}
    static func dismantleUIView(_ uiView: InstallerView, coordinator: ()) { uiView.uninstall() }

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            return tap
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            uninstall()
            window?.addGestureRecognizer(tap)
        }
        func uninstall() { tap.view?.removeGestureRecognizer(tap) }

        @objc private func dismissKeyboard() { window?.endEditing(true) }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
