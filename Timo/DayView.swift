import SwiftUI
import Combine
import UIKit
import CoreImage

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
    /// The calendar's size, which the glass it sits on grows to.
    @State private var calendarSize = CGSize(width: 360, height: 340)
    @ScaledMetric(relativeTo: .subheadline) private var dateLabelWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .caption) private var scheduleColumnWidth: CGFloat = 90
    // Only the views that move or fade read the mode, so switching never
    // rebuilds DayView or the day's content.
    @State private var viewMode = ViewMode(persisted: true)
    // Neighbouring pages follow after the animation instead of during it.
    @State private var previewMode = ViewMode(persisted: false)
    @State private var showingRelativeDate = true
    private enum DayFilter: Int { case all, review, reminders }
    @State private var filter: DayFilter = .all
    /// The persona shown in the top left. All keeps the day view; a persona swaps in its history.
    @State private var persona: Persona?
    private var reviewing: Bool { filter == .review }
    private var showingReminders: Bool { filter == .reminders }
    private var reminderItems: [PlanItem] { visible.filter(hasOpenReminder) }
    @State private var now = Date()
    @State private var lastToday = Day(Date())
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var day: Day { Day(date) }
    private var visible: [PlanItem] {
        store.items.filter { $0.shows(on: day, now: now) }.sorted {
            if $0.minute != $1.minute { return ($0.minute ?? -1) < ($1.minute ?? -1) }
            return $0.createdAt < $1.createdAt
        }
    }
    private var reviewItems: [PlanItem] {
        visible.filter(needsReview)
    }
    private func hasOpenReminder(_ item: PlanItem) -> Bool {
        !item.isComplete && item.reminders.contains { $0 > now }
    }
    private func needsReview(_ item: PlanItem) -> Bool {
        // A carried item is already late and shown as untimed, so its old time isn't flagged.
        !item.isComplete && !item.suggestionDismissed && !item.isCarried(now: now) &&
        item.isElapsed(now: now)
    }
    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ZStack(alignment: .bottom) {
                    DayPager(day: day,
                             content: pageContent(for: date, filter: filter, mode: viewMode, insets: viewport.safeAreaInsets),
                             adjacentContent: { adjacentDay in
                                 pageContent(for: adjacentDay.date(), filter: .all, mode: previewMode, insets: viewport.safeAreaInsets)
                             },
                             revision: DayPageRevision(items: store.items, filter: filter.rawValue,
                                                       minute: Int(now.timeIntervalSinceReferenceDate / 60), typeSize: dynamicTypeSize,
                                                       insets: viewport.safeAreaInsets, reduceMotion: reduceMotion),
                             reduceMotion: reduceMotion,
                             onSwipe: { move($0) },
                             interaction: daySwipeInteraction)
                        .ignoresSafeArea(.container, edges: .vertical)
                    if pickingDate {
                        // Tapping anywhere outside the calendar closes it.
                        Color.black.opacity(0.08)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { closeCalendar() }
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                    dayDock
                }
                // The day view stays alive underneath, so returning to All is instant.
                .opacity(persona == nil ? 1 : 0)
                .allowsHitTesting(persona == nil)
                .accessibilityHidden(persona != nil)
                .overlay {
                    ZStack(alignment: .bottomTrailing) {
                        PersonaPages(persona: persona, now: now, open: { editing = $0 }, add: add)
                            .contentMargins(.bottom, 94, for: .scrollContent)
                        if persona != nil {
                            // Sits where the day dock's add button does, and stays put as pages slide.
                            addButton
                                .frame(height: 72)
                                .padding(.horizontal, 20).padding(.bottom, 4)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PersonaSwitcher(selection: $persona)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The filters belong to a single day, so they rest while a persona is shown.
                    filterButtons
                        .opacity(persona == nil ? 1 : 0)
                        .allowsHitTesting(persona == nil)
                        .accessibilityHidden(persona != nil)
                }.sharedBackgroundVisibility(.hidden)
            }
            .sheet(item: $editing) { item in ItemEditor(item: item).environmentObject(store) }
            .sheet(item: $changingReminder) { item in
                ReminderTimeEditor(item: item).environmentObject(store)
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
    private func pageContent(for date: Date, filter: DayFilter, mode: ViewMode, insets: EdgeInsets) -> AnyView {
        AnyView(dayList(for: date, filter: filter)
            .contentMargins(.top, insets.top, for: .scrollContent)
            .contentMargins(.bottom, insets.bottom + 94, for: .scrollContent)
            .environment(mode)
            .environmentObject(store).tint(.primary))
    }
    private var dayDock: some View {
        ZStack {
            HStack {
                ViewModeButton(mode: viewMode, previewMode: previewMode)
                Spacer()
                addButton
            }
            .padding(.horizontal, 20)
            // The calendar spans the dock, so its neighbours step aside while it is open.
            .opacity(pickingDate ? 0 : 1)
            .allowsHitTesting(!pickingDate)
            .accessibilityHidden(pickingDate)
            // Only the day capsule and the calendar share this container, so the capsule can
            // stretch into the calendar and back as one piece of glass.
            GlassEffectContainer {
                ZStack {
                    if !pickingDate { dayNavigation }
                }
                .frame(maxWidth: .infinity).frame(height: 72)
                .overlay(alignment: .bottom) {
                    // Bottom-aligned with the capsule, so the calendar grows up out of it.
                    if pickingDate {
                        Color.clear
                            .frame(width: calendarSize.width, height: calendarSize.height)
                            .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
                            .glassEffectID("day", in: calendarTransition)
                            .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
                            .padding(.bottom, 8)
                    }
                }
            }
            // Outside the glass container, which would draw its glass over it.
            .overlay(alignment: .bottom) {
                calendarCard.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 72)
        .coordinateSpace(name: "dayNavigationDock")
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
    private var addButton: some View {
        Button { add() } label: {
            Image(systemName: "plus").font(.title3.weight(.regular)).foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // A circle as tall as the date capsule, rather than the glass style's wider capsule.
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(persona.map { "Add \($0.title) item" } ?? "Add item")
    }
    /// The calendar, on the same glass as the day capsule it opens from. Choosing a day,
    /// tapping outside or pulling it down folds it back into the capsule.
    ///
    /// The calendar itself stays built while hidden: creating it took long enough on device to
    /// stall the opening frames. Only a plain glass shape behind it morphs, which stays cheap,
    /// and the calendar fades in on top as the glass grows.
    private var calendarCard: some View {
        DatePicker("Day", selection: Binding(get: { date }, set: { picked in
            navigate(to: picked)
            // Leave the new selection visible for a moment before folding away.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                closeCalendar()
            }
        }), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 380)
            .onGeometryChange(for: CGSize.self, of: \.size) { calendarSize = $0 }
            // Grows from the capsule with the glass, so the days never hang outside it.
            .scaleEffect(pickingDate || reduceMotion ? 1 : 0.4, anchor: .bottom)
            .animation(calendarAnimation, value: pickingDate)
            .opacity(pickingDate ? 1 : 0)
            // In once the glass has started to grow; out quickly, before it folds away.
            .animation(pickingDate ? .easeOut(duration: 0.2).delay(0.12) : .easeIn(duration: 0.1), value: pickingDate)
            .allowsHitTesting(pickingDate)
            .accessibilityHidden(!pickingDate)
            .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
                if drag.translation.height > 50 { closeCalendar() }
            }, isEnabled: pickingDate)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { closeCalendar() }
    }
    private var calendarAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)
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
        // A fixed radius, the capsule's own at this height: a capsule shape would keep its
        // ends fully round while growing, swelling the glass into a circle on the way.
        .glassEffect(.regular.interactive(!calendarTransitionActive), in: .rect(cornerRadius: 28, style: .continuous))
        // The same glass as the calendar card, so one stretches into the other.
        .glassEffectID("day", in: calendarTransition)
        .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
        // Put the light behind the finished glass so its halo can spill beyond
        // the capsule instead of being contained by the glass effect.
        .background {
            // Keep one glow alive so reversing a day swipe reverses its fade
            // from the current brightness rather than restarting its entrance.
            TodayDateGlow(isVisible: day == Day(now) && !calendarTransitionActive)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(alignment: .top) {
            if showingRelativeDate && !calendarTransitionActive {
                Text(relativeDateLabel)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    // A small glass pill keeps the label readable over the list behind it. Glass
                    // ignores opacity, so the pill is added and removed and fades as glass does.
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectTransition(.materialize)
                    .offset(y: -22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
        // Run the morph at the display's full rate rather than SwiftUI's default 60 Hz.
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(800)) }
        withAnimation(calendarAnimation) {
            calendarTransitionActive = true
            pickingDate = true
        }
    }
    private func closeCalendar() {
        guard pickingDate else { return }
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(800)) }
        withAnimation(calendarAnimation) {
            pickingDate = false
            calendarTransitionActive = false
        }
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
        // The button already names the weekday, so the label only says which one.
        case 2...7: return "Next"
        case -7 ... -2: return "Last"
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
        let visible = store.items.filter { $0.shows(on: day, now: now) }.sorted {
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
        // A carried item keeps its old time on its scheduled day; here it is untimed.
        let displayedAnyTime = filtered.filter { $0.minute == nil || $0.isCarried(now: now) }
        let displayedTimed = filtered.filter { $0.minute != nil && !$0.isCarried(now: now) }
        // Items carried on from this day stay as quiet entries, outside the
        // counts and filters: they are counted and reviewed on their live day.
        let moved = filter == .all ? Planner.movedItems(from: day, in: store.items, now: now) : []
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
                if filter == .all && visible.isEmpty && moved.isEmpty {
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
                if !moved.isEmpty {
                    // No heading: each entry's "Carried to" line says what it is.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(moved) { item in
                            movedRow(item, day: day)
                                .padding(.leading, 12).padding(.trailing, 20)
                        }
                    }
                    .padding(.top, visible.isEmpty ? 0 : 16)
                }
                Text("timo").font(.system(.footnote, design: .rounded).weight(.medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            // One SwiftUI scroll surface resizes continuously with the rows.
            // A UIKit List cell used to resize separately and interrupt the morph.
            // The view-mode animation lives on the mode-reading views below.
            .animation(reviewAnimation, value: filter)
            .animation(reviewAnimation, value: filtered.map(\.id))
            .transaction { transaction in
                if reduceMotion && !ViewMode.crossFades(reduceMotion: true) { transaction.animation = nil }
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
        return ModeTimelineLayout(startMinute: startMinute, laneCount: (lanes.values.max() ?? 0) + 1,
                                  contentKey: contentKey) {
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
                    row(item, filter: filter, day: day, feedbackEnabled: false, sharedSchedule: filter == .all)
                        .modifier(ModeRowVariant(isTimed: timedVariant, isComplete: item.isComplete,
                                                 compactSortPriority: showNow ? -Double(compactOrder[item.id] ?? 0) : 0))
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
                        .modifier(ModeFade(visibleInTimeView: true))
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
            .modifier(ModeFade(visibleInTimeView: true))
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .modifier(ModeSectionHeaderFade())
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
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item, on: day) }
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
                            if item.isCarried(now: now) {
                                Text("Carried from \(item.day.date().formatted(.dateTime.day().month(.abbreviated)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let start = item.start(), !item.isCarried(now: now) {
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
        .deletableOnHold(item, isEnabled: { daySwipeInteraction.allowsItemActions })
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.primary.opacity(0.07))
    }
    // An item carried on from an earlier day. It is the same item as on its live
    // day, so completing or opening it here acts on that copy.
    private func movedRow(_ item: PlanItem, day: Day) -> some View {
        let live = item.liveDay(now: now)
        let destination = live == Day(now) ? "today"
            : live.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return HStack(alignment: .center, spacing: 8) {
            Button {
                guard daySwipeInteraction.allowsItemActions else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item, on: day) }
            } label: {
                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(ItemPressStyle())
                .accessibilityLabel(item.isComplete ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
                .accessibilityValue("Carried to \(destination)")
            Button {
                guard daySwipeInteraction.allowsItemActions else { return }
                editing = item
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.body)
                        .foregroundStyle(.secondary)
                        .strikethrough(item.isComplete, pattern: .solid, color: Color.secondary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Carried to \(destination)", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 2).contentShape(Rectangle())
            }.buttonStyle(ItemPressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityValue("Carried to \(destination)" + (item.isComplete ? ", completed" : ""))
                .accessibilityHint("Open details and edit")
        }
        .deletableOnHold(item, isEnabled: { daySwipeInteraction.allowsItemActions })
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
        if reminder, let time = item.displayedReminder(now: now) {
            message = time.formatted(date: Day(time) == day ? .omitted : .abbreviated, time: .shortened)
                + (item.reminders.count > 1 ? " · \(item.reminders.count) reminders" : "")
        } else {
            message = item.end != nil ? "This time has ended" : "The scheduled time has passed"
        }
        var actions = [FilteredItemAction(title: "Complete", symbol: "checkmark") {
            withAnimation(self.reviewAnimation) { self.store.toggle(item, on: day) }
        }]
        if reminder {
            actions.append(FilteredItemAction(title: "Change time", symbol: "clock.arrow.circlepath") {
                self.changingReminder = item
            })
            actions.append(FilteredItemAction(title: "Remove", symbol: "bell.slash") {
                // Remove the reminder shown in the panel; any others stay.
                guard var updated = self.store.item(item.id), let shown = updated.displayedReminder(now: Date()) else { return }
                updated.reminders.removeAll { $0 == shown }
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
    private func add() {
        // From a persona's history, a new item starts today in that persona.
        var item = PlanItem(title: "", day: persona == nil ? day : Day(now))
        item.persona = persona
        editing = item
    }
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

// List/Time view state, observed only by the views that move or fade with it.
@Observable
private final class ViewMode {
    private static let key = "timeView"
    @ObservationIgnored private let persisted: Bool
    var showingTime: Bool {
        didSet { if persisted { UserDefaults.standard.set(showingTime, forKey: Self.key) } }
    }
    init(persisted: Bool) {
        self.persisted = persisted
        showingTime = UserDefaults.standard.bool(forKey: Self.key)
    }
    // Prefer Cross-Fade Transitions is a Reduce Motion option: with it, layout
    // changes dissolve; with Reduce Motion alone, they apply immediately.
    static func crossFades(reduceMotion: Bool) -> Bool {
        reduceMotion && UIAccessibility.prefersCrossFadeTransitions
    }
    static func animation(reduceMotion: Bool) -> Animation? {
        if crossFades(reduceMotion: reduceMotion) { return .easeInOut(duration: 0.3) }
        return reduceMotion ? nil : .smooth(duration: 0.5)
    }
}

private struct ViewModeButton: View {
    let mode: ViewMode
    let previewMode: ViewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewSync: Task<Void, Never>?

    var body: some View {
        Button {
            if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
            withAnimation(ViewMode.animation(reduceMotion: reduceMotion)) { mode.showingTime.toggle() }
            // Neighbouring pages update once the switch has finished animating.
            previewSync?.cancel()
            previewSync = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                previewMode.showingTime = mode.showingTime
            }
        } label: {
            Image(systemName: mode.showingTime ? "list.bullet" : "clock")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // A circle as tall as the date capsule, rather than the glass style's wider capsule.
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(mode.showingTime ? "Switch to list view" : "Switch to time view")
        .accessibilityValue(mode.showingTime ? "Time view" : "List view")
    }
}

// SwiftUI animations otherwise stay at 60 Hz on ProMotion iPhones. An active
// display link asking for 120 Hz raises the app's frame rate while it runs.
@MainActor
private final class FrameRateBoost: NSObject {
    static let shared = FrameRateBoost()
    private var link: CADisplayLink?
    private var expiry: Task<Void, Never>?

    func request(for duration: Duration) {
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.link?.invalidate()
            self?.link = nil
        }
    }
    @objc private func tick() {}
}

private struct ModeTimelineLayout<Content: View>: View {
    let startMinute: Double
    let laneCount: Int
    let contentKey: TimelineContentKey
    @ViewBuilder let content: Content
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = DayTimelineLayout(startMinute: startMinute, laneCount: laneCount, contentKey: contentKey,
                                       progress: mode.showingTime ? 1 : 0) { content }
        if ViewMode.crossFades(reduceMotion: reduceMotion) {
            // Dissolve between the finished layouts instead of moving rows.
            ZStack { layout.id(mode.showingTime).transition(.opacity) }
                .animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
        } else {
            layout.animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
        }
    }
}

private struct ModeRowVariant: ViewModifier {
    let isTimed: Bool
    let isComplete: Bool
    let compactSortPriority: Double
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let active = mode.showingTime == isTimed
        content
            .sensoryFeedback(.success, trigger: isComplete) { _, _ in active }
            .opacity(active ? 1 : 0)
            // Both variants share a position, so additive blending keeps
            // identical pixels fully opaque instead of dipping to 75%
            // halfway through a normal crossfade.
            .blendMode(.plusLighter)
            .animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .accessibilitySortPriority(mode.showingTime ? 0 : compactSortPriority)
    }
}

private struct ModeFade: ViewModifier {
    let visibleInTimeView: Bool
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(mode.showingTime == visibleInTimeView ? 1 : 0)
            .animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
    }
}

// Headers travel across rows mid-transition. Leave quickly, and only
// return once the rows have nearly settled into the list.
private struct ModeSectionHeaderFade: ViewModifier {
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(mode.showingTime ? 0 : 1)
            .animation(reduceMotion ? ViewMode.animation(reduceMotion: true)
                       : mode.showingTime ? .easeOut(duration: 0.12) : .easeIn(duration: 0.18).delay(0.32),
                       value: mode.showingTime)
            .accessibilityHidden(mode.showingTime)
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
        _time = State(initialValue: max(item.displayedReminder(now: Date()) ?? Date(), Date().addingTimeInterval(60)))
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
        // Change the reminder this sheet opened with, keeping any others.
        if let shown = updated.displayedReminder(now: Date()), let index = updated.reminders.firstIndex(of: shown) {
            updated.reminders[index] = time
        } else {
            updated.reminders.append(time)
        }
        updated.reminders.sort()
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
    @State private var revealed = false
    private let fadeDuration = 1.6

    var body: some View {
        // A still halo: it only fades in and out with today.
        GlowRing()
            .opacity(0.48)
            .opacity(revealed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: fadeDuration), value: revealed)
            .onChange(of: isVisible, initial: true) { _, visible in revealed = visible }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct GlowRing: UIViewRepresentable {
    func makeUIView(context: Context) -> GlowRingView { GlowRingView() }
    func updateUIView(_ view: GlowRingView, context: Context) {}
}

// A conic gradient beneath a fixed mask of the three blurred capsule strokes.
// The mask is drawn once per size, so the halo costs no frames once shown.
private final class GlowRingView: UIView {
    private static let spill: CGFloat = 40
    private static let imageContext = CIContext()
    private static let colors: [Color] = [.cyan, .blue, .purple, .pink, .purple, .blue, .cyan]
    // Line width, blur radius and opacity of each stroke, outermost first.
    private static let strokes: [(width: CGFloat, blur: CGFloat, opacity: CGFloat)] = [(12, 12, 0.32), (6, 5, 0.36), (2, 2, 0.38)]
    private let container = CALayer()
    private let gradient = CAGradientLayer()
    private let ringMask = CALayer()
    private var maskSize: CGSize?
    private var maskScale: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        container.addSublayer(gradient)
        container.mask = ringMask
        layer.addSublayer(container)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: GlowRingView, _) in
            view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("GlowRingView is created programmatically") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let frame = bounds.insetBy(dx: -Self.spill, dy: -Self.spill)
        let side = hypot(frame.width, frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = frame
        ringMask.frame = container.bounds
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        gradient.colors = Self.colors.map { UIColor($0).resolvedColor(with: traitCollection).cgColor }
        let scale = traitCollection.displayScale
        if maskSize != bounds.size || maskScale != scale {
            ringMask.contents = Self.ringImage(size: bounds.size, scale: scale)
            ringMask.contentsScale = scale
            maskSize = bounds.size
            maskScale = scale
        }
        CATransaction.commit()
    }
    private static func ringImage(size: CGSize, scale: CGFloat) -> CGImage? {
        let canvas = CGSize(width: size.width + spill * 2, height: size.height + spill * 2)
        let rect = CGRect(x: spill, y: spill, width: size.width, height: size.height).insetBy(dx: 1, dy: 1)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        var combined: CIImage?
        for stroke in strokes {
            let sharp = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                UIColor(white: 1, alpha: stroke.opacity).setStroke()
                path.lineWidth = stroke.width
                path.stroke()
            }
            guard let image = CIImage(image: sharp) else { continue }
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double(stroke.blur * scale))
                .cropped(to: image.extent)
            combined = combined.map { blurred.composited(over: $0) } ?? blurred
        }
        guard let combined else { return nil }
        return imageContext.createCGImage(combined, from: combined.extent)
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
            if displayedRevision != latestRevision {
                host.content = latestContent
                displayedRevision = latestRevision
            }
            scheduleWarm()
        }
        private func scheduleWarm() {
            guard warmTask == nil, !dragging, animator == nil, requestedDay == day, size.width > 0 else { return }
            warmTask = Task { [weak self] in
                await Task.yield()
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
                if ViewMode.crossFades(reduceMotion: true), let view = container?.view {
                    UIView.transition(with: view, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction],
                                      animations: completeSettle)
                } else {
                    completeSettle()
                }
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
            // The promoted page still carries the preview mode and the demoted
            // page the live one; both get their proper content when idle.
            previewsDirty = true
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
            let crossFade = ViewMode.crossFades(reduceMotion: reduceMotion)
            if abs(delta) == 1, !reduceMotion {
                preparePreviews()
                // The source page is kept intact and the cached neighbour is
                // used directly, including its existing scroll/text layout.
                settle(direction: delta, notify: false)
            } else {
                let replace = {
                    for preview in self.previews.values { self.remove(preview) }
                    self.previews.removeAll()
                    self.remove(self.host)
                    self.host = Self.makeHost(self.latestContent)
                    if let container = self.container { self.install(self.host, in: container) }
                    self.day = selected
                    self.displayedRevision = self.latestRevision
                    self.offset = 0
                    self.positionPages()
                    self.refreshIfIdle()
                }
                if crossFade, let view = container?.view {
                    UIView.transition(with: view, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction],
                                      animations: replace)
                } else {
                    replace()
                }
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
