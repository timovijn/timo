import SwiftUI

struct ItemEditor: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State var item: PlanItem
    /// The entry's displayed day distinguishes the original from later carried entries.
    let viewingDay: Day
    @State private var locations: [ItemTextEntry]
    @State private var people: [ItemTextEntry]
    /// What is being typed into a new location or person pill, held here so Save keeps it
    /// even though the pill only adds it once its field loses focus.
    @State private var locationDraft = ""
    @State private var personDraft = ""
    /// The item as the editor opened with it, to tell whether there is anything to lose on closing.
    private let opened: PlanItem
    /// A copy made with Duplicate: unsaved, so there is something to keep from the start, and its
    /// title is a finished one rather than a line to read for details.
    private let isDuplicate: Bool
    @State private var confirmingClose = false
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
    /// Whether a picker's popover is on screen, including while it animates away.
    @State private var popoverShown = false
    @State private var removedDuration: TimeInterval?
    /// Identities for `item.reminders`, kept in the same order, so a button follows its reminder when sorting.
    @State private var reminderIDs: [UUID]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleFocused = false
    /// The title row has scrolled up under the bar, which then shows the item's title.
    @State private var titleScrolledAway = false
    /// Words of a new item's title kept as words rather than read as details.
    @State private var ignoredTitleWords: Set<String> = []
    /// The form as it was before a new item's title started filling it in, so each change to the
    /// title fills it in afresh: a changed or deleted word takes its value back out.
    @State private var titleBaseline: TitleBaseline?
    private struct TitleBaseline {
        var item: PlanItem
        var people: [ItemTextEntry]
        var locations: [ItemTextEntry]
    }
    /// Sections whose explanation is open. Explanations start closed, behind a small (i).
    @State private var openInfo: Set<String> = []
    /// Set on deleting, so the closing sheet doesn't turn into "New item" without its Delete row.
    @State private var deleted = false
    @State private var showingLinkedItems = false
    private var existing: Bool { deleted || store.item(item.id) != nil }
    private var kindTitle: LocalizedStringKey { existing ? "Edit item" : isDuplicate ? "Duplicate item" : "New item" }
    init(item: PlanItem, viewingDay: Day, isDuplicate: Bool = false, openItem: ((PlanItem) -> Void)? = nil) {
        self.viewingDay = viewingDay
        self.isDuplicate = isDuplicate
        self.openItem = openItem
        _item = State(initialValue: item.on(viewingDay))
        opened = item.on(viewingDay)
        _locations = State(initialValue: item.locations.map { ItemTextEntry(text: $0) })
        _people = State(initialValue: item.people.map { ItemTextEntry(text: $0) })
        _reminderIDs = State(initialValue: item.reminders.map { _ in UUID() })
    }
    /// The bar's centre: "Edit item", "New item" or "Duplicate item" while the title row is in view, then the item's
    /// own title, the two crossfading and sliding as the row scrolls under the bar. (Changing the
    /// navigation title itself would swap it in one step.)
    private var barTitle: some View {
        // While a new item's title is being read, the title it will keep rather than the full line.
        let read = titleEntry.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
        let title = read ?? item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsTitle = titleScrolledAway && !title.isEmpty
        return ZStack {
            Text(kindTitle)
                .opacity(showsTitle ? 0 : 1)
                .offset(y: showsTitle ? -8 : 0)
                .accessibilityHidden(showsTitle)
            Text(verbatim: title)
                .opacity(showsTitle ? 1 : 0)
                .offset(y: showsTitle ? 0 : 8)
                .accessibilityHidden(!showsTitle)
        }
        .font(.headline).lineLimit(1)
        .padding(.horizontal, 8)
    }
    var body: some View {
        editor
        // One size, so there's nothing to drag: as tall as a sheet goes while it's still a floating
        // glass card (at full height iOS makes it an edge-to-edge page). The keyboard is left to
        // iOS, which takes the sheet to full height while it's up and back again after.
        .presentationDetents([.fraction(0.95)])
        // A swipe down closes the editor like ✕ when nothing changed; with changes it springs back,
        // and ✕ asks what to do with them.
        .interactiveDismissDisabled(hasChanges)
        .sheet(isPresented: $showingLinkedItems) {
            LinkedItemsOverview(source: item).environmentObject(store)
        }
    }
    private var editor: some View {
        NavigationStack {
            // The reader lets a place or person row scroll well clear of the keyboard.
            ScrollViewReader { form in Form {
                Section {
                    ItemTitleField(text: $item.title, focused: $titleFocused)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { titleScrolledAway = !visible }
                        }
                        .overlay(alignment: .topLeading) {
                            if item.title.isEmpty {
                                Text("What’s on your day?")
                                    .font(.title3.weight(.medium)).foregroundStyle(Color(uiColor: .placeholderText))
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    if let titleEntry {
                        TitleDetailPills(entry: titleEntry) { ignoredTitleWords.formUnion($0) }
                    }
                } header: {
                    Text("Title")
                } footer: {
                    // Where a carried or linked item comes from, small under its title.
                    itemStatusNote
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
                    // The start day, optional time, and an optional timed or inclusive date end.
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
                                Button("Now") {
                                    Planner.updateStartToNow(&item, now: Date(), on: item.day)
                                    editingField = nil
                                }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                .accessibilityHint("Sets the current time on the selected day")
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                        } else {
                            SchedulePill(name: "End date", addTitle: "Add end date", addLabel: "End date", removeTitle: "Remove end date",
                                         value: item.endDay.map { "until \(dayName($0))" },
                                         accessibilityValue: item.endDay.map { "Through " + $0.date().formatted(date: .complete, time: .omitted) + ", inclusive" },
                                         isEditing: editing(.end), onAdd: { animate { setEndDay(item.day) } },
                                         onRemove: { animate { setEndDay(nil) } }) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ScheduleChips(options: [ScheduleOption(value: item.day, title: item.day == Day(Date()) ? "Today" : "Same day")], selected: item.endDay) {
                                        setEndDay($0); editingField = nil
                                    }
                                    DatePicker("End date", selection: Binding(get: { (item.endDay ?? item.day).date() }, set: {
                                        setEndDay(Day($0)); editingField = nil
                                    }), in: item.day.date()..., displayedComponents: .date)
                                        .datePickerStyle(.graphical).labelsHidden()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .id(PickerRow.schedule)
                    .sensoryFeedback(.selection, trigger: "\(item.day) \(item.minute != nil) \(item.end != nil) \(item.endDay != nil)")
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
                    .tint(.switchOn)
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
                Section {
                    FlowLayout(spacing: 8) {
                        if let deadline = item.deadline {
                            SchedulePill(name: "Deadline", removeTitle: "Remove deadline", value: deadlineText(deadline),
                                         accessibilityValue: deadline.formatted(date: .abbreviated, time: .shortened),
                                         // Grey once it has passed, like a past reminder.
                                         symbol: "flag", tint: deadline <= Date() ? .gray : .red, isEditing: editing(.deadline),
                                         onRemove: { animate { editingField = nil; item.deadline = nil } }) {
                                DatePicker("Due by", selection: Binding(get: { item.deadline ?? deadline }, set: { item.deadline = $0 }))
                            }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        } else {
                            SchedulePill(name: "Deadline", addTitle: "Add deadline", addLabel: "Deadline", value: nil,
                                         isEditing: .constant(false), onAdd: addDeadline) { EmptyView() }
                        }
                    }
                    .padding(.vertical, 2)
                    .id(PickerRow.deadline)
                    .sensoryFeedback(.selection, trigger: item.deadline != nil)
                } header: {
                    InfoHeader("Deadline", isExpanded: infoBinding("deadline"))
                } footer: {
                    InfoFooter(isExpanded: openInfo.contains("deadline")) {
                        Text("A red dot marks the item until it is done. A deadline doesn’t notify you; add a reminder for that."
                             + (item.deadline.map { $0 <= Date() } == true ? " A grey deadline has passed." : ""))
                    }
                }
                Section("Locations") {
                    TextPills(kind: .location, entries: $locations, draft: $locationDraft) { reveal("locations", in: form) }
                        .id("locations")
                }
                Section("People") {
                    TextPills(kind: .person, entries: $people, draft: $personDraft) { reveal("people", in: form) }
                        .id("people")
                }
                Section("Notes") { TextField("Anything to remember", text: $item.notes, axis: .vertical).lineLimit(3...8) }
                if existing && CloudSync.isAvailable { sharingSection }
                if existing {
                    Section {
                        Button {
                            Planner.setCancelled(!item.isCancelled, &item, on: viewingDay, now: Date())
                            item = item.on(viewingDay)
                        } label: {
                            Label(item.isCancelled ? "Uncancel item" : "Cancel item",
                                  systemImage: item.isCancelled ? "arrow.uturn.backward.circle" : "xmark.circle")
                        }
                        if item.seriesID == nil {
                            // No confirmation: the Undo that follows a deletion covers a mistaken tap.
                            Button(role: .destructive) {
                                deleted = true; store.delete(item, children: false, undoManager: undoManager); dismiss()
                            } label: {
                                Label("Delete item", systemImage: "trash").foregroundStyle(.red)
                            }
                        } else {
                            // The same choices as the long-press menu, opening from the button.
                            Menu {
                                RepeatDeletionButtons(item: item) { scope in
                                    deleted = true; store.delete(item, children: false, scope: scope, undoManager: undoManager); dismiss()
                                }
                            } label: {
                                Label { Text("Delete item") } icon: { Image(systemName: "trash") }
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                if let saved = store.item(item.id), saved.seriesID != nil, store.isOriginal(saved) {
                    Section("Linked items") {
                        Button { showingLinkedItems = true } label: {
                            Label("View and restore items", systemImage: "link")
                        }
                    }
                }
                if existing, let savedItem = store.item(item.id) {
                    Section("History") {
                        Text(savedItem.history)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .onChange(of: item.minute != nil || item.endDay != nil) { _, scheduledRange in
                guard !existing, !isDuplicate, !carryChosen else { return }
                item.movesToNextDay = !scheduledRange
            }
            .onChange(of: pendingField) { _, field in
                guard let field else { return }
                // Moving on from another picker: close it first.
                editingField = nil
                // Pickers open below their button; lift the row first so a tall calendar
                // is never cut off by the bottom of the screen.
                let row: PickerRow = switch field {
                case .reminder: .reminders
                case .deadline: .deadline
                default: .schedule
                }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { form.scrollTo(row, anchor: .top) }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 280))
                    // A popover presented while the last one is still leaving is dropped, so wait it out.
                    for _ in 0..<30 where popoverShown { try? await Task.sleep(for: .milliseconds(30)) }
                    guard pendingField == field else { return }
                    editingField = field
                    pendingField = nil
                }
            }
            // Popovers let the editor behind them be used, so close one once the form is dragged.
            .environment(\.popoverShown, PopoverShownAction { popoverShown = $0 })
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting, let field = editingField else { return }
                Task { @MainActor in
                    await Task.yield()
                    if editingField == field { editingField = nil }
                }
            }
            }
            // Kept for VoiceOver and the system; the bar shows `barTitle` in its place.
            .navigationTitle(kindTitle).navigationBarTitleDisplayMode(.inline)
            // The form fades out under the title as it scrolls, rather than meeting a hard bar edge.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The same gap above the Title header as between the sections below.
            .contentMargins(.top, 10, for: .scrollContent)
            .background(KeyboardDismissal())
            .background(PopoverDismissal(isActive: editingField != nil) { editingField = nil })
            // A popover replaces the keyboard, whichever field was being typed in.
            .onChange(of: editingField) { _, field in
                if field != nil { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
            .toolbar {
                // Round glass icons; their titles stay as VoiceOver labels.
                ToolbarItem(placement: .principal) { barTitle }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { close() }
                        // On the button, so the question comes out of ✕.
                        .confirmationDialog("Save your changes?", isPresented: $confirmingClose, titleVisibility: .visible) {
                            if canSave { Button("Save") { commitAndSave() } }
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        } message: {
                            Text(canSave ? "This item has changes that haven’t been saved." : "This item has changes, but it needs a title to be saved.")
                        }
                }
                // Plain glass like Cancel, greyed out until there's something to save. (Not the
                // confirmation placement: that fills the button solid in the app's black or white tint.)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", systemImage: "checkmark") { commitAndSave() }
                        .fontWeight(.semibold)
                        .disabled(!(hasChanges && canSave))
                }
            }
            .onAppear { if !existing && !isDuplicate { titleFocused = true } }
            // Typing fills in the fields as the title names them; done, the title keeps the rest.
            .onChange(of: item.title) { _, _ in
                guard titleFocused, !existing, !isDuplicate else { return }
                if titleBaseline == nil { titleBaseline = TitleBaseline(item: item, people: people, locations: locations) }
                fillInTitleDetails()
            }
            .onChange(of: ignoredTitleWords) { _, _ in fillInTitleDetails() }
            .onChange(of: titleFocused) { _, focused in
                // On the next turn, once the field has written its final text back.
                if !focused { Task { @MainActor in applyTitleDetails() } }
            }
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
            // Tapping the pill whose picker is open closes it; any other pill moves straight on.
            if open, editingField != field { pendingField = field } else { editingField = nil }
        })
    }
    private func setDay(_ day: Day) { Planner.updateStart(&item, day: day, minute: item.minute) }
    private func setMinute(_ minute: Int) { Planner.updateStart(&item, day: item.day, minute: minute) }
    private func setEnd(_ end: Date?) { item.end = end; item.suggestionDismissed = false }
    private func setEndDay(_ day: Day?) {
        item.endDay = day
        item.suggestionDismissed = false
    }
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
    /// Due at the end of the item's time, otherwise at 17:00 on its day; the picker opens to adjust it.
    private func addDeadline() {
        animate { item.deadline = item.end ?? (item.endDay ?? item.day).date().addingTimeInterval(17 * 3600) }
        Task { @MainActor in
            // Let the new button appear before anchoring its popover to it.
            try? await Task.sleep(for: .milliseconds(300))
            pendingField = .deadline
        }
    }
    /// The time, with the day when it isn't the item's own.
    private func deadlineText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Day(date) == item.day ? time : "\(dayName(Day(date))), \(time)"
    }
    /// Sorts reminders and their identities together, so each button slides to its new place.
    private func sortReminders() {
        guard editingField == nil, pendingField == nil, item.reminders.count == reminderIDs.count else { return }
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
    private var sharingSection: some View {
        Section {
            Button {
                SharingSheet.present(for: item, cloud: store.cloud)
            } label: {
                Label("Share item", systemImage: "person.2")
            }
        }
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
                        .tint(.switchOn)
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
    @ViewBuilder private var itemStatusNote: some View {
        if let stored = store.item(item.id) {
            let now = Date()
            let wasCarried = stored.isCarried(now: now) && !stored.appears(on: viewingDay)
            let carried = wasCarried && viewingDay > stored.day
            let carriedOriginal = wasCarried && viewingDay == stored.day
            let original = stored.seriesID == nil ? nil : store.originalDay(of: stored)
            if carried || carriedOriginal || original != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if carriedOriginal {
                        let count = Calendar.current.dateComponents([.day], from: stored.day.date(),
                                                                    to: stored.liveDay(now: now).date()).day ?? 0
                        let days = count == 1 ? "1 day" : "\(count) days"
                        Text("Original item, carried to \(days) so far")
                            .foregroundStyle(.secondary)
                    } else if carried {
                        Text(carriedFromText(stored))
                            .foregroundStyle(.secondary)
                            .tint(.blue)
                            .environment(\.openURL, OpenURLAction { _ in
                                openItem?(stored)
                                return .handled
                            })
                            .accessibilityHint(openItem == nil ? "" : "Goes to the item on its original scheduled day")
                    }
                    if let start = original {
                        if store.isOriginal(stored) {
                            Text(originalText(stored))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(linkedToText(stored, start: start))
                                .foregroundStyle(.secondary)
                                .tint(.blue)
                                .environment(\.openURL, OpenURLAction { _ in
                                    goToOriginal(of: stored)
                                    return .handled
                                })
                                .accessibilityHint(openItem == nil ? "" : "Goes to the original item")
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
    private func carriedFromText(_ stored: PlanItem) -> AttributedString {
        let text = AttributedString("Carried item, carried from ")
        var original = AttributedString("\(stored.title), \(dayText(stored.day))")
        if openItem != nil { original.link = URL(string: "timo-carried-origin:") }
        return text + original
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
    private var canSave: Bool {
        !requestingReminder && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The item as Save would store it, with places and people still being typed included.
    private var edited: PlanItem {
        func texts(_ entries: [ItemTextEntry], _ draft: String) -> [String] {
            (entries.map(\.text) + [draft]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var edited = item
        edited.locations = texts(locations, locationDraft)
        edited.people = texts(people, personDraft)
        return edited
    }
    private var hasChanges: Bool {
        guard !deleted else { return false }
        if isDuplicate && !existing { return true }
        // Reminders compare as a set: sorting or a duplicate isn't a change.
        func normalized(_ item: PlanItem) -> PlanItem {
            var item = item
            item.reminders = Array(Set(item.reminders)).sorted()
            return item
        }
        return normalized(edited) != normalized(opened)
    }
    private func close() {
        if hasChanges { confirmingClose = true } else { dismiss() }
    }
    /// Ends editing before saving, so text still being typed (including unconfirmed keyboard
    /// suggestions) reaches its field's value, then saves on the next turn of the run loop.
    private func commitAndSave() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            guard canSave else { return }
            save()
        }
    }
    /// What a new item's title says about its day, time, repeat, persona, people and places,
    /// read as it's typed: "January 20 dinner with Sam at 18:00".
    private var titleEntry: QuickEntry? {
        guard !existing, !isDuplicate, !item.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        func unique(_ names: [String]) -> [String] {
            var seen: Set<String> = []
            return names.filter { seen.insert($0.lowercased()).inserted }
        }
        return QuickEntry(item.title, on: titleBaseline?.item.day ?? item.day, now: Date(), ignoring: ignoredTitleWords,
                          knownPeople: unique(store.items.flatMap(\.people)), knownPlaces: unique(store.items.flatMap(\.locations)))
    }
    /// Fills the form in from what the title names so far, starting from the form as it was before
    /// the title began, so only what the title says now is in it.
    private func fillInTitleDetails() {
        guard let base = titleBaseline else { return }
        let title = item.title
        let entry = titleEntry
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            item = base.item
            item.title = title
            people = base.people
            locations = base.locations
            if let entry, !entry.matches.isEmpty { fillIn(entry) }
        }
    }
    /// The title is done (or the item saved): the details are already in the form, so the title
    /// keeps only the remaining words. Other changes made since are left as they are.
    private func applyTitleDetails() {
        defer { titleBaseline = nil }
        guard let entry = titleEntry, !entry.matches.isEmpty, !entry.title.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            // Not filled in while typing (a title that was never typed in), so fill it in now.
            if titleBaseline == nil { fillIn(entry) }
            item.title = entry.title
        }
    }
    private func fillIn(_ entry: QuickEntry) {
        let kinds = Set(entry.matches.map(\.kind))
        if kinds.contains(.day) || kinds.contains(.repeats) { setDay(entry.day) }
        if kinds.contains(.day) { setEndDay(entry.minute == nil ? entry.endDay : nil) }
        if let minute = entry.minute {
            item.endDay = nil
            setMinute(minute)
            setEnd(entry.endMinute.flatMap { end in item.start().map { $0.addingTimeInterval(TimeInterval((end - minute) * 60)) } })
        }
        if kinds.contains(.repeats) {
            item.repeatRule = entry.repeatRule
            item.repeatWeekdays = entry.repeatWeekdays
            item.endDay = nil
        }
        item.personas = Persona.ordered(item.personas + entry.personas)
        for name in entry.people where !people.contains(where: { $0.text.lowercased() == name.lowercased() }) {
            people.append(ItemTextEntry(text: name))
        }
        for place in entry.locations where !locations.contains(where: { $0.text.lowercased() == place.lowercased() }) {
            locations.append(ItemTextEntry(text: place))
        }
    }
    private func save() {
        applyTitleDetails()
        let edited = edited
        item.locations = edited.locations
        item.people = edited.people
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

private struct LinkedItemsOverview: View {
    let sourceID: UUID
    @State private var through: Day
    @State private var onlyChanges = false
    @EnvironmentObject private var store: PlanStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(source: PlanItem) {
        sourceID = source.id
        let start = max(Day(Date()), source.day).date()
        _through = State(initialValue: Day(Calendar.current.date(byAdding: .day, value: 60, to: start)!))
    }
    var body: some View {
        NavigationStack {
            Group {
                if let source = store.item(sourceID) {
                    let entries = store.linkedItems(of: source, through: through)
                    let changed = entries.filter { $0.status != .linked }
                    List {
                        Section {
                            Text("\(entries.filter { $0.status == .linked }.count) linked · \(entries.filter { $0.status == .changed }.count) changed · \(entries.filter { $0.status == .deleted }.count) deleted")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Toggle("Changed or deleted only", isOn: $onlyChanges)
                            if !changed.isEmpty {
                                Button("Restore all changed or deleted items") { restore(changed) }
                            }
                        } footer: {
                            Text("Restore returns each day to the original’s saved details and schedule. Existing completion and cancellation are kept; deleted items return open.")
                        }
                        Section {
                            ForEach(entries.filter { !onlyChanges || $0.status != .linked }) { entry in
                                entryRow(entry, source: source)
                            }
                        }
                        if store.linkedItemsContinue(after: through, for: source) {
                            Button("Show later items") {
                                through = Day(Calendar.current.date(byAdding: .day, value: 60, to: through.date())!)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Item unavailable", systemImage: "link", description: Text("The original item is no longer in your plan."))
                }
            }
            .navigationTitle("Linked items").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func entryRow(_ entry: LinkedItemEntry, source: PlanItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.origin.day.date().formatted(date: .abbreviated, time: .omitted))
                    .font(.body.weight(.medium))
                Text(entry.item?.title ?? source.title)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(status(entry, source: source))
                    .font(.caption).foregroundStyle(.secondary)
                if let actual = entry.item, entry.status == .changed {
                    if actual.day != entry.origin.day {
                        Text("Moved to " + actual.day.date().formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let start = actual.start() {
                        Text(start.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.status != .linked {
                Button("Restore") { restore([entry]) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .accessibilityLabel("Restore item for " + entry.origin.day.date().formatted(date: .complete, time: .omitted))
                    .accessibilityHint("Uses the original’s saved details and schedule")
            }
        }
        .padding(.vertical, 4)
    }
    private func status(_ entry: LinkedItemEntry, source: PlanItem) -> String {
        let label = entry.item?.id == sourceID ? "Original" : entry.status.rawValue.capitalized
        return label + (entry.item?.isComplete == true ? " · Completed" : entry.item?.isCancelled == true ? " · Cancelled" : "")
    }
    private func restore(_ entries: [LinkedItemEntry]) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { store.restoreLinkedItems(entries) }
    }
}

/// Own the Return key before it becomes a newline. SwiftUI's multiline TextField can
/// recommit an earlier editing value when its binding strips a newline and removes focus.
private struct ItemTitleField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .medium))
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .done
        view.autocorrectionType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = "What’s on your day?"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // While typing, the text view owns the live value. A delayed SwiftUI update must
        // never write an older copy over it, including edits that only remove a space.
        if !view.isFirstResponder, view.text != text { view.text = text }
        if focused, !view.isFirstResponder {
            // The field may not have a window yet on the first Form update.
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard coordinator?.parent.focused == true else { return }
                view?.becomeFirstResponder()
            }
        } else if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, uiView.font?.lineHeight ?? 24))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ItemTitleField
        init(_ parent: ItemTitleField) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.text = textView.text
            parent.focused = false
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                // Capture the exact visible text before ending the input session.
                parent.text = textView.text
                parent.focused = false
                textView.resignFirstResponder()
                return false
            }
            guard text.contains(where: \.isNewline) else { return true }
            // A multiline paste stays a single wrapping title and keeps its spaces.
            let replacement = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            textView.text = (textView.text as NSString).replacingCharacters(in: range, with: replacement)
            textView.selectedRange = NSRange(location: range.location + replacement.utf16.count, length: 0)
            parent.text = textView.text
            return false
        }
    }
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

private enum PickerRow: Hashable { case schedule, reminders, deadline }

private enum ScheduleField: Equatable { case day, time, end, reminder(Int), deadline }

private extension EnvironmentValues {
    /// Tells the editor when a picker's popover appears and has fully gone.
    @Entry var popoverShown = PopoverShownAction { _ in }
}

/// Wraps the closure so the environment can compare it: it only ever reports to the editor that
/// set it, so any two count as equal and updating it never invalidates the pills.
private struct PopoverShownAction: Equatable {
    let action: (Bool) -> Void
    func callAsFunction(_ shown: Bool) { action(shown) }
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

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
    @Environment(\.popoverShown) private var popoverShown
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
                        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.pillText))
                    } else {
                        HStack(spacing: 6) { Image(systemName: "plus").accessibilityHidden(true); Text(addLabel ?? addTitle) }
                            .foregroundStyle(.pillSecondaryText)
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
                        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.pillSecondaryText))
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
                    : tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.pillFill), in: .capsule)
        .overlay {
            if value == nil {
                Capsule().strokeBorder(Color.pillSecondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
        }
        // Keep the arrow on top so the popover opens below the button at full width,
        // rather than beside it where a calendar would be clipped.
        .popover(isPresented: $isEditing, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            // A fixed width lets the chips wrap before the popover measures its height.
            picker().frame(width: 320).padding().presentationCompactAdaptation(.popover)
                // Taps reach the editor behind, so the next pill (End after Time) opens in one tap.
                .background(PopoverPassthrough())
                .onAppear { popoverShown(true) }
                .onDisappear { popoverShown(false) }
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
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.pillText))
                    .background(isSelected ? AnyShapeStyle(.pillText) : AnyShapeStyle(.pillFill), in: .capsule)
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
            // Chosen, it reads like a reminder pill in the persona's colour; the rest look like the
            // editor's add buttons, a dashed outline with grey text.
            .foregroundStyle(isSelected ? AnyShapeStyle(persona.color) : AnyShapeStyle(.pillSecondaryText))
            .background(isSelected ? persona.color.opacity(0.14) : .clear, in: .capsule)
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(Color.pillSecondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(persona.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Removes this persona" : "Adds this persona")
    }
}

/// Shared by editor pills and focussed actions: wrap only the views that do not fit.
struct FlowLayout: Layout {
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
    /// The new pill's text, owned by the editor so Save can include it before the pill is added.
    @Binding var draft: String
    /// Called when one of the pills starts being typed in.
    var onEditing: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Field?
    @State private var adding = false
    /// Set while the add button starts another pill from the new one, so losing focus keeps the field.
    @State private var continuing = false
    /// Set while the new pill's ✕ waits for the keyboard to go, so losing focus doesn't keep its text.
    @State private var discardingDraft = false
    @State private var keyboardShown = false
    private enum Field: Hashable { case entry(UUID), new }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach($entries) { $entry in
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(.pillSecondaryText).accessibilityHidden(true)
                    field(text: $entry.text, focusedAs: .entry(entry.id))
                    removeButton(label: Text("\(Text(kind.removeTitle)): \(entry.text)")) {
                        removeAfterKeyboard { entries.removeAll { $0.id == entry.id } }
                    }
                }
                .foregroundStyle(.pillText)
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(minHeight: 36)
                .background(.pillFill, in: .capsule)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if adding {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(.pillSecondaryText).accessibilityHidden(true)
                    field(text: $draft, focusedAs: .new)
                    // Remove straight away, like a pill already added: drops what's being typed.
                    removeButton(label: Text("\(Text(kind.removeTitle)): \(draft)")) {
                        discardingDraft = true
                        // The text goes once the pill has, so it doesn't flash its placeholder on the way out.
                        removeAfterKeyboard({ adding = false }, then: { draft = ""; discardingDraft = false })
                    }
                }
                .foregroundStyle(.pillText)
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(minHeight: 36)
                .background(.pillFill, in: .capsule)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            // While typing a new one, the add button stays so the next can follow straight away.
            if !adding || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: startAdding) {
                    AddPillLabel(title: kind.name)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(kind.addTitle)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: entries.count)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardShown = false }
        .onChange(of: focus) { old, new in
            if new != nil { onEditing() }
            // Settle a pill once its field loses focus: keep new text, and drop any left empty.
            if old == .new, new != .new, !discardingDraft {
                animate {
                    keepDraft()
                    if !continuing { adding = false }
                }
            }
            if case .entry(let id) = old, let index = entries.firstIndex(where: { $0.id == id }) {
                let text = entries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { animate { entries.remove(at: index) } } else { entries[index].text = text }
            }
        }
    }
    private func startAdding() {
        continuing = true
        animate { keepDraft(); adding = true }
        // Focus once the field exists.
        Task { @MainActor in
            focus = .new
            continuing = false
        }
    }
    private func keepDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if !text.isEmpty { entries.append(ItemTextEntry(text: text)) }
    }
    private func field(text: Binding<String>, focusedAs field: Field) -> some View {
        // The pill fits what is typed: a hidden copy of the text (or the placeholder while empty)
        // sets the width, as a text field on its own takes a fixed default width.
        Text(text.wrappedValue.isEmpty ? kind.placeholder : text.wrappedValue)
            .fixedSize()
            .padding(.trailing, 2)  // room for the cursor
            .frame(minWidth: 16, alignment: .leading)
            .hidden()
            .overlay(alignment: .leading) {
                TextField(kind.placeholder, text: text)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .focused($focus, equals: field)
                    .accessibilityLabel(kind.name)
            }
    }
    /// Removes a pill with its usual animation. With the keyboard up, the keyboard goes first: it
    /// takes the sheet from full height back to a card, and a pill leaving during that would vanish
    /// in the jump. So the pill waits until the keyboard has hidden (or briefly, without one).
    private func removeAfterKeyboard(_ change: @escaping () -> Void, then completion: @escaping () -> Void = {}) {
        func remove() {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25), change, completion: completion)
        }
        guard keyboardShown else { remove(); return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardDidHideNotification) { break }
                }
                group.addTask { try? await Task.sleep(for: .seconds(0.8)) }
                await group.next()
                group.cancelAll()
            }
            remove()
        }
    }
    private func removeButton(label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical).foregroundStyle(.pillSecondaryText)
                .frame(minHeight: 36)
                // Reach a 44-point target without making the pill taller.
                .contentShape(.rect.inset(by: -6))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
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
        .foregroundStyle(.pillSecondaryText)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .overlay(Capsule().strokeBorder(Color.pillSecondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(.capsule)
    }
}

