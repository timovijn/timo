import SwiftUI
import Combine

struct DayView: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var editing: PlanItem?
    @State private var pickingDate = false
    @State private var deleting: PlanItem?
    @State private var now = Date()
    @State private var lastToday = Day(Date())
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var day: Day { Day(date) }
    private var visible: [PlanItem] {
        store.items.filter { $0.appears(on: day) }.sorted {
            if $0.minute != $1.minute { return ($0.minute ?? -1) < ($1.minute ?? -1) }
            return $0.createdAt < $1.createdAt
        }
    }
    private var anyTime: [PlanItem] { visible.filter { $0.minute == nil } }
    private var timed: [PlanItem] { visible.filter { $0.minute != nil } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(date.formatted(.dateTime.weekday(.wide))).font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text(date.formatted(.dateTime.day().month(.wide))).font(.title3).foregroundStyle(.secondary)
                        if !visible.isEmpty {
                            Text("\(visible.filter(\.isComplete).count) of \(visible.count) complete")
                                .font(.subheadline).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                    }.padding(.vertical, 18)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                if visible.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Room for your day", systemImage: "sun.horizon")
                        } description: {
                            Text("A small task. A little time set aside. Start with what matters today.")
                        } actions: {
                            Button("Add an item", systemImage: "plus") { add() }.buttonStyle(.borderedProminent)
                            if store.items.isEmpty { Button("Try a sample day") { store.addSampleDay(); date = Calendar.current.startOfDay(for: Date()) } }
                        }.listRowBackground(Color.clear)
                    }.listRowSeparator(.hidden)
                }
                if !anyTime.isEmpty {
                    Section("Any time") { ForEach(anyTime) { row($0) } }
                }
                if !timed.isEmpty {
                    Section {
                        ForEach(timed) { item in
                            if day == Day(now), let start = item.start(), start > now,
                               item.id == timed.first(where: { ($0.start() ?? .distantPast) > now })?.id {
                                nowMarker
                            }
                            row(item)
                        }
                        if day == Day(now), !timed.contains(where: { ($0.start() ?? .distantPast) > now }) { nowMarker }
                    } header: { Text("Your day") }
                }
                Section {
                    Text("timo").font(.system(.footnote, design: .rounded).weight(.medium)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { pickingDate = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Choose a day")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { date = Calendar.current.startOfDay(for: Date()) }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                    Button { pickingDate = true } label: { Text(date, format: .dateTime.day().month(.abbreviated)).font(.subheadline.weight(.medium)) }
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next day")
                    Spacer()
                    Button { add() } label: { Image(systemName: "plus").font(.title3.weight(.semibold)) }
                        .buttonStyle(.glassProminent).tint(.primary).accessibilityLabel("Add task or event")
                }
            }
            .sheet(item: $editing) { item in ItemEditor(item: item).environmentObject(store) }
            .sheet(isPresented: $pickingDate) {
                NavigationStack {
                    DatePicker("Day", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).padding()
                        .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pickingDate = false } } }
                }.presentationDetents([.medium, .large])
            }
            .confirmationDialog("Delete this item?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let item = deleting {
                    if !store.children(of: item).isEmpty {
                        Button("Delete parent, keep subtasks", role: .destructive) { store.delete(item, children: false); deleting = nil }
                        Button("Delete parent and subtasks", role: .destructive) { store.delete(item, children: true); deleting = nil }
                    } else { Button("Delete item", role: .destructive) { store.delete(item, children: false); deleting = nil } }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            }
            .onReceive(timer) { refresh($0) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(Date()) } }
        }.tint(.primary)
    }
    private var nowMarker: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            Text(now, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }.accessibilityLabel("Current time \(now.formatted(date: .omitted, time: .shortened))")
            .listRowSeparator(.hidden).padding(.vertical, 4)
    }
    private func row(_ item: PlanItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item) }
                } label: {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.title2.weight(.light)).foregroundStyle(item.isComplete ? .secondary : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.isComplete ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
                    .sensoryFeedback(.success, trigger: item.isComplete)
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let start = item.start() {
                            HStack(spacing: 6) {
                                Text(timeLabel(item, start: start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if item.kind == .event, !item.isComplete, start <= now, (item.end ?? .distantPast) > now {
                                    Text("In progress").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(item.title).font(.body.weight(.medium)).foregroundStyle(item.isComplete ? .secondary : .primary)
                            .strikethrough(item.isComplete, pattern: .solid, color: Color.secondary.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let parent = store.item(item.parentID) {
                            Text(parent.title + (parent.kind == .event && (parent.end ?? .distantFuture) < now ? " · Past event" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let from = item.carriedFrom {
                            Text("Carried from \(from.date().formatted(.dateTime.day().month(.abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !store.children(of: item).isEmpty {
                            let children = store.children(of: item)
                            Text("\(children.filter(\.isComplete).count)/\(children.count) subtasks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Open details and edit")
            }
            if !item.suggestionDismissed && (item.isElapsed(now: now) || Planner.suggestsParentCompletion(item, in: store.items)) {
                HStack(spacing: 14) {
                    Menu {
                        Button("Mark complete", systemImage: "checkmark") { store.toggle(item) }
                        Button("Leave open", systemImage: "minus") { store.dismissSuggestion(item) }
                        Button("Reschedule", systemImage: "calendar") { editing = item }
                    } label: {
                        Label(Planner.suggestsParentCompletion(item, in: store.items) ? "Subtasks finished · Review" : "Time passed · Review", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.leading, 58).padding(.bottom, 8)
            }
        }
        .padding(.vertical, 5)
        .listRowSeparatorTint(Color.primary.opacity(0.07))
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { deleting = item }
            Button("Edit") { editing = item }.tint(.secondary)
        }
        .swipeActions(edge: .leading) { Button(item.isComplete ? "Undo" : "Complete") { store.toggle(item) }.tint(.secondary) }
    }
    private func timeLabel(_ item: PlanItem, start: Date) -> String {
        let startText = (item.day == day ? "" : start.formatted(.dateTime.day().month(.abbreviated)) + " · ") + start.formatted(date: .omitted, time: .shortened)
        guard item.kind == .event, let end = item.end else { return startText }
        let endText = end.formatted(date: .omitted, time: .shortened)
        return startText + " – " + endText + (Day(end) != item.day ? " (+\(Calendar.current.dateComponents([.day], from: item.day.date(), to: Day(end).date()).day ?? 1)d)" : "")
    }
    private func refresh(_ tick: Date) {
        let today = Day(tick)
        if today != lastToday && day == lastToday { date = Calendar.current.startOfDay(for: tick) }
        lastToday = today; now = tick; store.reconcile(now: tick)
    }
    private func add() { editing = PlanItem(title: "", day: day) }
    private func move(_ delta: Int) { date = Calendar.current.date(byAdding: .day, value: delta, to: date)! }
}
