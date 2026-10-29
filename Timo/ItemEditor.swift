import SwiftUI

struct ItemEditor: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.dismiss) private var dismiss
    @State var item: PlanItem
    @State private var issue: String?
    @State private var childEditor: PlanItem?
    @State private var showingDelete = false
    @FocusState private var titleFocused: Bool
    private var existing: Bool { store.item(item.id) != nil }
    private var children: [PlanItem] { store.children(of: item) }
    private var parentOptions: [PlanItem] { store.items.filter { $0.id != item.id && $0.parentID == nil } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What’s on your day?", text: $item.title, axis: .vertical)
                        .font(.title3.weight(.medium)).focused($titleFocused)
                    Picker("Type", selection: $item.kind) {
                        Text("Task").tag(ItemKind.task); Text("Event").tag(ItemKind.event)
                    }.pickerStyle(.segmented).disabled(item.parentID != nil)
                }
                Section("Schedule") {
                    DatePicker("Day", selection: Binding(get: { item.day.date() }, set: { new in
                        let oldStart = item.start(); item.day = Day(new)
                        if item.kind == .event, let oldStart, let newStart = item.start(), let end = item.end {
                            item.end = end.addingTimeInterval(newStart.timeIntervalSince(oldStart))
                        }
                        item.carriedFrom = nil; item.suggestionDismissed = false
                    }), displayedComponents: .date)
                    if item.kind == .task {
                        Toggle("Set a time", isOn: Binding(get: { item.minute != nil }, set: { item.minute = $0 ? 9 * 60 : nil; item.suggestionDismissed = false }))
                    }
                    if item.minute != nil {
                        DatePicker(item.kind == .event ? "Starts" : "Time", selection: Binding(get: { item.start() ?? item.day.date() }, set: { new in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: new)
                            item.minute = (c.hour ?? 0) * 60 + (c.minute ?? 0); item.suggestionDismissed = false
                        }), displayedComponents: .hourAndMinute)
                    }
                    if item.kind == .event {
                        DatePicker("Ends", selection: Binding(get: { item.end ?? Date() }, set: { item.end = $0; item.suggestionDismissed = false }), displayedComponents: [.date, .hourAndMinute])
                    }
                    if let from = item.carriedFrom { Text("Carried from \(from.date().formatted(date: .abbreviated, time: .omitted)). Choosing a date gives this task a fresh plan.").font(.caption).foregroundStyle(.secondary) }
                    if existing { Text("Originally planned for \(item.originalDay.date().formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Notes") { TextField("Anything to remember", text: $item.notes, axis: .vertical).lineLimit(3...8) }
                if item.kind == .task && children.isEmpty {
                    Section("Linked work") {
                        Picker("Parent", selection: $item.parentID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(parentOptions) { parent in Text(parent.title).tag(Optional(parent.id)) }
                        }
                        if let parent = store.item(item.parentID) {
                            Button("Open \(parent.title)") { childEditor = parent }
                            if parent.kind == .event && (parent.end ?? .distantFuture) < Date() {
                                Text("This task is linked to an event in the past.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if item.parentID == nil {
                    Section {
                        ForEach(children) { child in
                            HStack {
                                Button { store.toggle(child) } label: { Image(systemName: child.isComplete ? "checkmark.circle.fill" : "circle").frame(minWidth: 44, minHeight: 44) }
                                    .buttonStyle(.plain).accessibilityLabel(child.isComplete ? "Undo \(child.title)" : "Complete \(child.title)")
                                Button { childEditor = child } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(child.title).foregroundStyle(child.isComplete ? .secondary : .primary)
                                        Text(child.day.date(), format: .dateTime.day().month(.abbreviated)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                        if existing {
                            Button("Add subtask", systemImage: "plus") { childEditor = PlanItem(title: "", day: item.day, parentID: item.id) }
                        } else { Text("Save this item to add subtasks.").foregroundStyle(.secondary) }
                    } header: { Text("Subtasks · \(children.filter(\.isComplete).count)/\(children.count)") }
                }
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
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold).disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onChange(of: item.kind) { _, kind in
                if kind == .event {
                    item.minute = item.minute ?? 9 * 60
                    item.end = item.end ?? item.start()!.addingTimeInterval(3600)
                    item.parentID = nil
                } else { item.end = nil }
                item.suggestionDismissed = false
            }
            .onAppear { if !existing { titleFocused = true } }
            .sheet(item: $childEditor) { linked in ItemEditor(item: linked).environmentObject(store) }
            .alert("Check this item", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
            .confirmationDialog("Delete this item?", isPresented: $showingDelete, titleVisibility: .visible) {
                if children.isEmpty { Button("Delete item", role: .destructive) { store.delete(item, children: false); dismiss() } }
                else {
                    Button("Delete parent, keep subtasks", role: .destructive) { store.delete(item, children: false); dismiss() }
                    Button("Delete parent and subtasks", role: .destructive) { store.delete(item, children: true); dismiss() }
                }
            }
        }
    }
    private func save() {
        // A linked item may have been deleted in a nested editor.
        if let parentID = item.parentID, store.item(parentID) == nil { item.parentID = nil }
        do { try store.save(item); if store.errorMessage == nil { dismiss() } }
        catch { issue = error.localizedDescription }
    }
}
