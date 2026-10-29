import SwiftUI
import Combine
import UIKit

struct DayView: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let reviewTint = Color.orange
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var editing: PlanItem?
    @State private var pickingDate = false
    @State private var changingDay = false
    @State private var queuedDates: [Date] = []
    private enum DayFilter { case all, review, reminders }
    @State private var filter: DayFilter = .all
    private var reviewing: Bool { filter == .review }
    private var showingReminders: Bool { filter == .reminders }
    private var reminderItems: [PlanItem] { visible.filter { $0.reminderAt != nil } }
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
    private var reviewItems: [PlanItem] {
        visible.filter(needsReview)
    }
    private func needsReview(_ item: PlanItem) -> Bool {
        !item.isComplete && !item.suggestionDismissed &&
        item.isElapsed(now: now)
    }
    var body: some View {
        NavigationStack {
            DayPager(day: day,
                     content: AnyView(dayList(for: date, filter: filter).environmentObject(store).tint(.primary)),
                     reduceMotion: reduceMotion) {
                changingDay = false
                advanceQueuedDay()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZStack {
                    HStack {
                        Spacer()
                        Button { add() } label: {
                            Image(systemName: "plus").font(.title3.weight(.regular)).foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass).tint(.primary)
                        .accessibilityLabel("Add item")
                    }.padding(.horizontal, 20)
                    dayNavigation
                }
                .frame(maxWidth: .infinity).frame(height: 72)
                .coordinateSpace(name: "dayNavigationDock")
                .padding(.bottom, 4)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if showingReminders || !reminderItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { setFilter(showingReminders ? .all : .reminders) } label: {
                            filterIcon("alarm.fill", tint: .blue, count: reminderItems.count, isActive: showingReminders)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showingReminders ? "Show full day" : "Show \(reminderItems.count) items with reminders")
                        .accessibilityValue(showingReminders ? "Reminder filter on" : "Reminder filter off")
                        .accessibilityAddTraits(showingReminders ? .isSelected : [])
                        .accessibilityHint("Toggles items with a reminder set for this day")
                    }.sharedBackgroundVisibility(.hidden)
                }
                if reviewing || !reviewItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { setReviewing(!reviewing) } label: {
                            filterIcon("exclamationmark.triangle.fill", tint: reviewTint, count: reviewItems.count, isActive: reviewing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(reviewing ? "Show full day" : "Review \(reviewItems.count) items")
                        .accessibilityValue(reviewing ? "Review filter on" : "Review filter off")
                        .accessibilityAddTraits(reviewing ? .isSelected : [])
                        .accessibilityHint("Toggles items needing review for this day")
                    }.sharedBackgroundVisibility(.hidden)
                }

            }
            .sheet(item: $editing) { item in ItemEditor(item: item).environmentObject(store) }
            .sheet(isPresented: $pickingDate) {
                NavigationStack {
                    DatePicker("Day", selection: Binding(get: { date }, set: { navigate(to: $0) }), displayedComponents: .date).datePickerStyle(.graphical).padding()
                        .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pickingDate = false } } }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: date) { _, _ in filter = .all }
            .onReceive(timer) { refresh($0) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(Date()); store.refreshReminders() } }
        }.tint(.primary)
    }
    private var dayNavigation: some View {
        HStack(spacing: 0) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 44, height: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous day")
            Text(date, format: .dateTime.day().month(.abbreviated))
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 70, minHeight: 56)
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
                        .onEnded { _ in goToToday() }
                        .exclusively(before: TapGesture().onEnded { pickingDate = true })
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Choose a day")
                .accessibilityValue(date.formatted(date: .complete, time: .omitted))
                .accessibilityHint("Tap for the calendar or hold for today")
                .accessibilityAction { pickingDate = true }
                .accessibilityAction(named: "Go to today") { goToToday() }
            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 44, height: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("dayNavigationDock"))
                .onEnded { swipe in
                    let horizontal = swipe.translation.width
                    guard abs(horizontal) >= 6, abs(horizontal) > abs(swipe.translation.height) * 1.2 else { return }
                    move(horizontal < 0 ? 1 : -1)
                }
        )
        .sensoryFeedback(.selection, trigger: date)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Next day") { move(1) }
        .accessibilityAction(named: "Previous day") { move(-1) }
    }
    private func navigate(to next: Date) {
        if changingDay {
            queuedDates.append(next)
            return
        }
        guard Day(next) != day else { setFilter(.all); return }
        withTransaction(Transaction(animation: nil)) {
            changingDay = true
            filter = .all
            date = next
        }
    }
    private func advanceQueuedDay() {
        while !queuedDates.isEmpty {
            let next = queuedDates.removeFirst()
            if Day(next) != day {
                navigate(to: next)
                return
            }
        }
    }
    private func goToToday() {
        queuedDates.removeAll()
        navigate(to: Calendar.current.startOfDay(for: Date()))
    }
    private func filterIcon(_ symbol: String, tint: Color, count: Int, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isActive ? tint : Color.secondary)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.tint(isActive ? tint.opacity(0.32) : .clear).interactive(), in: .circle)
            .overlay(alignment: .topTrailing) {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(tint, in: Capsule())
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .animation(reviewAnimation, value: isActive)
    }
    private func dayList(for date: Date, filter: DayFilter) -> some View {
        let day = Day(date)
        let visible = store.items.filter { $0.appears(on: day) }.sorted {
            if $0.minute != $1.minute { return ($0.minute ?? -1) < ($1.minute ?? -1) }
            return $0.createdAt < $1.createdAt
        }
        let reviewing = filter == .review
        let showingReminders = filter == .reminders
        let reviewItems = visible.filter(needsReview)
        let reminderItems = visible.filter { $0.reminderAt != nil }
        let filteredCount = showingReminders ? reminderItems.count : reviewItems.count
        let filterTint = showingReminders ? Color.blue : reviewTint
        let filtered = visible.filter { item in
            switch filter {
            case .all: true
            case .review: needsReview(item)
            case .reminders: item.reminderAt != nil
            }
        }
        let displayedAnyTime = filtered.filter { $0.minute == nil }
        let displayedTimed = filtered.filter { $0.minute != nil }
        let timed = visible.filter { $0.minute != nil }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
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
                                .font(.caption).foregroundStyle(reviewTint)
                        } else if showingReminders {
                            Text("\(reminderItems.count) with reminders")
                                .font(.caption).foregroundStyle(.blue)
                        } else if !visible.isEmpty {
                            Text("\(visible.filter(\.isComplete).count)/\(visible.count) complete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if filter != .all {
                        HStack(spacing: 8) {
                            Image(systemName: showingReminders ? "alarm" : "line.3.horizontal.decrease").foregroundStyle(filterTint)
                            Text("\(visible.count - filteredCount) items hidden")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Show all") { setReviewing(false) }
                                .fontWeight(.medium)
                                .frame(minHeight: 44)
                        }
                        .font(.caption)
                        .transition(.opacity)
                        .accessibilityElement(children: .contain)
                    }
                }.padding(.vertical, 6)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if reviewing && reviewItems.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("All clear", systemImage: "checkmark.circle")
                    } description: {
                        Text("There’s nothing left to review for this day. Your other items are still in the full day view.")
                    } actions: {
                        Button("Show full day") { setReviewing(false) }.buttonStyle(.bordered)
                    }.listRowBackground(Color.clear)
                }.listRowSeparator(.hidden)
            }
            if showingReminders && reminderItems.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No reminders set", systemImage: "alarm")
                    } description: {
                        Text("Open an item and turn on Remind me to add it here.")
                    } actions: {
                        Button("Show full day") { setFilter(.all) }.buttonStyle(.bordered)
                    }.listRowBackground(Color.clear)
                }.listRowSeparator(.hidden)
            }
            if filter == .all && visible.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Room for your day", systemImage: "sun.horizon")
                    } description: {
                        Text("Something to do. A little time set aside. Start with what matters today.")
                    } actions: {
                        Button("Add an item", systemImage: "plus") { add() }.buttonStyle(.borderedProminent)
                        if store.items.isEmpty { Button("Try a sample day") { store.addSampleDay(); goToToday() } }
                    }.listRowBackground(Color.clear)
                }.listRowSeparator(.hidden)
            }
            // Keep the same sections and item IDs in both modes so List can animate
            // individual removals and close their gaps instead of replacing the list.
            if !displayedAnyTime.isEmpty {
                Section("Any time") {
                    ForEach(displayedAnyTime) { row($0, filter: filter, day: day) }
                }
            }
            if !displayedTimed.isEmpty {
                Section {
                    ForEach(displayedTimed) { item in
                        if filter == .all, day == Day(now), let start = item.start(), start > now,
                           item.id == timed.first(where: { ($0.start() ?? .distantPast) > now })?.id {
                            nowMarker
                        }
                        row(item, filter: filter, day: day)
                    }
                    if filter == .all, day == Day(now), !timed.contains(where: { ($0.start() ?? .distantPast) > now }) { nowMarker }
                } header: { Text("Your day") }
            }
            Section {
                Text("timo").font(.system(.footnote, design: .rounded).weight(.medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        // Attach filtering animation to the list itself so toolbar actions and
        // in-list controls produce the same row insertion/removal transaction.
        .animation(reviewAnimation, value: filter)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
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
    private func row(_ item: PlanItem, filter: DayFilter, day: Day) -> some View {
        let reviewing = filter == .review
        let showingReminders = filter == .reminders
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item) }
                } label: {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .resizable().scaledToFit().frame(width: 22, height: 22)
                        .foregroundStyle(item.isComplete ? .secondary : .primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.isComplete ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
                    .accessibilityValue([needsReview(item) ? "Needs review" : nil, item.reminderAt != nil ? "Reminder set" : nil].compactMap { $0 }.joined(separator: ", "))
                    .sensoryFeedback(.success, trigger: item.isComplete)
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 12) {
                                itemTitle(item).fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                                if let start = item.start() { scheduleLabel(item, start: start, day: day).fixedSize() }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                itemTitle(item)
                                if let start = item.start() { scheduleLabel(item, start: start, day: day) }
                            }
                        }
                        if showingReminders, let reminder = item.reminderAt {
                            Label(reminder.formatted(date: .abbreviated, time: .shortened), systemImage: "alarm")
                                .font(.caption).foregroundStyle(.blue)
                        }
                        if !item.people.isEmpty || !item.locations.isEmpty {
                            itemDetailsLine(item)
                        }
                        if let from = item.carriedFrom {
                            Text("Carried from \(from.date().formatted(.dateTime.day().month(.abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint((needsReview(item) ? "Needs review. " : "") + (item.reminderAt != nil ? "Reminder set. " : "") + "Open details and edit")
            }
            if reviewing {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.end != nil ? "This time has ended" : "The scheduled time has passed")
                        .font(.caption).foregroundStyle(reviewTint)
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 0) { reviewActions(item) }
                        } else {
                            HStack(spacing: 0) { reviewActions(item) }
                        }
                    }
                    .background(reviewTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(reviewTint.opacity(0.12), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                    .padding(.bottom, 8)
                }
                .padding(.leading, 52).padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .padding(.trailing, (!reviewing && needsReview(item) ? 14.0 : 0) + (item.reminderAt != nil ? 14.0 : 0))
        .overlay(alignment: .trailing) {
            HStack(spacing: 8) {
                if !reviewing && needsReview(item) {
                    Circle().fill(reviewTint).frame(width: 6, height: 6)
                }
                if item.reminderAt != nil {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.primary.opacity(0.07))
    }
    private func itemDetailsLine(_ item: PlanItem) -> some View {
        HStack(spacing: 5) {
            if !item.people.isEmpty {
                Image(systemName: "person")
                    .font(.system(size: 9, weight: .light)).foregroundStyle(.quaternary)
                    .fixedSize()
                Text(item.people.joined(separator: ", "))
            }
            if !item.people.isEmpty && !item.locations.isEmpty {
                Text("·").foregroundStyle(.quaternary).fixedSize()
            }
            if !item.locations.isEmpty {
                Image(systemName: "mappin")
                    .font(.system(size: 9, weight: .light)).foregroundStyle(.quaternary)
                    .fixedSize()
                Text(item.locations.joined(separator: ", "))
            }
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .lineLimit(1).truncationMode(.tail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            item.people.isEmpty ? nil : "People: " + item.people.joined(separator: ", "),
            item.locations.isEmpty ? nil : "Locations: " + item.locations.joined(separator: ", ")
        ].compactMap { $0 }.joined(separator: ". "))
    }
    // Retained for a future use; review and reminder status currently use row dots.
    private func outlinedCompletionIndicator(_ item: PlanItem) -> some View {
        let review = needsReview(item)
        let reminder = item.reminderAt != nil
        return ZStack {
            if item.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .strokeBorder(review ? reviewTint : reminder ? Color.blue : Color.primary.opacity(0.8), lineWidth: 1.2)
                    .frame(width: 22, height: 22)
            }
            if reminder && (review || item.isComplete) {
                Circle().strokeBorder(Color.blue, lineWidth: 1)
                    .frame(width: 28, height: 28)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    private var reviewAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.5)
    }
    private func setReviewing(_ value: Bool) {
        setFilter(value ? .review : .all)
    }
    private func setFilter(_ value: DayFilter) {
        withAnimation(reviewAnimation) { filter = value }
    }
    @ViewBuilder private func reviewActions(_ item: PlanItem) -> some View {
        reviewAction("Complete", symbol: "checkmark", item: item) {
            withAnimation(reviewAnimation) { store.toggle(item) }
        }
        reviewActionDivider
        reviewAction("Leave open", symbol: "minus", item: item) {
            withAnimation(reviewAnimation) { store.dismissSuggestion(item) }
        }
        reviewActionDivider
        reviewAction("Reschedule", symbol: "calendar", item: item) { editing = item }
    }
    private var reviewActionDivider: some View {
        Rectangle().fill(reviewTint.opacity(0.15))
            .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 0.5,
                   height: dynamicTypeSize.isAccessibilitySize ? 0.5 : 24)
            .accessibilityHidden(true)
    }
    private func reviewAction(_ title: String, symbol: String, item: PlanItem,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Label(title, systemImage: symbol)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                            .frame(height: 20)
                        Text(title).font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(reviewTint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6).padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderless)
        .accessibilityLabel("\(title): \(item.title)")
    }
    private func itemTitle(_ item: PlanItem) -> some View {
        Text(item.title).font(.body.weight(.medium))
            .foregroundStyle(item.isComplete ? .secondary : .primary)
            .strikethrough(item.isComplete, pattern: .solid, color: Color.secondary.opacity(0.45))
    }
    private func scheduleLabel(_ item: PlanItem, start: Date, day: Day) -> some View {
        HStack(spacing: 6) {
            Text(timeLabel(item, start: start, day: day)).font(.caption.monospacedDigit())
            if item.end != nil, !item.isComplete, start <= now, (item.end ?? .distantPast) > now {
                Text("In progress").font(.caption2.weight(.medium))
            }
        }.foregroundStyle(.secondary)
    }
    private func timeLabel(_ item: PlanItem, start: Date, day: Day) -> String {
        let startText = (item.day == day ? "" : start.formatted(.dateTime.day().month(.abbreviated)) + " · ") + start.formatted(date: .omitted, time: .shortened)
        guard item.end != nil, let end = item.end else { return startText }
        let endText = end.formatted(date: .omitted, time: .shortened)
        return startText + " – " + endText + (Day(end) != item.day ? " (+\(Calendar.current.dateComponents([.day], from: item.day.date(), to: Day(end).date()).day ?? 1)d)" : "")
    }
    private func refresh(_ tick: Date) {
        let today = Day(tick)
        if today != lastToday && day == lastToday { date = Calendar.current.startOfDay(for: tick) }
        lastToday = today; now = tick; store.reconcile(now: tick)
    }
    private func add() { editing = PlanItem(title: "", day: day) }
    private func move(_ delta: Int) {
        let base = queuedDates.last ?? date
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: base) else { return }
        navigate(to: next)
    }
}

