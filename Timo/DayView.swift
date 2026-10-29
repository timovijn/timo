import SwiftUI
import Combine

struct DayView: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var editing: PlanItem?
    @State private var pickingDate = false
    @State private var reviewing = false
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
    private var reviewItems: [PlanItem] {
        visible.filter(needsReview)
    }
    private func needsReview(_ item: PlanItem) -> Bool {
        !item.isComplete && !item.suggestionDismissed &&
        (item.isElapsed(now: now) || Planner.suggestsParentCompletion(item, in: store.items))
    }
    var body: some View {
        NavigationStack {
            ZStack {
                dayList
                    .id(reviewing)
                    .zIndex(1)
                    .transition(reviewTransition)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { pickingDate = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Choose a day")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { date = Calendar.current.startOfDay(for: Date()) }
                }
                if reviewing || !reviewItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            refresh(Date())
                            setReviewing(!reviewing)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: reviewing ? "line.3.horizontal.decrease" : "exclamationmark.triangle.fill")
                                Text("\(reviewItems.count)").font(.caption.weight(.semibold).monospacedDigit())
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .glassEffect(.regular.tint(.orange.opacity(reviewing ? 0.35 : 0.22)).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(reviewing ? "Show full day" : "Review \(reviewItems.count) items")
                        .accessibilityValue(reviewing ? "Review filter on" : "Review filter off")
                        .accessibilityHint("Toggles items needing review for this day")
                    }.sharedBackgroundVisibility(.hidden)
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
            .onChange(of: date) { _, _ in reviewing = false }
            .onReceive(timer) { refresh($0) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(Date()) } }
        }.tint(.primary)
    }
    private var reviewTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .offset(y: -6))
        )
    }
    private var dayList: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        Text(date.formatted(.dateTime.day().month(.wide)))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if reviewing {
                        Text("\(reviewItems.count) to review")
                            .font(.caption).foregroundStyle(.orange)
                    } else if !visible.isEmpty {
                        Text("\(visible.filter(\.isComplete).count)/\(visible.count) complete")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if reviewing {
                if reviewItems.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("All clear", systemImage: "checkmark.circle")
                        } description: {
                            Text("There’s nothing left to review for this day.")
                        } actions: {
                            Button("Show full day") { setReviewing(false) }
                                .buttonStyle(.bordered)
                        }.listRowBackground(Color.clear)
                    }.listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(reviewItems) { row($0) }
                    } header: {
                        HStack {
                            Text("Needs review")
                            Spacer()
                            Button("Show all") { setReviewing(false) }
                                .textCase(nil)
                        }
                    }
                }
            } else {
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
            }
            Section {
                Text("timo").font(.system(.footnote, design: .rounded).weight(.medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
    }
    private var nowMarker: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            Text(now, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }.accessibilityLabel("Current time \(now.formatted(date: .omitted, time: .shortened))")
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
            .environment(\.defaultMinListRowHeight, 24)
    }
    private func row(_ item: PlanItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item) }
                } label: {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .light)).foregroundStyle(item.isComplete ? .secondary : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.isComplete ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
                    .sensoryFeedback(.success, trigger: item.isComplete)
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                itemTitle(item).fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                                if let start = item.start() { scheduleLabel(item, start: start).fixedSize() }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                itemTitle(item)
                                if let start = item.start() { scheduleLabel(item, start: start) }
                            }
                        }
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
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint(needsReview(item) ? "Needs review. Open details and edit" : "Open details and edit")
                if !reviewing && needsReview(item) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            if reviewing {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Planner.suggestsParentCompletion(item, in: store.items)
                         ? "All subtasks are complete"
                         : item.kind == .event ? "This event has ended" : "The scheduled time has passed")
                        .font(.caption).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { reviewActions(item, compact: true) }
                        VStack(alignment: .leading, spacing: 8) { reviewActions(item, compact: false) }
                    }
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }.padding(.leading, 52).padding(.bottom, 4)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.primary.opacity(0.07))
    }
    private func setReviewing(_ value: Bool) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.35)) { reviewing = value }
    }
    @ViewBuilder private func reviewActions(_ item: PlanItem, compact: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item) }
        } label: {
            Label("Complete", systemImage: "checkmark")
                .font(.subheadline.weight(.medium)).fixedSize()
                .padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(Color(.systemBackground))
                .background(Color.primary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Complete \(item.title)")
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.dismissSuggestion(item) }
        } label: {
            Text("Leave open").font(.subheadline.weight(.medium)).fixedSize()
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Leave \(item.title) open")
        Button { editing = item } label: {
            Group {
                if compact {
                    Image(systemName: "calendar.badge.clock").font(.body)
                } else {
                    Label("Reschedule", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.medium)).fixedSize()
                }
            }
            .padding(.horizontal, compact ? 0 : 14)
            .frame(minWidth: 44, minHeight: 44)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reschedule \(item.title)")
        .help("Reschedule")
    }
    private func itemTitle(_ item: PlanItem) -> some View {
        Text(item.title).font(.body.weight(.medium))
            .foregroundStyle(item.isComplete ? .secondary : .primary)
            .strikethrough(item.isComplete, pattern: .solid, color: Color.secondary.opacity(0.45))
    }
    private func scheduleLabel(_ item: PlanItem, start: Date) -> some View {
        HStack(spacing: 6) {
            Text(timeLabel(item, start: start)).font(.caption.monospacedDigit())
            if item.kind == .event, !item.isComplete, start <= now, (item.end ?? .distantPast) > now {
                Text("In progress").font(.caption2.weight(.medium))
            }
        }.foregroundStyle(.secondary)
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
