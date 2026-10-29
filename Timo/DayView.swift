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
    @State private var changingReminder: PlanItem?
    @State private var pickingDate = false
    @AppStorage("timeView") private var showingTimeView = false
    @State private var showingRelativeDate = true
    private enum DayFilter { case all, review, reminders }
    @State private var filter: DayFilter = .all
    private var reviewing: Bool { filter == .review }
    private var showingReminders: Bool { filter == .reminders }
    private var reminderItems: [PlanItem] { visible.filter(hasOpenReminder) }
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
    private func hasOpenReminder(_ item: PlanItem) -> Bool {
        item.reminderAt != nil && !item.isComplete
    }
    private func needsReview(_ item: PlanItem) -> Bool {
        !item.isComplete && !item.suggestionDismissed &&
        item.isElapsed(now: now)
    }
    var body: some View {
        NavigationStack {
            DayPager(day: day,
                     content: AnyView(dayList(for: date, filter: filter).environmentObject(store).tint(.primary)),
                     reduceMotion: reduceMotion)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZStack {
                    HStack {
                        viewModeButton
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
                .padding(.top, 18)
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
                        .accessibilityHint("Toggles unfinished items with a reminder set for this day")
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
            .sheet(item: $changingReminder) { item in
                ReminderTimeEditor(item: item).environmentObject(store)
            }
            .sheet(isPresented: $pickingDate) {
                NavigationStack {
                    DatePicker("Day", selection: Binding(get: { date }, set: { navigate(to: $0) }), displayedComponents: .date).datePickerStyle(.graphical).padding()
                        .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pickingDate = false } } }
                }.presentationDetents([.medium, .large])
            }
            .task(id: date) {
                showingRelativeDate = true
                do {
                    try await Task.sleep(for: .seconds(1.5))
                    try Task.checkCancellation()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        showingRelativeDate = false
                    }
                } catch { /* A new day restarts the label's display time. */ }
            }
            .onChange(of: date) { _, _ in filter = .all; store.showDay(day) }
            .onAppear { store.showDay(day) }
            .onReceive(timer) { refresh($0) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(Date()); store.refreshReminders() } }
        }.tint(.primary)
    }
    private var viewModeButton: some View {
        Button {
            withAnimation(viewModeAnimation) {
                showingTimeView.toggle()
            }
        } label: {
            Image(systemName: showingTimeView ? "list.bullet" : "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass).tint(.primary)
        .accessibilityLabel(showingTimeView ? "Switch to list view" : "Switch to time view")
        .accessibilityValue(showingTimeView ? "Time view" : "List view")
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
            VStack(spacing: 2) {
                Text(date, format: .dateTime.weekday(.wide))
                    .font(.subheadline.weight(.medium))
                Text(date, format: .dateTime.day().month(.abbreviated))
                    .font(.caption).foregroundStyle(.secondary)
            }
                .frame(minWidth: 90, minHeight: 56)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
                        .onEnded { _ in goToToday() }
                )
                .onTapGesture { pickingDate = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Choose a day")
                .accessibilityValue(relativeDateLabel + ", " + date.formatted(date: .complete, time: .omitted))
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
        // Include the rim in the glass content so native interaction transforms
        // deform it together with the capsule, rather than leaving it outside.
        .overlay {
            ZStack {
                if day == Day(now) {
                    TodayDateGlow()
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: day == Day(now))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(alignment: .top) {
            Text(relativeDateLabel)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 8)
                .offset(y: -16)
                .opacity(showingRelativeDate ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        // Observe swipes alongside the date's press gesture. An ancestor's
        // high-priority drag blocks the child's long press while it waits to fail.
        .simultaneousGesture(
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
    private var relativeDateLabel: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selected = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: today, to: selected).day ?? 0
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...7: return "Next " + date.formatted(.dateTime.weekday(.wide))
        case -7 ... -2: return "Last " + date.formatted(.dateTime.weekday(.wide))
        case 8...: return "In \(offset) days"
        default: return "\(-offset) days ago"
        }
    }
    private func navigate(to next: Date) {
        guard Day(next) != day else { setFilter(.all); return }
        withTransaction(Transaction(animation: nil)) {
            filter = .all
            date = next
        }
    }
    private func goToToday() {
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
        let reminderItems = visible.filter(hasOpenReminder)
        let filteredCount = showingReminders ? reminderItems.count : reviewItems.count
        let filterTint = showingReminders ? Color.blue : reviewTint
        let filtered = visible.filter { item in
            switch filter {
            case .all: true
            case .review: needsReview(item)
            case .reminders: hasOpenReminder(item)
            }
        }
        let displayedAnyTime = filtered.filter { $0.minute == nil }
        let displayedTimed = filtered.filter { $0.minute != nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Spacer(minLength: 0)
                        if reviewing {
                            Text("\(reviewItems.count) to review").font(.caption).foregroundStyle(reviewTint)
                        } else if showingReminders {
                            Text("\(reminderItems.count) with reminders").font(.caption).foregroundStyle(.blue)
                        } else if !visible.isEmpty {
                            Text("\(visible.filter(\.isComplete).count)/\(visible.count) complete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if filter != .all {
                        HStack(spacing: 8) {
                            Image(systemName: showingReminders ? "alarm" : "line.3.horizontal.decrease").foregroundStyle(filterTint)
                            Text("\(visible.count - filteredCount) items hidden").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Show all") { setFilter(.all) }.fontWeight(.medium).frame(minHeight: 44)
                        }
                        .font(.caption)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
                if filter != .all && filtered.isEmpty {
                    ContentUnavailableView {
                        Label("All clear", systemImage: "checkmark.circle")
                    } description: {
                        Text(showingReminders
                             ? "There are no unfinished items with reminders for this day. Your other items are still in the full day view."
                             : "There’s nothing left to review for this day. Your other items are still in the full day view.")
                    } actions: {
                        Button("Show full day") { setFilter(.all) }.buttonStyle(.bordered)
                    }.frame(minHeight: 280)
                }
                if filter == .all && visible.isEmpty {
                    ContentUnavailableView {
                        Label("Room for your day", systemImage: "sun.horizon")
                    } description: {
                        Text("Something to do. A little time set aside. Start with what matters today.")
                    } actions: {
                        Button("Add an item", systemImage: "plus") { add() }.buttonStyle(.borderedProminent)
                        if store.items.isEmpty { Button("Try a sample day") { store.addSampleDay(); goToToday() } }
                    }.frame(minHeight: 280)
                }
                if !displayedAnyTime.isEmpty {
                    sectionHeading("Anytime")
                    ForEach(displayedAnyTime) { item in
                        row(item, filter: filter, day: day)
                            .padding(.leading, 12).padding(.trailing, 20)
                            .overlay(alignment: .bottom) {
                                Color.primary.opacity(0.07).frame(height: 0.5)
                                    .padding(.leading, 64).padding(.trailing, 20)
                                    .allowsHitTesting(false)
                            }
                    }
                }
                if !displayedTimed.isEmpty {
                    sectionHeading("Scheduled")
                    scheduledItems(items: displayedTimed, day: day, filter: filter)
                        .padding(.leading, 12).padding(.trailing, 20)
                }
                Text("timo").font(.system(.footnote, design: .rounded).weight(.medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            // One SwiftUI scroll surface resizes continuously with the rows.
            // A UIKit List cell used to resize separately and interrupt the morph.
            .animation(viewModeAnimation, value: showingTimeView)
            .animation(reviewAnimation, value: filter)
            .animation(reviewAnimation, value: filtered.map(\.id))
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
        }
    }
    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
    }
    private func scheduledItems(items: [PlanItem], day: Day, filter: DayFilter) -> some View {
        let calendar = Calendar.current
        let beginning = calendar.startOfDay(for: day.date())
        let end = calendar.date(byAdding: .day, value: 1, to: beginning)!
        let entries = items.compactMap { item -> TimelineEntry? in
            guard let start = item.start() else { return nil }
            func minute(_ date: Date) -> Double {
                if date < beginning { return 0 }
                if date >= end { return 1440 }
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
            return TimelineEntry(id: item.id, minute: minute(start), endMinute: item.end.map(minute), complete: item.isComplete)
        }.sorted { $0.minute < $1.minute }
        let currentMinute: Double? = day == Day(now) ? Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)) : nil
        let firstMinute = min(entries.map(\.minute).min() ?? 360, currentMinute ?? 360)
        let startMinute = min(360, floor(firstMinute / 60) * 60)
        let lanes = TimelineEntry.durationLanes(for: entries)
        let nextItem = items.first { ($0.start() ?? .distantPast) > now }?.id
        let showNow = filter == .all && day == Day(now)
        // Keep both text layouts at fixed endpoint widths. Only their positions
        // and opacity animate, so wrapping never changes in the middle of a frame.
        return DayTimelineLayout(startMinute: startMinute, laneCount: (lanes.values.max() ?? 0) + 1,
                                 progress: showingTimeView ? 1 : 0) {
            ForEach(items) { item in
                if showNow && item.id == nextItem {
                    compactNowMarker
                }
                ForEach([false, true], id: \.self) { timedVariant in
                    row(item, filter: filter, day: day, feedbackEnabled: showingTimeView == timedVariant)
                        .overlay(alignment: .bottom) {
                            if !timedVariant {
                                Color.primary.opacity(0.07)
                                    .frame(height: 0.5).padding(.leading, 52)
                                    .allowsHitTesting(false)
                            }
                        }
                        .opacity(showingTimeView == timedVariant ? 1 : 0)
                        .allowsHitTesting(showingTimeView == timedVariant)
                        .accessibilityHidden(showingTimeView != timedVariant)
                        .layoutValue(key: TimelineTimedVariantKey.self, value: timedVariant)
                        .layoutValue(key: TimelineMinuteKey.self, value: entries.first(where: { $0.id == item.id })?.minute ?? 0)
                        .anchorPreference(key: TimelineRowAnchors.self, value: .bounds) {
                            timedVariant ? [item.id: $0] : [:]
                        }
                }
            }
            if showNow && nextItem == nil { compactNowMarker }
        }
        .backgroundPreferenceValue(TimelineRowAnchors.self) { anchors in
            GeometryReader { geometry in
                TimelineDrawing(entries: entries, startMinute: startMinute, currentMinute: currentMinute,
                                date: beginning, rowFrames: anchors.mapValues { geometry[$0] }, lanes: lanes)
                    .opacity(showingTimeView ? 1 : 0)
            }
        }
        .accessibilityElement(children: .contain)
    }
    private var compactNowMarker: some View {
        nowMarker
            .padding(.horizontal, 8)
            .frame(height: 24)
            .opacity(showingTimeView ? 0 : 1)
            .accessibilityHidden(showingTimeView)
            .layoutValue(key: TimelineMarkerKey.self, value: true)
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
    private func row(_ item: PlanItem, filter: DayFilter, day: Day, feedbackEnabled: Bool = true) -> some View {
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
                    .accessibilityValue([needsReview(item) ? "Needs review" : nil, hasOpenReminder(item) ? "Reminder set" : nil].compactMap { $0 }.joined(separator: ", "))
                    .sensoryFeedback(.success, trigger: item.isComplete) { _, _ in feedbackEnabled }
                Button { editing = item } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            itemTitle(item)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.people.isEmpty || !item.locations.isEmpty {
                                itemDetailsLine(item)
                            }
                            if let from = item.carriedFrom {
                                Text("Carried from \(from.date().formatted(.dateTime.day().month(.abbreviated)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let start = item.start() {
                            scheduleLabel(item, start: start, day: day)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint((needsReview(item) ? "Needs review. " : "") + (hasOpenReminder(item) ? "Reminder set. " : "") + "Open details and edit")
            }
            if reviewing || showingReminders {
                itemStatusPanel(item, filter: filter, day: day)
                    .padding(.leading, 52).padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .padding(.trailing, (!reviewing && needsReview(item) ? 14.0 : 0) + (!showingReminders && hasOpenReminder(item) ? 14.0 : 0))
        .overlay(alignment: .trailing) {
            HStack(spacing: 8) {
                if !reviewing && needsReview(item) {
                    Circle().fill(reviewTint).frame(width: 6, height: 6)
                }
                if !showingReminders && hasOpenReminder(item) {
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
                Text(item.people.joined(separator: ", "))
            }
            if !item.people.isEmpty && !item.locations.isEmpty {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)
            }
            if !item.locations.isEmpty {
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
        let reminder = hasOpenReminder(item)
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
    private var viewModeAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.5)
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
    private func itemStatusPanel(_ item: PlanItem, filter: DayFilter, day: Day) -> some View {
        let reminder = filter == .reminders
        let message: String
        if reminder, let time = item.reminderAt {
            message = time.formatted(date: Day(time) == day ? .omitted : .abbreviated, time: .shortened)
        } else {
            message = item.end != nil ? "This time has ended" : "The scheduled time has passed"
        }
        var actions = [FilteredItemAction(title: "Complete", symbol: "checkmark") {
            withAnimation(self.reviewAnimation) { self.store.toggle(item) }
        }]
        if reminder {
            actions.append(FilteredItemAction(title: "Change time", symbol: "clock.arrow.circlepath") {
                self.changingReminder = item
            })
            actions.append(FilteredItemAction(title: "Remove", symbol: "bell.slash") {
                guard var updated = self.store.item(item.id) else { return }
                updated.reminderAt = nil
                do { try withAnimation(self.reviewAnimation) { try self.store.save(updated) } }
                catch { self.store.errorMessage = error.localizedDescription }
            })
        } else {
            actions.append(FilteredItemAction(title: "Leave open", symbol: "minus") {
                withAnimation(self.reviewAnimation) { self.store.dismissSuggestion(item) }
            })
            actions.append(FilteredItemAction(title: "Reschedule", symbol: "calendar") { self.editing = item })
        }
        return FilteredItemPanel(symbol: reminder ? "alarm" : "exclamationmark.triangle",
                                 message: message, tint: reminder ? .blue : reviewTint,
                                 itemTitle: item.title, actions: actions)
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
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: date) else { return }
        navigate(to: next)
    }
}

private struct FilteredItemAction: Identifiable {
    let title: String
    let symbol: String
    let action: () -> Void
    var id: String { title }
}

// Reminder and warning filters share typography, spacing and action treatment.
private struct FilteredItemPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbol: String
    let message: String
    let tint: Color
    let itemTitle: String
    let actions: [FilteredItemAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                Text(message).font(.caption.monospacedDigit())
            }
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((symbol == "alarm" ? "Reminder: " : "Warning: ") + message)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 0) { actionButtons }
                } else {
                    HStack(spacing: 0) { actionButtons }
                }
            }
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
    }
    @ViewBuilder private var actionButtons: some View {
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            if index > 0 {
                Rectangle().fill(tint.opacity(0.15))
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 0.5,
                           height: dynamicTypeSize.isAccessibilitySize ? 0.5 : 24)
                    .accessibilityHidden(true)
            }
            Button(action: action.action) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label(action.title, systemImage: action.symbol)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: action.symbol).font(.system(size: 16, weight: .medium))
                                .frame(height: 20)
                            Text(action.title).font(.caption.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity)
                    }
                }
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6).padding(.vertical, 10)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title == "Remove" ? "Remove reminder" : action.title): \(itemTitle)")
        }
    }
}