// UIKit owns the page movement so SwiftUI list transactions cannot suppress it.
private struct DayPager: UIViewControllerRepresentable {
    let day: Day
    let content: AnyView
    let reduceMotion: Bool
    let onTransitionCompleted: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(day: day, content: content) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.view.backgroundColor = .systemBackground
        controller.view.clipsToBounds = true
        controller.setViewControllers([context.coordinator.host], direction: .forward, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTransitionCompleted = onTransitionCompleted
        guard day != coordinator.day else {
            if !coordinator.isTransitioning { coordinator.host.rootView = content }
            return
        }
        let direction: UIPageViewController.NavigationDirection = day > coordinator.day ? .forward : .reverse
        let next = Coordinator.makeHost(content)
        coordinator.day = day
        coordinator.host = next
        coordinator.isTransitioning = true
        controller.setViewControllers([next], direction: direction, animated: !reduceMotion) { _ in
            coordinator.isTransitioning = false
            // Defer SwiftUI state changes in case a nonanimated completion is synchronous.
            DispatchQueue.main.async { coordinator.onTransitionCompleted?() }
        }
    }

    final class Coordinator {
        var day: Day
        var host: UIHostingController<AnyView>
        var isTransitioning = false
        var onTransitionCompleted: (() -> Void)?

        init(day: Day, content: AnyView) {
            self.day = day
            host = Self.makeHost(content)
        }
        static func makeHost(_ content: AnyView) -> UIHostingController<AnyView> {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .systemBackground
            // The outer navigation view already accounts for safe areas and the date dock.
            host.safeAreaRegions = []
            return host
        }
    }
}