/// While a picker's popover is open, closes it when a tap lands on the editor behind it. The tap
/// still reaches what it landed on, so another pill opens its own picker in the same tap.
private struct PopoverDismissal: UIViewRepresentable {
    let isActive: Bool
    let dismiss: () -> Void
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {
        uiView.isActive = isActive
        uiView.dismiss = dismiss
    }
    static func dismantleUIView(_ uiView: InstallerView, coordinator: ()) { uiView.uninstall() }

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        var isActive = false
        var dismiss: () -> Void = {}
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
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

        // After the tapped pill's own action, which then sees which picker was open and can toggle it.
        @objc private func tapped() { DispatchQueue.main.async { [dismiss] in dismiss() } }

        /// Only taps on the editor itself: the popover, and pickers it presents in turn, sit outside its view.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isActive, let view = touch.view, let editor = editorController?.view else { return false }
            return view.isDescendant(of: editor)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        private var editorController: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, controller.presentingViewController != nil { return controller }
                responder = current.next
            }
            return nil
        }
    }
}

/// Lets taps outside a popover reach the view it was presented from, instead of only closing it.
/// SwiftUI's `presentationBackgroundInteraction` covers sheets but not popovers.
private struct PopoverPassthrough: UIViewRepresentable {
    func makeUIView(context: Context) -> PassthroughView { PassthroughView() }
    func updateUIView(_ uiView: PassthroughView, context: Context) {}

    final class PassthroughView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            apply()
            // UIKit resets the pass-through views once the popover has finished appearing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.apply() }
        }
        private func apply() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let popover = controller.popoverPresentationController,
                   let presenting = controller.presentingViewController {
                    popover.passthroughViews = [presenting.view]
                    return
                }
                responder = current.next
            }
        }
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
                // Cancel and Save act on their own. Closing the keyboard first would shrink the
                // sheet from full height and move the button away before the tap lands.
                if current is UINavigationBar { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

extension ShapeStyle where Self == Color {
    // Pills use plain system colours rather than the vibrant `.fill` and `.primary`/`.secondary`
    // styles: those are drawn differently on the sheet's glass and on its opaque full-height page,
    // so pills would change colour in one frame when the keyboard takes the sheet to full height.
    /// An unset pill's fill.
    static var pillFill: Color { Color(.secondarySystemFill) }
    static var pillText: Color { Color(.label) }
    static var pillSecondaryText: Color { Color(.secondaryLabel) }
}
