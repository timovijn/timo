import SwiftUI

struct ItemEditor: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State var item: PlanItem
    @State private var locations: [ItemTextEntry]
    @State private var people: [ItemTextEntry]
    @State private var issue: String?
    @State private var showingDelete = false
    @State private var requestingReminder = false
    @State private var needsNotificationSettings = false
    @State private var editingField: ScheduleField?
    @State private var removedDuration: TimeInterval?
    /// Identities for `item.reminders`, kept in the same order, so a button follows its reminder when sorting.
    @State private var reminderIDs: [UUID]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var titleFocused: Bool
    private var existing: Bool { store.item(item.id) != nil }
    init(item: PlanItem) {
        _item = State(initialValue: item)
        _locations = State(initialValue: (item.locations.isEmpty ? [""] : item.locations).map { ItemTextEntry(text: $0) })
        _people = State(initialValue: (item.people.isEmpty ? [""] : item.people).map { ItemTextEntry(text: $0) })
        _reminderIDs = State(initialValue: item.reminders.map { _ in UUID() })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What’s on your day?", text: $item.title, axis: .vertical)
                        .font(.title3.weight(.medium)).focused($titleFocused)
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
                    .sensoryFeedback(.selection, trigger: "\(item.day) \(item.minute != nil) \(item.end != nil)")
                    if let from = item.carriedFrom {
                        Text("Carried from \(from.date().formatted(date: .abbreviated, time: .omitted)). Choosing a date gives this item a fresh plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Schedule") }
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
                } header: { Text("Repeat") } footer: {
                    if item.repeatRule != .never || item.seriesID != nil {
                        Text("Starts on the first matching day on or after the selected date. Each occurrence can be completed independently and stays on its scheduled day. Edits apply to every occurrence of this repeating item, including earlier days. Completion is separate for each day. Choosing Never keeps only this occurrence.")
                    }
                }
                .onChange(of: item.repeatRule) { _, rule in
                    if rule != .never { item.movesToNextDay = false }
                    if rule == .custom && item.repeatWeekdays.isEmpty {
                        item.repeatWeekdays = [Calendar.current.component(.weekday, from: item.day.date())]
                    }
                }
                if item.repeatRule == .never && item.seriesID == nil {
                    Section {
                        Toggle("Move to next day if unfinished", isOn: $item.movesToNextDay)
                    } footer: {
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
                                     tint: .blue, isEditing: .constant(false), onAdd: addReminder) { EmptyView() }
                            .disabled(requestingReminder)
                    }
                    .padding(.vertical, 2)
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
                    if item.reminders.contains(where: { $0 <= Date() }) {
                        Text("Grey reminders have passed and won’t notify you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Reminders") } footer: {
                    Text("Reminders appear in the blue alarm filter and notify you at the chosen times.")
                }
                Section("Locations") {
                    ItemTextFields(entries: $locations, placeholder: "Location", symbol: "mappin.and.ellipse", addLabel: "Add location")
                }
                Section("People") {
                    ItemTextFields(entries: $people, placeholder: "Name", symbol: "person", addLabel: "Add person")
                }
                Section("Notes") { TextField("Anything to remember", text: $item.notes, axis: .vertical).lineLimit(3...8) }
                if existing {
                    Section {
                        Button(item.isComplete ? "Mark incomplete" : "Mark complete", systemImage: item.isComplete ? "arrow.uturn.backward" : "checkmark") {
                            // Save current edits together with the completion change.
                            item.completedAt = item.isComplete ? nil : Date(); save()
                        }
                        Button(item.seriesID == nil ? "Delete item" : "Delete repeating item", role: .destructive) { showingDelete = true }
                    }
                }
            }
            .navigationTitle(existing ? "Your item" : "New item").navigationBarTitleDisplayMode(.inline)
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
            .confirmationDialog(item.seriesID == nil ? "Delete this item?" : "Delete all occurrences of this repeating item?", isPresented: $showingDelete, titleVisibility: .visible) {
                Button(item.seriesID == nil ? "Delete item" : "Delete all occurrences", role: .destructive) {
                    store.delete(item, children: false); dismiss()
                }
            }
        }
    }
    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy) { change() }
    }
    private func editing(_ field: ScheduleField) -> Binding<Bool> {
        Binding(get: { editingField == field }, set: { editingField = $0 ? field : nil })
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
                editingField = .reminder(item.reminders.count - 1)
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
    private func save() {
        item.locations = locations.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        item.people = people.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Retain existing relationships unless their saved parent no longer exists.
        if let parentID = item.parentID, store.item(parentID) == nil { item.parentID = nil }
        // Deduplicate a copy, so the editor's reminders keep matching their button identities.
        var saved = item
        saved.reminders = Array(Set(item.reminders)).sorted()
        do { try store.save(saved); if store.errorMessage == nil { dismiss() } }
        catch { issue = error.localizedDescription }
    }
}

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
                            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
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
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
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
        .background(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.fill.tertiary), in: .capsule)
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

private struct ItemTextFields: View {
    @Binding var entries: [ItemTextEntry]
    let placeholder: String
    let symbol: String
    let addLabel: String
    @FocusState private var focusedEntry: UUID?

    var body: some View {
        ForEach($entries) { $entry in
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $entry.text, axis: .vertical)
                    .textInputAutocapitalization(.words)
                    .focused($focusedEntry, equals: entry.id)
                    .accessibilityLabel(placeholder == "Name" ? "Person" : placeholder)
                if entries.count > 1 || !entry.text.isEmpty {
                    Button {
                        let id = entry.id
                        focusedEntry = nil
                        if entries.count == 1 { entries[0].text = "" }
                        else { entries.removeAll { $0.id == id } }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.text.isEmpty ? placeholder.lowercased() : entry.text)")
                }
            }
        }
        Button(addLabel, systemImage: "plus") {
            if let empty = entries.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                focusedEntry = empty.id
            } else {
                let entry = ItemTextEntry(text: "")
                entries.append(entry)
                focusedEntry = entry.id
            }
        }
    }
}
