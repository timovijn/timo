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
    @FocusState private var titleFocused: Bool
    private var existing: Bool { store.item(item.id) != nil }
    init(item: PlanItem) {
        _item = State(initialValue: item)
        _locations = State(initialValue: (item.locations.isEmpty ? [""] : item.locations).map { ItemTextEntry(text: $0) })
        _people = State(initialValue: (item.people.isEmpty ? [""] : item.people).map { ItemTextEntry(text: $0) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What’s on your day?", text: $item.title, axis: .vertical)
                        .font(.title3.weight(.medium)).focused($titleFocused)
                }
                Section {
                    DatePicker("Day", selection: Binding(get: { item.day.date() }, set: { new in
                        Planner.updateStart(&item, day: Day(new), minute: item.minute)
                    }), displayedComponents: .date)
                    Toggle("Set a time", isOn: Binding(get: { item.minute != nil }, set: { enabled in
                        Planner.updateStart(&item, day: item.day, minute: enabled ? 9 * 60 : nil)
                    }))
                    if item.minute != nil {
                        DatePicker("Time", selection: Binding(get: { item.start() ?? item.day.date() }, set: { new in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: new)
                            Planner.updateStart(&item, day: item.day, minute: (c.hour ?? 0) * 60 + (c.minute ?? 0))
                        }), displayedComponents: .hourAndMinute)
                        Toggle("Add an end time", isOn: Binding(get: { item.end != nil }, set: { enabled in
                            item.end = enabled ? item.start()?.addingTimeInterval(3600) : nil
                            item.suggestionDismissed = false
                        }))
                    }
                    if item.end != nil {
                        DatePicker("Ends", selection: Binding(get: { item.end ?? item.day.date() }, set: { item.end = $0; item.suggestionDismissed = false }), displayedComponents: [.date, .hourAndMinute])
                    }
                    if let from = item.carriedFrom {
                        Text("Carried from \(from.date().formatted(date: .abbreviated, time: .omitted)). Choosing a date gives this item a fresh plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Schedule") } footer: {
                    Text("Leave the time open, choose a moment, or set aside a stretch of time.")
                }
                Section {
                    Toggle("Move to next day if unfinished", isOn: $item.movesToNextDay)
                } footer: {
                    Text(item.movesToNextDay
                         ? "Unfinished items move to today. A time range keeps its time and duration; a single time becomes any time."
                         : "This item stays on its scheduled day, even if unfinished.")
                }
                Section {
                    Toggle(isOn: Binding(get: { item.reminderAt != nil }, set: { enabled in
                        if !enabled { item.reminderAt = nil; return }
                        requestingReminder = true
                        Task { @MainActor in
                            defer { requestingReminder = false }
                            do {
                                if try await store.requestReminderPermission() {
                                    item.reminderAt = max(item.start() ?? Date().addingTimeInterval(3600), Date().addingTimeInterval(60))
                                } else {
                                    needsNotificationSettings = true
                                    issue = "Allow notifications for timo in Settings to receive reminders."
                                }
                            } catch { issue = "Reminders could not be enabled. \(error.localizedDescription)" }
                        }
                    })) {
                        Label("Remind me", systemImage: "alarm").foregroundStyle(.blue)
                    }.tint(.blue).disabled(requestingReminder)
                    if item.reminderAt != nil {
                        DatePicker("Remind me at", selection: Binding(get: { item.reminderAt ?? Date() }, set: { item.reminderAt = $0 }), displayedComponents: [.date, .hourAndMinute])
                        if let reminder = item.reminderAt, reminder <= Date() {
                            Text("This reminder has passed. Choose a new time to be reminded again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Reminders appear in the blue alarm filter and notify you at the chosen time.")
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
                        Button("Delete item", role: .destructive) { showingDelete = true }
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
            .confirmationDialog("Delete this item?", isPresented: $showingDelete, titleVisibility: .visible) {
                Button("Delete item", role: .destructive) { store.delete(item, children: false); dismiss() }
            }
        }
    }
    private func save() {
        item.locations = locations.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        item.people = people.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let reminder = item.reminderAt, reminder <= Date(), reminder != store.item(item.id)?.reminderAt {
            issue = "Choose a reminder time in the future."
            return
        }
        // Retain existing relationships unless their saved parent no longer exists.
        if let parentID = item.parentID, store.item(parentID) == nil { item.parentID = nil }
        do { try store.save(item); if store.errorMessage == nil { dismiss() } }
        catch { issue = error.localizedDescription }
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
