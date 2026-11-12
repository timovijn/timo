import SwiftUI

/// "Add to Timo": what's being shared, a new item to put it in, and the items to choose from
/// (today's, then upcoming, then earlier ones, or what a search finds). Choosing one adds the
/// attachments and closes the sheet.
struct ShareView: View {
    @ObservedObject var model: ShareModel
    @State private var query = ""
    @State private var newTitle = ""
    @State private var addedTo: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let now = Date()
    private var today: Day { Day(now) }

    var body: some View {
        NavigationStack {
            List {
                Section("Adding") { sharedRows }
                if model.plan == nil {
                    Section {
                        Text("Open Timo once, then share again.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("New item") { newItemRow }
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { itemRow($0) }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search items")
            .navigationTitle("Add to Timo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { model.cancelled() }
                }
            }
            .overlay { if let addedTo { confirmation(addedTo) } }
            .disabled(addedTo != nil)
            .sensoryFeedback(.success, trigger: addedTo != nil)
            .alert("Couldn’t add this", isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {} message: {
                Text(model.issue ?? "")
            }
        }
        .onChange(of: model.suggestedTitle, initial: true) { _, title in
            if newTitle.isEmpty { newTitle = title }
        }
    }

    @ViewBuilder private var sharedRows: some View {
        if model.loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading what you shared…").foregroundStyle(.secondary)
            }
        } else if model.attachments.isEmpty {
            Text("Nothing here can be added to an item.").foregroundStyle(.secondary)
        }
        ForEach(model.attachments) { attachment in
            Label {
                Text(verbatim: attachment.title).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: attachment.symbol).foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(attachment.kindName): \(attachment.title)")
        }
    }

    private var canAdd: Bool { !model.loading && !model.attachments.isEmpty }

    private var newItemRow: some View {
        HStack {
            // Read like a typed item: "tomorrow at 9 dentist" gets its day and time.
            TextField("Title, such as “tomorrow at 9 dentist”", text: $newTitle)
                .submitLabel(.done)
                .onSubmit(addNewItem)
            Button("Add", systemImage: "plus.circle.fill", action: addNewItem)
                .labelStyle(.iconOnly)
                .font(.title2)
                .disabled(!canAdd || newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add as a new item")
        }
    }

    private func itemRow(_ item: PlanItem) -> some View {
        Button { add(to: item) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .foregroundStyle(item.isSettled ? .secondary : .primary)
                    .strikethrough(item.isCancelled)
                    .lineLimit(2)
                Text(verbatim: subtitle(item))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .accessibilityHint(repeatsNote(item) ?? "Adds what you shared to this item")
    }

    private func confirmation(_ title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("Added to “\(title)”").font(.headline).multilineTextAlignment(.center)
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    // MARK: Choosing

    private struct Group { let title: String; let items: [PlanItem] }

    /// What a search finds, or today's items, then upcoming and earlier ones (each list kept short).
    private var groups: [Group] {
        guard let plan = model.plan else { return [] }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let found = Planner.search(query, in: plan.items, now: now).flatMap(\.items)
            return [Group(title: found.isEmpty ? "No items found" : "Found", items: Array(found.prefix(50)))]
        }
        let shownToday = plan.items.filter { $0.shows(on: today, now: now) }
            .sorted { ($0.minute ?? -1, $0.createdAt) < ($1.minute ?? -1, $1.createdAt) }
        let todayIDs = Set(shownToday.map(\.id))
        let others = plan.items.filter { !todayIDs.contains($0.id) }
        let upcoming = others.filter { $0.day > today }
            .sorted { ($0.day, $0.minute ?? -1) < ($1.day, $1.minute ?? -1) }
        let earlier = others.filter { $0.day < today }.sorted { $0.day > $1.day }
        return [Group(title: "Today", items: shownToday),
                Group(title: "Upcoming", items: Array(upcoming.prefix(30))),
                Group(title: "Earlier", items: Array(earlier.prefix(30)))]
            .filter { !$0.items.isEmpty }
    }

    private func subtitle(_ item: PlanItem) -> String {
        var parts: [String] = []
        let day = item.day.date()
        if item.day < today && item.shows(on: today, now: now) {
            // Under Today, an unfinished item from an earlier day reads as it does in the app.
            parts.append("Carried from " + day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        } else if item.day == today { parts.append("Today") }
        else if Calendar.current.isDateInTomorrow(day) { parts.append("Tomorrow") }
        else if Calendar.current.isDateInYesterday(day) { parts.append("Yesterday") }
        else { parts.append(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) }
        if let start = item.start() { parts.append(start.formatted(date: .omitted, time: .shortened)) }
        if let note = repeatsNote(item) { parts.append(note) }
        if !item.attachments.isEmpty { parts.append(item.attachments.count == 1 ? "1 attachment" : "\(item.attachments.count) attachments") }
        return parts.joined(separator: " · ")
    }
    /// Like editing it: a later day of a repeating item gets the attachments on its own.
    private func repeatsNote(_ item: PlanItem) -> String? {
        guard item.seriesID != nil, let plan = model.plan else { return nil }
        return Planner.isOriginal(item, in: plan.series) ? "Repeats, adds to every day" : "Repeats, adds to this day only"
    }

    private func add(to item: PlanItem) {
        guard canAdd, model.add(to: item.id) else { return }
        done(item.title)
    }
    private func addNewItem() {
        let typed = newTitle.trimmingCharacters(in: .whitespaces)
        guard canAdd, !typed.isEmpty else { return }
        var item = newItem(from: typed)
        item.attachments = model.attachments
        guard model.add(to: nil, newItem: item) else { return }
        done(item.title)
    }
    private func done(_ title: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { addedTo = title }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            model.finish()
        }
    }

    /// A new item from a typed line, as the editor reads a title: its day, time, repeat, personas,
    /// people and places, Anytime today when it names none.
    private func newItem(from text: String) -> PlanItem {
        let items = model.plan?.items ?? []
        func unique(_ names: [String]) -> [String] {
            var seen: Set<String> = []
            return names.filter { seen.insert($0.lowercased()).inserted }
        }
        let entry = QuickEntry(text, on: today, now: now, knownPeople: unique(items.flatMap(\.people)),
                               knownPlaces: unique(items.flatMap(\.locations)))
        let title = entry.title.isEmpty ? text : entry.title
        var item = PlanItem(title: title, day: entry.day, minute: entry.minute,
                            endDay: entry.minute == nil ? entry.endDay : nil,
                            // Only Anytime items carry over, as in the editor.
                            movesToNextDay: entry.minute == nil && entry.endDay == nil,
                            locations: entry.locations, people: entry.people)
        if let minute = entry.minute, let end = entry.endMinute, let start = item.start() {
            item.end = start.addingTimeInterval(TimeInterval((end - minute) * 60))
        }
        item.repeatRule = entry.repeatRule
        item.repeatWeekdays = entry.repeatWeekdays
        item.personas = entry.personas
        return item
    }
}