private struct ReminderTimeEditor: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.dismiss) private var dismiss
    let item: PlanItem
    @State private var time: Date
    @State private var issue: String?

    init(item: PlanItem) {
        self.item = item
        _time = State(initialValue: max(item.reminderAt ?? Date(), Date().addingTimeInterval(60)))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Remind me at", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text(item.title).textCase(nil)
                } footer: {
                    if item.seriesID != nil {
                        Text("This updates the reminder time for every occurrence of this repeating item.")
                    }
                }
            }
            .navigationTitle("Reminder time").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
            .alert("Check this reminder", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
        }
        .tint(.blue)
        .presentationDetents([.medium, .large])
    }
    private func save() {
        guard time > Date() else { issue = "Choose a reminder time in the future."; return }
        guard var updated = store.item(item.id) else { dismiss(); return }
        updated.reminderAt = time
        do {
            try store.save(updated)
            if let error = store.errorMessage { issue = error }
            else { dismiss() }
        } catch { issue = error.localizedDescription }
    }
}

// The rim sweeps in once on arrival, then settles into quiet continuous motion.
private struct TodayDateGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { tick in
            let elapsed = max(0, tick.date.timeIntervalSince(appearedAt))
            let entrance = reduceMotion ? 1 : min(elapsed / 1.35, 1)
            let bloom = sin(entrance * .pi)
            let reveal = reduceMotion ? 1 : 1 - pow(1 - min(elapsed / 0.85, 1), 3)
            // Start with a quicker sweep and smoothly slow to the idle orbit.
            let phase = reduceMotion ? 0 : elapsed / 12 + 0.55 * (1 - exp(-elapsed * 3))
            let gradient = AngularGradient(
                colors: [.cyan, .blue, .purple, .pink, .purple, .blue, .cyan],
                center: .center, angle: .degrees(phase * 360))
            ZStack {
                Capsule().trim(from: 0, to: reveal)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 2.5 + bloom * 3, lineCap: .round))
                    .blur(radius: 4 + bloom * 2).opacity(0.22 + bloom * 0.2)
                Capsule().trim(from: 0, to: reveal)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 0.75 + bloom * 0.65, lineCap: .round))
                    .opacity(0.28 + bloom * 0.28)
                Capsule().trim(from: max(0, reveal - 0.2), to: reveal)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .blur(radius: 0.7).opacity((1 - entrance) * 0.65)
            }
            .padding(1)
        }
        .onAppear { appearedAt = Date() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineEntry: Equatable {
    let id: UUID
    let minute: Double
    let endMinute: Double?
    let complete: Bool

    static func durationLanes(for entries: [TimelineEntry]) -> [UUID: Int] {
        let ranges = entries.filter { ($0.endMinute ?? $0.minute) > $0.minute }
        let assignments = TimelineLanes.assign(ranges.map { $0.minute..<$0.endMinute! })
        return Dictionary(uniqueKeysWithValues: zip(ranges.map(\.id), assignments))
    }
}

private struct TimelineMinuteKey: LayoutValueKey {
    static let defaultValue: Double = 0
}

private struct TimelineTimedVariantKey: LayoutValueKey {
    static let defaultValue = false
}

private struct TimelineMarkerKey: LayoutValueKey {
    static let defaultValue = false
}

private struct TimelineRowAnchors: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// Measure the two endpoint layouts once, then only interpolate positions while
// animating. Repeated text measurement during each frame caused uneven movement.
private struct DayTimelineLayout: Layout {
    let startMinute: Double
    let laneCount: Int
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    private var gutter: CGFloat { 76 + CGFloat(max(0, laneCount - 1)) * 6 }
    static let top: CGFloat = 28
    static let pointsPerMinute: CGFloat = 1

    struct Cache {
        var width: CGFloat?
        var start: Double?
        var gutter: CGFloat?
        var compact: [CGRect] = []
        var timed: [CGRect] = []
        var proposals: [ProposedViewSize] = []
        var compactHeight: CGFloat = 0
        var timedHeight: CGFloat = 0
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func prepare(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width || cache.start != startMinute || cache.gutter != gutter || cache.compact.count != subviews.count else { return }
        let timeWidth = max(1, width - gutter)
        var compactBottom: CGFloat = 0
        var timeBottom: CGFloat = -8
        cache.compact = []
        cache.timed = []
        cache.proposals = []
        for index in subviews.indices {
            let subview = subviews[index]
            if subview[TimelineTimedVariantKey.self] {
                // The preceding compact variant already measured both endpoints.
                cache.compact.append(cache.compact[index - 1])
                cache.timed.append(cache.timed[index - 1])
                let frame = cache.timed[index]
                cache.proposals.append(ProposedViewSize(width: frame.width, height: frame.height))
                continue
            }
            let compactHeight = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let marker = subview[TimelineMarkerKey.self]
            let timeHeight = marker ? 0 : subviews[index + 1].sizeThatFits(ProposedViewSize(width: timeWidth, height: nil)).height
            let timeY = Self.top + CGFloat(subview[TimelineMinuteKey.self] - startMinute) * Self.pointsPerMinute
            let timeTop = marker ? max(0, timeBottom) : max(0, max(timeY - timeHeight / 2, timeBottom + 8))
            cache.compact.append(CGRect(x: 0, y: compactBottom, width: width, height: compactHeight))
            cache.timed.append(CGRect(x: gutter, y: timeTop, width: timeWidth, height: timeHeight))
            cache.proposals.append(ProposedViewSize(width: width, height: compactHeight))
            compactBottom += compactHeight
            if !marker { timeBottom = timeTop + timeHeight }
        }
        let axisHeight = Self.top + CGFloat(1440 - startMinute) * Self.pointsPerMinute
        cache.compactHeight = compactBottom
        cache.timedHeight = max(axisHeight, timeBottom) + Self.top
        cache.width = width
        cache.start = startMinute
        cache.gutter = gutter
    }
    private func mix(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        first + (second - first) * CGFloat(min(1, max(0, progress)))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 390
        prepare(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: mix(cache.compactHeight, cache.timedHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        prepare(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            let first = cache.compact[index], second = cache.timed[index]
            let position = CGPoint(x: bounds.minX + mix(first.minX, second.minX),
                                   y: bounds.minY + mix(first.minY, second.minY))
            // A constant proposal lets SwiftUI reuse each row's text layout while
            // this layout interpolates placement and the scroll content height.
            subviews[index].place(at: position, anchor: .topLeading, proposal: cache.proposals[index])
        }
    }
}

private struct TimelineDrawing: View {
    let entries: [TimelineEntry]
    let startMinute: Double
    let currentMinute: Double?
    let date: Date
    let rowFrames: [UUID: CGRect]
    let lanes: [UUID: Int]

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineScale(entries: entries, startMinute: startMinute, currentMinute: currentMinute,
                          date: date, lanes: lanes)
                .equatable()
                .frame(height: DayTimelineLayout.top * 2 + CGFloat(1440 - startMinute) * DayTimelineLayout.pointsPerMinute)
            Canvas { context, _ in
                for entry in entries {
                    guard let frame = rowFrames[entry.id] else { continue }
                    let timeY = DayTimelineLayout.top + CGFloat(entry.minute - startMinute) * DayTimelineLayout.pointsPerMinute
                    let barX = 54 + CGFloat(lanes[entry.id] ?? 0) * 6
                    var connector = Path()
                    connector.move(to: CGPoint(x: barX + 3, y: timeY))
                    connector.addCurve(to: CGPoint(x: frame.minX + 7, y: frame.midY),
                                       control1: CGPoint(x: barX + 12, y: timeY),
                                       control2: CGPoint(x: frame.minX - 4, y: frame.midY))
                    context.stroke(connector, with: .color(.primary.opacity(entry.complete ? 0.12 : 0.3)), lineWidth: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineScale: View, Equatable {
    let entries: [TimelineEntry]
    let startMinute: Double
    let currentMinute: Double?
    let date: Date
    let lanes: [UUID: Int]

    private func y(_ minute: Double) -> CGFloat {
        DayTimelineLayout.top + CGFloat(minute - startMinute) * DayTimelineLayout.pointsPerMinute
    }
    var body: some View {
        Canvas { context, size in
            let axisX: CGFloat = 54
            var axis = Path()
            axis.move(to: CGPoint(x: axisX, y: y(startMinute)))
            axis.addLine(to: CGPoint(x: axisX, y: y(1440)))
            context.stroke(axis, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)

            for hour in Int(startMinute / 60)...24 {
                let position = y(Double(hour * 60))
                var tick = Path()
                tick.move(to: CGPoint(x: axisX - 3, y: position))
                tick.addLine(to: CGPoint(x: axisX + 3, y: position))
                context.stroke(tick, with: .color(.primary.opacity(0.2)), lineWidth: 0.5)
                let hourDate = Calendar.current.date(byAdding: .day, value: hour == 24 ? 1 : 0, to: date)!
                let time = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: hourDate)!
                let label = Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: axisX - 8, y: position), anchor: .trailing)
            }
            for entry in entries {
                let timeY = y(entry.minute)
                let barX = axisX + CGFloat(lanes[entry.id] ?? 0) * 6
                let opacity = entry.complete ? 0.12 : 0.3
                if let end = entry.endMinute, end > entry.minute {
                    var duration = Path()
                    duration.move(to: CGPoint(x: barX, y: timeY))
                    duration.addLine(to: CGPoint(x: barX, y: y(end)))
                    context.stroke(duration, with: .color(.primary.opacity(opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    var endTick = Path()
                    endTick.move(to: CGPoint(x: barX - 3, y: y(end)))
                    endTick.addLine(to: CGPoint(x: barX + 3, y: y(end)))
                    context.stroke(endTick, with: .color(.primary.opacity(opacity)), lineWidth: 1)
                }
                context.fill(Path(ellipseIn: CGRect(x: barX - 2, y: timeY - 2, width: 4, height: 4)),
                             with: .color(.primary.opacity(entry.complete ? 0.2 : 0.55)))
            }
            if let currentMinute, currentMinute >= startMinute {
                let position = y(currentMinute)
                var current = Path()
                current.move(to: CGPoint(x: axisX - 4, y: position))
                current.addLine(to: CGPoint(x: size.width, y: position))
                context.stroke(current, with: .color(.accentColor.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                context.fill(Path(ellipseIn: CGRect(x: axisX - 2.5, y: position - 2.5, width: 5, height: 5)),
                             with: .color(.accentColor))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// An interruptible UIKit transition keeps rapid flicks immediate, without a queue.
private struct DayPager: UIViewControllerRepresentable {
    let day: Day
    let content: AnyView
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator(day: day, content: content) }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.view.clipsToBounds = true
        context.coordinator.install(context.coordinator.host, in: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard day != coordinator.day else {
            coordinator.host.rootView = content
            return
        }
        let direction: CGFloat = day > coordinator.day ? 1 : -1
        // Capture the current visual position before interrupting an earlier slide.
        let outgoing = reduceMotion ? nil : controller.view.snapshotView(afterScreenUpdates: false)
        coordinator.finishTransition()
        let previous = coordinator.host
        previous.willMove(toParent: nil)
        previous.view.removeFromSuperview()
        previous.removeFromParent()

        let next = Coordinator.makeHost(content)
        coordinator.day = day
        coordinator.host = next
        coordinator.install(next, in: controller)
        controller.view.layoutIfNeeded()
        guard let outgoing else { return }
        outgoing.frame = controller.view.bounds
        outgoing.isUserInteractionEnabled = false
        outgoing.accessibilityElementsHidden = true
        controller.view.addSubview(outgoing)
        coordinator.outgoing = outgoing

        let distance = controller.view.bounds.width * direction
        next.view.transform = CGAffineTransform(translationX: distance, y: 0)
        let animator = UIViewPropertyAnimator(duration: 0.18, curve: .easeOut) {
            next.view.transform = .identity
            outgoing.transform = CGAffineTransform(translationX: -distance, y: 0)
        }
        animator.addCompletion { [weak coordinator, weak outgoing] _ in
            outgoing?.removeFromSuperview()
            coordinator?.outgoing = nil
            coordinator?.animator = nil
        }
        coordinator.animator = animator
        animator.startAnimation()
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.finishTransition()
    }

    final class Coordinator {
        var day: Day
        var host: UIHostingController<AnyView>
        var animator: UIViewPropertyAnimator?
        var outgoing: UIView?

        init(day: Day, content: AnyView) {
            self.day = day
            host = Self.makeHost(content)
        }
        func finishTransition() {
            animator?.stopAnimation(true)
            animator = nil
            outgoing?.removeFromSuperview()
            outgoing = nil
            host.view.transform = .identity
        }
        func install(_ host: UIHostingController<AnyView>, in controller: UIViewController) {
            controller.addChild(host)
            host.view.frame = controller.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
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
