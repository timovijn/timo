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
    @StateObject private var daySwipeInteraction = DaySwipeInteraction()
    @State private var changingReminder: PlanItem?
    @State private var pickingDate = false
    @State private var calendarTransitionActive = false
    @Namespace private var calendarTransition
    @ScaledMetric(relativeTo: .subheadline) private var dateLabelWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .caption) private var scheduleColumnWidth: CGFloat = 90
    @AppStorage("timeView") private var showingTimeView = false
    @State private var showingRelativeDate = true
    private enum DayFilter: Int { case all, review, reminders }
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
            GeometryReader { viewport in
                ZStack(alignment: .bottom) {
                    DayPager(day: day,
                             content: pageContent(for: date, filter: filter, insets: viewport.safeAreaInsets),
                             adjacentContent: { adjacentDay in
                                 pageContent(for: adjacentDay.date(), filter: .all, insets: viewport.safeAreaInsets)
                             },
                             revision: DayPageRevision(items: store.items, mode: showingTimeView, filter: filter.rawValue,
                                                       minute: Int(now.timeIntervalSinceReferenceDate / 60), typeSize: dynamicTypeSize,
                                                       insets: viewport.safeAreaInsets, reduceMotion: reduceMotion),
                             reduceMotion: reduceMotion,
                             onSwipe: { move($0) },
                             interaction: daySwipeInteraction)
                        .ignoresSafeArea(.container, edges: .vertical)
                    dayDock
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    filterButtons
                }.sharedBackgroundVisibility(.hidden)
            }
            .sheet(item: $editing) { item in ItemEditor(item: item).environmentObject(store) }
            .sheet(item: $changingReminder) { item in
                ReminderTimeEditor(item: item).environmentObject(store)
            }
            .sheet(isPresented: $pickingDate, onDismiss: { calendarTransitionActive = false }) {
                if reduceMotion {
                    calendarPicker
                } else {
                    calendarPicker
                        .navigationTransition(.zoom(sourceID: "daySelector", in: calendarTransition))
                }
            }
            .task(id: date) {
                guard !calendarTransitionActive else {
                    showingRelativeDate = false
                    return
                }
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
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh(Date()); store.refreshReminders() }
                else { daySwipeInteraction.cancelExternalDrag() }
            }
        }.tint(.primary)
    }
    private func pageContent(for date: Date, filter: DayFilter, insets: EdgeInsets) -> AnyView {
        AnyView(dayList(for: date, filter: filter)
            .contentMargins(.top, insets.top, for: .scrollContent)
            .contentMargins(.bottom, insets.bottom + 94, for: .scrollContent)
            .environmentObject(store).tint(.primary))
    }
    private var dayDock: some View {
        ZStack {
            HStack {
                viewModeButton
                Spacer()
                Button { add() } label: {
                    Image(systemName: "plus").font(.title3.weight(.regular)).foregroundStyle(.primary)
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
    private var calendarPicker: some View {
        DatePicker("Day", selection: Binding(get: { date }, set: { navigate(to: $0) }), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .padding()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
    private var viewModeButton: some View {
        Button {
            withAnimation(viewModeAnimation) {
                showingTimeView.toggle()
            }
        } label: {
            Image(systemName: showingTimeView ? "list.bullet" : "clock")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass).tint(.primary)
        .accessibilityLabel(showingTimeView ? "Switch to list view" : "Switch to time view")
        .accessibilityValue(showingTimeView ? "Time view" : "List view")
    }
    private var dayNavigation: some View {
        HStack(spacing: 0) {
            Button {
                guard daySwipeInteraction.allowsItemActions else { return }
                move(-1)
            } label: {
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
                .frame(width: dateLabelWidth)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
                        .onEnded { _ in
                            if daySwipeInteraction.isExternalDragging {
                                daySwipeInteraction.cancelExternalDrag()
                                return
                            }
                            guard daySwipeInteraction.allowsItemActions else { return }
                            goToToday()
                        }
                )
                .onTapGesture {
                    guard daySwipeInteraction.allowsItemActions else { return }
                    openCalendar()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Choose a day")
                .accessibilityValue(relativeDateLabel + ", " + date.formatted(date: .complete, time: .omitted))
                .accessibilityHint("Tap or swipe up for the calendar, or hold for today")
                .accessibilityAction { openCalendar() }
                .accessibilityAction(named: "Go to today") { goToToday() }
            Button {
                guard daySwipeInteraction.allowsItemActions else { return }
                move(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 44, height: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal, 6)
        .glassEffect(.regular.interactive(!calendarTransitionActive), in: .capsule)
        // Keep the animated halo and relative label outside the zoom source.
        .matchedTransitionSource(id: "daySelector", in: calendarTransition) {
            $0.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        // Put the light behind the finished glass so its halo can spill beyond
        // the capsule instead of being contained by the glass effect.
        .background {
            // Keep one glow alive so reversing a day swipe reverses its fade
            // from the current brightness rather than restarting its entrance.
            TodayDateGlow(isVisible: day == Day(now) && !calendarTransitionActive)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(alignment: .top) {
            Text(relativeDateLabel)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 8)
                .offset(y: -16)
                .opacity(showingRelativeDate && !calendarTransitionActive ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        // Observe swipes alongside the date's press gesture. An ancestor's
        // high-priority drag blocks the child's long press while it waits to fail.
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("dayNavigationDock"))
                .onChanged { swipe in
                    guard !calendarTransitionActive else { return }
                    daySwipeInteraction.updateExternalDrag(horizontal: swipe.translation.width,
                                                          vertical: swipe.translation.height)
                }
                .onEnded { swipe in
                    guard !calendarTransitionActive else { return }
                    if daySwipeInteraction.finishExternalDrag(horizontal: swipe.translation.width,
                                                             projected: swipe.predictedEndTranslation.width) {
                        return
                    }
                    // Release the glass press before the zoom captures its source.
                    if swipe.translation.height < -18,
                       -swipe.translation.height > abs(swipe.translation.width) * 1.35 {
                        openCalendar()
                        return
                    }
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
    private func openCalendar() {
        guard !calendarTransitionActive else { return }
        calendarTransitionActive = true
        pickingDate = true
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
    private var filterButtons: some View {
        let reminderCount = reminderItems.count
        let reviewCount = reviewItems.count
        let showReminders = showingReminders || reminderCount > 0
        let showReview = reviewing || reviewCount > 0
        let transition: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .trailing))
        return HStack(spacing: 10) {
            if showReminders {
                Button { setFilter(showingReminders ? .all : .reminders) } label: {
                    filterIcon("alarm.fill", tint: .blue, count: reminderCount, isActive: showingReminders)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingReminders ? "Show full day" : "Show \(reminderCount) items with reminders")
                .accessibilityValue(showingReminders ? "Reminder filter on" : "Reminder filter off")
                .accessibilityAddTraits(showingReminders ? .isSelected : [])
                .accessibilityHint("Toggles unfinished items with a reminder set for this day")
                .transition(transition)
            }
            if showReview {
                Button { setReviewing(!reviewing) } label: {
                    filterIcon("exclamationmark.triangle.fill", tint: reviewTint, count: reviewCount, isActive: reviewing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reviewing ? "Show full day" : "Review \(reviewCount) items")
                .accessibilityValue(reviewing ? "Review filter on" : "Review filter off")
                .accessibilityAddTraits(reviewing ? .isSelected : [])
                .accessibilityHint("Toggles items needing review for this day")
                .transition(transition)
            }
        }
        // A stable toolbar host lets SwiftUI finish both sides of the transition
        // instead of UIKit immediately inserting/removing separate toolbar items.
        .frame(width: 98, height: 44, alignment: .trailing)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32), value: showReminders)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32), value: showReview)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!showReminders && !showReview)
    }
    private func filterIcon(_ symbol: String, tint: Color, count: Int, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isActive ? tint.opacity(0.85) : Color.primary.opacity(0.42))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.tint(isActive ? tint.opacity(0.22) : .clear).interactive(), in: .circle)
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
        .scrollEdgeEffectHidden(true, for: .vertical)
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
        let showNow = filter == .all && day == Day(now)
        let active = showNow ? items.filter { $0.isInProgress(now: now) } : []
        let activeIDs = Set(active.map(\.id))
        // Compact order puts all current ranges together, including overlapping
        // ranges with an already-ended item between their start times.
        let past = items.filter { !activeIDs.contains($0.id) && ($0.start() ?? .distantPast) <= now }
        let upcoming = items.filter { !activeIDs.contains($0.id) && ($0.start() ?? .distantPast) > now }
        let compactItems = showNow ? past + active + upcoming : items
        let compactOrder = Dictionary(uniqueKeysWithValues: compactItems.enumerated().map { ($0.element.id, $0.offset * 3) })
        let activeTop = active.first.flatMap { compactOrder[$0.id] }.map { $0 - 1 } ?? 0
        // Keep both text layouts at fixed endpoint widths. Only their positions
        // and opacity animate, so wrapping never changes in the middle of a frame.
        let contentKey = TimelineContentKey(items: items, order: compactItems.map(\.id),
                                            markers: items.map { [needsReview($0), hasOpenReminder($0)] },
                                            filter: filter.rawValue, showNow: showNow, typeSize: dynamicTypeSize)
        return DayTimelineLayout(startMinute: startMinute, laneCount: (lanes.values.max() ?? 0) + 1,
                                 contentKey: contentKey, progress: showingTimeView ? 1 : 0) {
            if showNow, let first = past.first {
                let order = (compactOrder[first.id] ?? 0) - 1
                compactSectionDivider("Past")
                    .layoutValue(key: TimelineCompactOrderKey.self, value: order)
                    .accessibilitySortPriority(-Double(order))
            }
            if !active.isEmpty {
                compactSectionDivider("In progress", showTime: true)
                    .layoutValue(key: TimelineCompactOrderKey.self, value: activeTop)
                    .accessibilitySortPriority(-Double(activeTop))
            }
            if showNow, let first = upcoming.first {
                let order = (compactOrder[first.id] ?? 0) - 1
                compactSectionDivider("Upcoming")
                    .layoutValue(key: TimelineCompactOrderKey.self, value: order)
                    .accessibilitySortPriority(-Double(order))
            }
            ForEach(items) { item in
                ForEach([false, true], id: \.self) { timedVariant in
                    row(item, filter: filter, day: day, feedbackEnabled: showingTimeView == timedVariant,
                        sharedSchedule: filter == .all)
                        .opacity(showingTimeView == timedVariant ? 1 : 0)
                        // Both variants share a position, so additive blending keeps
                        // identical pixels fully opaque instead of dipping to 75%
                        // halfway through a normal crossfade.
                        .blendMode(.plusLighter)
                        .allowsHitTesting(showingTimeView == timedVariant)
                        .accessibilityHidden(showingTimeView != timedVariant)
                        .accessibilitySortPriority(showingTimeView || !showNow ? 0 : -Double(compactOrder[item.id] ?? 0))
                        .layoutValue(key: TimelineCompactOrderKey.self, value: compactOrder[item.id] ?? 0)
                        .layoutValue(key: TimelineTimedVariantKey.self, value: timedVariant)
                        .layoutValue(key: TimelineMinuteKey.self, value: entries.first(where: { $0.id == item.id })?.minute ?? 0)
                }
                if filter == .all, let start = item.start() {
                    // Keep one visible time label across both modes. The rows
                    // reserve its measured space but never crossfade its text.
                    scheduleLabel(item, start: start, day: day)
                        .multilineTextAlignment(.trailing)
                        .frame(width: scheduleColumnWidth, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, CGFloat((needsReview(item) ? 14 : 0) + (hasOpenReminder(item) ? 14 : 0)))
                        .overlay(alignment: .trailing) { rowMarkers(item, filter: filter) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .layoutValue(key: TimelineSharedTimeInsetKey.self, value: 0)
                }
                if let entry = entries.first(where: { $0.id == item.id }) {
                    TimelineConnector(complete: entry.complete)
                        .opacity(showingTimeView ? 1 : 0)
                        .layoutValue(key: TimelineConnectorLaneKey.self, value: lanes[item.id] ?? 0)
                        .layoutValue(key: TimelineMinuteKey.self, value: entry.minute)
                }
            }
        }
        // Blend the row variants with each other before compositing over the page.
        .compositingGroup()
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                TimelineScale(entries: entries, startMinute: startMinute, date: beginning, lanes: lanes)
                    .equatable()
                    .frame(height: DayTimelineLayout.top * 2 + CGFloat(1440 - startMinute) * DayTimelineLayout.pointsPerMinute)
                // The minute tick only moves this small marker, never redrawing the tall scale.
                if let currentMinute, currentMinute >= startMinute {
                    TimelineNowMarker()
                        .offset(y: DayTimelineLayout.top + CGFloat(currentMinute - startMinute) * DayTimelineLayout.pointsPerMinute
                                - TimelineNowMarker.height / 2)
                }
            }
            .opacity(showingTimeView ? 1 : 0)
        }
        .animation(reviewAnimation, value: active.map(\.id))
        .accessibilityElement(children: .contain)
    }
    private func compactSectionDivider(_ title: String, showTime: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 0)
            if showTime {
                Text(now, style: .time).monospacedDigit()
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .opacity(showingTimeView ? 0 : 1)
        // Headers travel across rows mid-transition. Leave quickly, and only
        // return once the rows have nearly settled into the list.
        .animation(reduceMotion ? nil : showingTimeView ? .easeOut(duration: 0.12)
                   : .easeIn(duration: 0.18).delay(0.32), value: showingTimeView)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(showingTimeView)
        .allowsHitTesting(false)
        .layoutValue(key: TimelineMarkerKey.self, value: true)
    }
    private func row(_ item: PlanItem, filter: DayFilter, day: Day, feedbackEnabled: Bool = true, sharedSchedule: Bool = false) -> some View {
        let reviewing = filter == .review
        let showingReminders = filter == .reminders
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    guard daySwipeInteraction.allowsItemActions else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item) }
                } label: {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .resizable().scaledToFit().frame(width: 22, height: 22)
                        .foregroundStyle(item.isComplete ? .secondary : .primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(ItemPressStyle())
                    .accessibilityLabel(item.isComplete ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
                    .accessibilityValue([needsReview(item) ? "Needs review" : nil, hasOpenReminder(item) ? "Reminder set" : nil].compactMap { $0 }.joined(separator: ", "))
                    .sensoryFeedback(.success, trigger: item.isComplete) { _, _ in feedbackEnabled }
                Button {
                    guard daySwipeInteraction.allowsItemActions else { return }
                    editing = item
                } label: {
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
                                .frame(width: sharedSchedule ? scheduleColumnWidth : nil, alignment: .trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .opacity(sharedSchedule ? 0 : 1)
                                .accessibilityHidden(sharedSchedule)
                                .layoutPriority(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(ItemPressStyle())
                    .accessibilityValue(sharedSchedule ? item.start().map { timeLabel(item, start: $0, day: day) } ?? "" : "")
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
            // Shared schedules draw the dots beside the shared time label, so
            // they cannot drift apart while the row variants slide.
            if !sharedSchedule { rowMarkers(item, filter: filter) }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.primary.opacity(0.07))
    }
    private func rowMarkers(_ item: PlanItem, filter: DayFilter) -> some View {
        HStack(spacing: 8) {
            if filter != .review && needsReview(item) {
                Circle().fill(reviewTint).frame(width: 6, height: 6)
            }
            if filter != .reminders && hasOpenReminder(item) {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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
                                 itemTitle: item.title, actions: actions.map { action in
            FilteredItemAction(title: action.title, symbol: action.symbol) {
                guard daySwipeInteraction.allowsItemActions else { return }
                action.action()
            }
        })
    }
    private func itemTitle(_ item: PlanItem) -> some View {
        Text(item.title).font(.body.weight(.medium))
            .foregroundStyle(item.isComplete ? .secondary : .primary)
            .strikethrough(item.isComplete, pattern: .solid, color: Color.secondary.opacity(0.45))
    }
    private func scheduleLabel(_ item: PlanItem, start: Date, day: Day) -> some View {
        Text(timeLabel(item, start: start, day: day))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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

// Use the button's native pressed state so scrolling cancels the highlight
// automatically and opening still happens immediately on release.
private struct ItemPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.06 : 0.16),
                       value: configuration.isPressed)
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

// Layer diffuse light around a soft core. Every layer is blurred, so the
// capsule emits a halo rather than displaying a coloured border.
private struct TodayDateGlow: View {
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appearedAt = Date()
    @State private var revealed = false
    @State private var running = true
    private let fadeDuration = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active || !running)) { tick in
            let elapsed = max(0, tick.date.timeIntervalSince(appearedAt))
            let phase = reduceMotion ? 0 : elapsed / 20
            let gradient = AngularGradient(
                colors: [.cyan, .blue, .purple, .pink, .purple, .blue, .cyan],
                center: .center, angle: .degrees(phase * 360))
            ZStack {
                Capsule()
                    .stroke(gradient, lineWidth: 12)
                    .blur(radius: 12).opacity(0.32)
                Capsule()
                    .stroke(gradient, lineWidth: 6)
                    .blur(radius: 5).opacity(0.36)
                Capsule()
                    .stroke(gradient, lineWidth: 2)
                    .blur(radius: 2).opacity(0.38)
            }
            .padding(1)
            .opacity(0.48)
        }
        .opacity(revealed ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: fadeDuration), value: revealed)
        .task(id: isVisible) {
            revealed = isVisible
            if isVisible {
                running = true
            } else {
                // Finish the same fade used on arrival before stopping frames.
                // Returning to today cancels this task and resumes immediately.
                do {
                    if !reduceMotion { try await Task.sleep(for: .seconds(fadeDuration)) }
                    try Task.checkCancellation()
                    running = false
                } catch { /* A reversed fade keeps the current glow alive. */ }
            }
        }
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

private struct TimelineCompactOrderKey: LayoutValueKey {
    static let defaultValue = 0
}

private struct TimelineTimedVariantKey: LayoutValueKey {
    static let defaultValue = false
}

private struct TimelineMarkerKey: LayoutValueKey {
    static let defaultValue = false
}

private struct TimelineSharedTimeInsetKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

private struct TimelineConnectorLaneKey: LayoutValueKey {
    static let defaultValue: Int? = nil
}

// Everything that can change a row's measured size or compact order.
private struct TimelineContentKey: Equatable {
    let items: [PlanItem]
    let order: [UUID]
    let markers: [[Bool]]
    let filter: Int
    let showNow: Bool
    let typeSize: DynamicTypeSize
}

// Measure the two endpoint layouts once, then only interpolate positions while
// animating. Repeated text measurement during each frame caused uneven movement.
private struct DayTimelineLayout: Layout {
    let startMinute: Double
    let laneCount: Int
    let contentKey: TimelineContentKey
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    private var gutter: CGFloat { 76 + CGFloat(max(0, laneCount - 1)) * 6 }
    static let top: CGFloat = 28
    static let pointsPerMinute: CGFloat = 1

    struct Cache {
        var key: TimelineContentKey?
        var width: CGFloat?
        var start: Double?
        var gutter: CGFloat?
        var compact: [CGRect] = []
        var timed: [CGRect] = []
        var proposals: [ProposedViewSize] = []
        var compactHeight: CGFloat = 0
        var timedHeight: CGFloat = 0
    }
    func makeCache(subviews: Subviews) -> Cache { Cache(key: contentKey) }
    // SwiftUI updates the cache on every animation frame as `progress` changes.
    // Only discard measurements when what the rows display has changed.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        guard cache.key != contentKey else { return }
        cache = Cache(key: contentKey)
    }

    private func prepare(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width || cache.start != startMinute || cache.gutter != gutter || cache.compact.count != subviews.count else { return }
        let timeWidth = max(1, width - gutter)
        var compactBottom: CGFloat = 0
        var timeBottom: CGFloat = -8
        var lastTimedRow: CGRect = .zero
        cache.compact = []
        cache.timed = []
        cache.proposals = []
        for index in subviews.indices {
            let subview = subviews[index]
            if let lane = subview[TimelineConnectorLaneKey.self] {
                // The preceding timed row supplies a fixed endpoint. Connector
                // bounds never interpolate, so Canvas does not redraw each frame.
                let row = lastTimedRow
                let x = 54 + CGFloat(lane) * 6 + 3
                let y = Self.top + CGFloat(subview[TimelineMinuteKey.self] - startMinute) * Self.pointsPerMinute
                let frame = CGRect(x: x, y: y, width: max(1, row.minX + 7 - x), height: max(1, row.midY - y + 1))
                cache.compact.append(frame)
                cache.timed.append(frame)
                cache.proposals.append(ProposedViewSize(width: frame.width, height: frame.height))
                continue
            }
            if let trailingInset = subview[TimelineSharedTimeInsetKey.self] {
                let first = cache.compact[index - 1], second = cache.timed[index - 1]
                let size = subview.sizeThatFits(.unspecified)
                func labelFrame(in row: CGRect) -> CGRect {
                    CGRect(x: row.maxX - trailingInset - size.width, y: row.midY - size.height / 2,
                           width: size.width, height: size.height)
                }
                cache.compact.append(labelFrame(in: first))
                cache.timed.append(labelFrame(in: second))
                cache.proposals.append(ProposedViewSize(width: size.width, height: size.height))
                continue
            }
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
            if !marker {
                timeBottom = timeTop + timeHeight
                lastTimedRow = CGRect(x: gutter, y: timeTop, width: timeWidth, height: timeHeight)
            }
        }
        // Timeline positions stay chronological. Only compact placement groups
        // active items; both endpoint text layouts retain their view identities.
        compactBottom = 0
        let compactIndices = subviews.indices.filter {
            !subviews[$0][TimelineTimedVariantKey.self] && subviews[$0][TimelineConnectorLaneKey.self] == nil &&
            subviews[$0][TimelineSharedTimeInsetKey.self] == nil
        }
            .sorted { subviews[$0][TimelineCompactOrderKey.self] < subviews[$1][TimelineCompactOrderKey.self] }
        for index in compactIndices {
            cache.compact[index].origin.y = compactBottom
            if !subviews[index][TimelineMarkerKey.self] {
                cache.compact[index + 1].origin.y = compactBottom
                if index + 2 < subviews.count, subviews[index + 2][TimelineSharedTimeInsetKey.self] != nil {
                    cache.compact[index + 2].origin.y = compactBottom + (cache.compact[index].height - cache.compact[index + 2].height) / 2
                }
            }
            compactBottom += cache.compact[index].height
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

private struct TimelineConnector: View {
    let complete: Bool
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let endY = max(0, size.height - 1)
            var connector = Path()
            connector.move(to: .zero)
            connector.addCurve(to: CGPoint(x: size.width, y: endY),
                               control1: CGPoint(x: 9, y: 0),
                               control2: CGPoint(x: size.width - 11, y: endY))
            context.stroke(connector, with: .color(.primary.opacity(complete ? 0.12 : 0.3)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineScale: View, Equatable {
    let entries: [TimelineEntry]
    let startMinute: Double
    let date: Date
    let lanes: [UUID: Int]

    private func y(_ minute: Double) -> CGFloat {
        DayTimelineLayout.top + CGFloat(minute - startMinute) * DayTimelineLayout.pointsPerMinute
    }
    var body: some View {
        // The full-day scale is tall; rasterise it off the main thread so
        // revealing Time view does not stall the first animation frames.
        Canvas(rendersAsynchronously: true) { context, size in
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
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineNowMarker: View {
    static let height: CGFloat = 5
    var body: some View {
        Canvas { context, size in
            let axisX: CGFloat = 54, middle = size.height / 2
            var current = Path()
            current.move(to: CGPoint(x: axisX - 4, y: middle))
            current.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(current, with: .color(.accentColor.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
            context.fill(Path(ellipseIn: CGRect(x: axisX - 2.5, y: 0, width: 5, height: 5)),
                         with: .color(.accentColor))
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// UIKit and SwiftUI can both recognise the same touch sequence. Keep a
// synchronous gate shared by the pager and all item actions, including the
// release event that SwiftUI may deliver just after the pan ends.
@MainActor
private final class DaySwipeInteraction: ObservableObject {
    private var swiping = false
    private var suppressUntil: TimeInterval = 0
    private var externalDragging = false
    var isPaging = false
    var externalDragChanged: ((CGFloat) -> Void)?
    var externalDragEnded: ((CGFloat, CGFloat, Bool) -> Void)?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    var allowsItemActions: Bool { !swiping && !isPaging && now() >= suppressUntil }
    var isExternalDragging: Bool { externalDragging }
    func begin() { swiping = true }
    func end() {
        guard swiping else { return }
        swiping = false
        suppressUntil = now() + 0.2
    }
    func updateExternalDrag(horizontal: CGFloat, vertical: CGFloat) {
        if !externalDragging {
            guard abs(horizontal) >= 4, abs(horizontal) > abs(vertical) * 1.35 else { return }
            externalDragging = true
            begin()
        }
        externalDragChanged?(horizontal)
    }
    @discardableResult
    func finishExternalDrag(horizontal: CGFloat, projected: CGFloat) -> Bool {
        guard externalDragging else { return false }
        externalDragging = false
        end()
        externalDragEnded?(horizontal, projected, false)
        return true
    }
    func cancelExternalDrag() {
        guard externalDragging else { return }
        externalDragging = false
        end()
        externalDragEnded?(0, 0, true)
    }

}

// Only plan, layout or minute changes update hosted content. Dock/glow/relative
// label updates must not rebuild three pages during a horizontal animation.
private struct DayPageRevision: Equatable {
    let items: [PlanItem]
    let mode: Bool
    let filter: Int
    let minute: Int
    let typeSize: DynamicTypeSize
    let insets: EdgeInsets
    let reduceMotion: Bool
}

// Retain the current page and its neighbours. A swipe only moves existing
// layers; the preview itself becomes the selected page after settling.
private struct DayPager: UIViewControllerRepresentable {
    let day: Day
    let content: AnyView
    let adjacentContent: (Day) -> AnyView
    let revision: DayPageRevision
    let reduceMotion: Bool
    let onSwipe: (Int) -> Void
    let interaction: DaySwipeInteraction

    func makeCoordinator() -> Coordinator {
        Coordinator(day: day, content: content, adjacentContent: adjacentContent,
                    revision: revision, reduceMotion: reduceMotion, onSwipe: onSwipe, interaction: interaction)
    }
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = Controller()
        controller.view.backgroundColor = .systemBackground
        controller.view.clipsToBounds = true
        let coordinator = context.coordinator
        coordinator.container = controller
        coordinator.install(coordinator.host, in: controller)
        controller.onLayout = { [weak coordinator] size in coordinator?.layout(size: size) }
        interaction.externalDragChanged = { [weak coordinator] translation in coordinator?.drag(to: translation) }
        interaction.externalDragEnded = { [weak coordinator] translation, projected, cancelled in
            coordinator?.endDrag(translation: translation, projected: projected, minimumTravel: 6, cancelled: cancelled)
        }
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = coordinator
        pan.delaysTouchesBegan = false
        pan.cancelsTouchesInView = true
        controller.view.addGestureRecognizer(pan)
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSwipe = onSwipe
        coordinator.adjacentContent = adjacentContent
        coordinator.reduceMotion = reduceMotion
        coordinator.requestedDay = day
        coordinator.latestContent = content
        if revision != coordinator.latestRevision { coordinator.previewsDirty = true }
        coordinator.latestRevision = revision
        if day != coordinator.day {
            coordinator.navigate(to: day)
        } else {
            coordinator.refreshIfIdle()
        }
    }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.interaction.cancelExternalDrag()
        coordinator.interaction.externalDragChanged = nil
        coordinator.interaction.externalDragEnded = nil
        coordinator.dispose()
    }
    private final class Controller: UIViewController {
        var onLayout: ((CGSize) -> Void)?
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onLayout?(view.bounds.size)
        }
    }
    final class PageAnimationPolicy {
        var isForeground: Bool
        init(isForeground: Bool) { self.isForeground = isForeground }
    }
    struct PageSurface: View {
        let content: AnyView
        let policy: PageAnimationPolicy
        var body: some View {
            content.transaction { transaction in
                if !policy.isForeground {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
    }
    final class PageHost: UIHostingController<PageSurface> {
        let policy: PageAnimationPolicy
        var content: AnyView {
            get { rootView.content }
            set { rootView = PageSurface(content: newValue, policy: policy) }
        }
        init(content: AnyView, isForeground: Bool) {
            let policy = PageAnimationPolicy(isForeground: isForeground)
            self.policy = policy
            super.init(rootView: PageSurface(content: content, policy: policy))
        }
        required init?(coder: NSCoder) { fatalError("PageHost is created programmatically") }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipe: (Int) -> Void
        let interaction: DaySwipeInteraction
        weak var container: UIViewController?
        var adjacentContent: (Day) -> AnyView
        var reduceMotion: Bool
        var previews: [Int: PageHost] = [:]
        var previewsDirty = false
        var latestRevision: DayPageRevision
        var displayedRevision: DayPageRevision?
        var latestContent: AnyView
        var requestedDay: Day
        var day: Day
        var host: PageHost
        private var animator: UIViewPropertyAnimator?
        private var settlingDirection: Int?
        private var notifyOnSettle = false
        private var warmTask: Task<Void, Never>?
        private var size: CGSize = .zero
        private var dragging = false
        private var dragOrigin: CGFloat = 0
        private var offset: CGFloat = 0

        init(day: Day, content: AnyView, adjacentContent: @escaping (Day) -> AnyView,
             revision: DayPageRevision, reduceMotion: Bool, onSwipe: @escaping (Int) -> Void,
             interaction: DaySwipeInteraction) {
            self.adjacentContent = adjacentContent
            self.reduceMotion = reduceMotion
            self.day = day
            self.requestedDay = day
            self.latestRevision = revision
            self.displayedRevision = revision
            self.latestContent = content
            self.onSwipe = onSwipe
            self.interaction = interaction
            host = Self.makeHost(content)
            super.init()
        }
        func layout(size: CGSize) {
            guard size.width > 0, size.height > 0, self.size != size else { return }
            haltMotion(notify: true)
            self.size = size
            offset = 0
            positionPages()
            scheduleWarm()
        }
        private func positionPages() {
            UIView.performWithoutAnimation {
                host.view.transform = .identity
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.transform = CGAffineTransform(translationX: offset, y: 0)
                for (direction, preview) in previews {
                    preview.view.transform = .identity
                    preview.view.frame = CGRect(x: CGFloat(direction) * size.width, y: 0, width: size.width, height: size.height)
                    preview.view.transform = CGAffineTransform(translationX: offset, y: 0)
                }
            }
        }
        func refreshIfIdle() {
            guard !dragging, animator == nil, requestedDay == day else { return }
            let modeChanged = displayedRevision.map { $0.mode != latestRevision.mode } ?? false
            if displayedRevision != latestRevision {
                host.content = latestContent
                displayedRevision = latestRevision
            }
            if modeChanged {
                warmTask?.cancel()
                warmTask = nil
                scheduleWarm(delay: .milliseconds(600))
            } else {
                scheduleWarm()
            }
        }
        private func scheduleWarm(delay: Duration = .zero) {
            guard warmTask == nil, !dragging, animator == nil, requestedDay == day, size.width > 0 else { return }
            warmTask = Task { [weak self] in
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                } else { await Task.yield() }
                guard !Task.isCancelled, let self else { return }
                self.warmTask = nil
                guard !self.dragging, self.animator == nil, self.requestedDay == self.day else { return }
                self.preparePreviews()
            }
        }
        private func preparePreviews() {
            guard !reduceMotion, let container, size.width > 0,
                  previewsDirty || previews[-1] == nil || previews[1] == nil else { return }
            for direction in [-1, 1] {
                guard let date = Calendar.current.date(byAdding: .day, value: direction, to: day.date()) else { continue }
                let previewDay = Day(date)
                if let preview = previews[direction] {
                    if previewsDirty { preview.content = adjacentContent(previewDay) }
                } else {
                    let preview = Self.makeHost(adjacentContent(previewDay), isForeground: false)
                    install(preview, in: container)
                    preview.view.isUserInteractionEnabled = false
                    preview.view.accessibilityElementsHidden = true
                    previews[direction] = preview
                }
            }
            previewsDirty = false
            positionPages()
            // Warm text/layout before the next gesture instead of forcing it
            // when a finger moves or when the destination is being revealed.
            for preview in previews.values { preview.view.layoutIfNeeded() }
        }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                interaction.begin()
                drag(to: translation.x)
            case .changed:
                drag(to: translation.x)
            case .ended:
                interaction.end()
                let projected = translation.x + gesture.velocity(in: gesture.view).x * 0.16
                endDrag(translation: translation.x, projected: projected,
                        minimumTravel: max(32, size.width * 0.18), cancelled: false)
            case .cancelled, .failed:
                interaction.end()
                endDrag(translation: 0, projected: 0, minimumTravel: 24, cancelled: true)
            default: break
            }
        }
        func drag(to translation: CGFloat) {
            guard size.width > 0 else { return }
            if !dragging {
                warmTask?.cancel()
                warmTask = nil
                haltMotion(notify: true)
                // Usually already warm. This is a fallback for a gesture that
                // arrives before the first idle turn or immediately reverses.
                preparePreviews()
                dragging = true
                dragOrigin = offset
            }
            offset = min(size.width, max(-size.width, dragOrigin + translation))
            guard !reduceMotion else { return }
            setTranslation(offset)
        }
        private func setTranslation(_ translation: CGFloat) {
            let transform = CGAffineTransform(translationX: translation, y: 0)
            host.view.transform = transform
            for preview in previews.values { preview.view.transform = transform }
        }
        func endDrag(translation: CGFloat, projected: CGFloat, minimumTravel: CGFloat, cancelled: Bool) {
            guard dragging else { return }
            dragging = false
            let travel = dragOrigin + translation
            let projection = dragOrigin + projected
            let commit = !cancelled && (abs(travel) >= minimumTravel ||
                (abs(travel) >= 10 && abs(projection) > size.width * 0.2))
            let direction: Int? = commit ? ((abs(travel) >= minimumTravel ? travel : projection) < 0 ? 1 : -1) : nil
            settle(direction: direction, notify: true)
        }
        private func settle(direction: Int?, notify: Bool) {
            warmTask?.cancel()
            warmTask = nil
            settlingDirection = direction
            notifyOnSettle = notify
            interaction.isPaging = true
            let target = direction.map { -CGFloat($0) * size.width } ?? 0
            if reduceMotion {
                offset = target
                completeSettle()
                return
            }
            let animation = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 1) {
                self.setTranslation(target)
            }
            animation.addCompletion { [weak self] position in
                guard position == .end else { return }
                self?.offset = target
                self?.completeSettle()
            }
            animator = animation
            animation.startAnimation()
        }
        private func completeSettle() {
            animator = nil
            let direction = settlingDirection
            let notify = notifyOnSettle
            settlingDirection = nil
            notifyOnSettle = false
            if let direction { promote(direction: direction, preserving: 0) }
            else { offset = 0; setTranslation(0) }
            interaction.isPaging = false
            if let direction, notify { onSwipe(direction) }
            refreshIfIdle()
        }
        private func promote(direction: Int, preserving translation: CGFloat) {
            guard let next = previews.removeValue(forKey: direction),
                  let date = Calendar.current.date(byAdding: .day, value: direction, to: day.date()) else { return }
            if let distant = previews.removeValue(forKey: -direction) { remove(distant) }
            let previous = host
            previous.policy.isForeground = false
            previous.view.isUserInteractionEnabled = false
            previous.view.accessibilityElementsHidden = true
            previews[-direction] = previous
            host = next
            host.policy.isForeground = true
            host.view.isUserInteractionEnabled = true
            host.view.accessibilityElementsHidden = false
            day = Day(date)
            displayedRevision = nil
            offset = translation
            positionPages()
        }
        private func haltMotion(notify: Bool) {
            guard let animator else { return }
            let visibleOffset = host.view.layer.presentation()?.affineTransform().tx ?? host.view.transform.tx
            animator.stopAnimation(true)
            self.animator = nil
            let direction = settlingDirection
            let shouldNotify = notify && notifyOnSettle
            settlingDirection = nil
            notifyOnSettle = false
            if let direction {
                promote(direction: direction, preserving: visibleOffset + CGFloat(direction) * size.width)
                if shouldNotify { onSwipe(direction) }
            } else {
                offset = visibleOffset
                setTranslation(visibleOffset)
            }
            interaction.isPaging = false
        }
        func navigate(to selected: Day) {
            // Repeated SwiftUI updates must not interrupt an animation already
            // settling towards the requested date.
            if let direction = settlingDirection,
               let target = Calendar.current.date(byAdding: .day, value: direction, to: day.date()),
               Day(target) == selected { return }
            haltMotion(notify: false)
            dragging = false
            guard selected != day else { refreshIfIdle(); return }
            let delta = Calendar.current.dateComponents([.day], from: day.date(), to: selected.date()).day ?? 0
            if abs(delta) == 1, !reduceMotion {
                preparePreviews()
                // The source page is kept intact and the cached neighbour is
                // used directly, including its existing scroll/text layout.
                settle(direction: delta, notify: false)
            } else {
                for preview in previews.values { remove(preview) }
                previews.removeAll()
                remove(host)
                host = Self.makeHost(latestContent)
                if let container { install(host, in: container) }
                day = selected
                displayedRevision = latestRevision
                offset = 0
                positionPages()
                refreshIfIdle()
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.35
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func dispose() {
            warmTask?.cancel()
            warmTask = nil
            animator?.stopAnimation(true)
            animator = nil
            interaction.isPaging = false
            for preview in previews.values { remove(preview) }
            previews.removeAll()
        }
        private func remove(_ controller: PageHost) {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        func install(_ host: PageHost, in controller: UIViewController) {
            controller.addChild(host)
            host.view.frame = controller.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
        }
        static func makeHost(_ content: AnyView, isForeground: Bool = true) -> PageHost {
            let host = PageHost(content: content, isForeground: isForeground)
            host.view.backgroundColor = .systemBackground
            host.safeAreaRegions = []
            return host
        }
    }
}
