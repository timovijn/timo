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
    /// The calendar's size, which the glass it sits on grows to.
    @State private var calendarSize = CGSize(width: 360, height: 340)
    /// The day capsule's own size, which the glass folds back to.
    @State private var capsuleSize = CGSize(width: 222, height: 56)
    @State private var dockWidth: CGFloat = 402
    @ScaledMetric(relativeTo: .subheadline) private var dateLabelWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .caption) private var scheduleColumnWidth: CGFloat = 90
    // Only the views that move or fade read the mode, so switching never
    // rebuilds DayView or the day's content.
    @State private var viewMode = ViewMode(persisted: true)
    // Neighbouring pages follow after the animation instead of during it.
    @State private var previewMode = ViewMode(persisted: false)
    @State private var showingRelativeDate = true
    @GestureState private var pressingDate = false
    private enum DayFilter: Int { case all, review, reminders, deadlines }
    @State private var filter: DayFilter = .all
    @State private var filterTransition = 0
    /// Which filter the rows' status panels show. It outlasts the filter, so a panel keeps its
    /// content while it collapses back into its row.
    @State private var panelFilter: DayFilter = .review
    /// The persona shown in the top left. All keeps the day view; a persona swaps in its history.
    @State private var persona: Persona?
    private var reviewing: Bool { filter == .review }
    private var showingReminders: Bool { filter == .reminders }
    private var showingDeadlines: Bool { filter == .deadlines }
    private var reminderItems: [PlanItem] { (visible + moved).filter { matches($0, .reminders, on: day) } }
    private var deadlineItems: [PlanItem] { (visible + moved).filter { matches($0, .deadlines, on: day) } }
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
    /// How many rows the active filter keeps; nil in the full day.
    private var activeFilterCount: Int? {
        switch filter {
        case .all: nil
        case .review: reviewItems.count
        case .reminders: reminderItems.count
        case .deadlines: deadlineItems.count
        }
    }
    /// Items carried on from the viewed day, shown there as "Carried to" entries.
    private var moved: [PlanItem] { Planner.movedItems(from: day, in: store.items, now: now) }
    private var reviewItems: [PlanItem] {
        (visible + moved).filter { matches($0, .review, on: day) }
    }
    /// Whether the row for `item` on `day` has the filter's dot, and so is in that filter. A
    /// "Carried to" entry keeps its orange dot until the item is done or left open; it gets no
    /// reminder dot, as reminders are about its live day.
    private func matches(_ item: PlanItem, _ filter: DayFilter, on day: Day) -> Bool {
        let carried = item.movedAway(from: day, now: now)
        switch filter {
        case .all: return true
        case .review: return carried ? !item.isSettled && !item.suggestionDismissed : needsReview(item)
        case .reminders: return !carried && hasOpenReminder(item)
        case .deadlines: return item.hasOpenDeadline
        }
    }
    private func hasOpenReminder(_ item: PlanItem) -> Bool {
        !item.isSettled && item.reminders.contains { $0 > now }
    }
    private func needsReview(_ item: PlanItem) -> Bool {
        // A carried item is already late and shown as untimed, so its old time isn't flagged.
        !item.isSettled && !item.suggestionDismissed && !item.isCarried(now: now) &&
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
                             revision: DayPageRevision(items: store.items, filter: filter.rawValue, panelFilter: panelFilter.rawValue,
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
                        PersonaPages(persona: persona, now: now, add: add) { AnyView(row($0, filter: .all, day: $1)) }
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
                .overlay(alignment: .bottom) {
                    // Above the dock, on the day view and on persona pages alike.
                    UndoDeletionBar().padding(.bottom, 92)
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
            .sheet(item: $editing) { item in
                ItemEditor(item: item, viewingDay: persona == nil ? day : item.liveDay(now: now), openItem: openOnItsDay)
                    .environmentObject(store)
            }
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
            // Resolving the last item in a filter returns to the full day rather than an empty list.
            .onChange(of: activeFilterCount) { _, count in
                if count == 0 { setFilter(.all) }
            }
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
            // The indicator runs only between the top controls and the dock, never under the glass.
            .contentMargins(.top, insets.top, for: .scrollIndicators)
            .contentMargins(.bottom, insets.bottom + 94, for: .scrollIndicators)
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
            Color.clear
                .overlay(alignment: .bottom) {
                    // Bottom-aligned with the capsule, so the calendar grows up out of it.
                    dateGlass
                        .background(alignment: .bottom) { capsuleDecorations }
                        .padding(.bottom, 8)
                }
        }
        .frame(maxWidth: .infinity).frame(height: 72)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { dockWidth = $0 }
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
    /// The day capsule and the calendar are one piece of glass. A single animation grows its
    /// frame from the capsule's size to the calendar's and back, and both are clipped to it:
    /// the calendar stays still at full size and is uncovered as the glass grows, rather than
    /// scaled on a separate timing, so it can never drift from the glass beneath it.
    private var dateGlass: some View {
        // A fixed radius, the capsule's own at its height: a capsule shape would keep its
        // ends fully round while growing, swelling the glass into a circle on the way.
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let size = pickingDate ? calendarSize : capsuleSize
        return ZStack(alignment: .bottom) {
            calendarCard
            dayNavigation
                // Out at once as the glass starts to grow; back once it has nearly folded. Only
                // the fade takes this timing: the position must follow the glass's spring.
                .animation(pickingDate ? .easeOut(duration: 0.1) : .easeOut(duration: 0.2).delay(0.15)) {
                    $0.opacity(pickingDate ? 0 : 1)
                }
                .allowsHitTesting(!pickingDate)
                .accessibilityHidden(pickingDate)
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .clipShape(shape)
        .glassEffect(.regular.interactive(!calendarTransitionActive), in: shape)
    }
    /// The halo and relative date belong to the capsule, so they keep its size behind the
    /// glass while it grows into the calendar.
    private var capsuleDecorations: some View {
        Color.clear
            .frame(width: capsuleSize.width, height: capsuleSize.height)
            // Put the light behind the glass so its halo can spill beyond the capsule
            // instead of being contained by the glass effect.
            .background {
                // Keep one glow alive so reversing a day swipe reverses its fade
                // from the current brightness rather than restarting its entrance.
                TodayDateGlow(isVisible: day == Day(now) && !calendarTransitionActive)
            }
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
                        .offset(y: -26)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
    /// The calendar, on the same glass as the day capsule it opens from. Choosing a day,
    /// tapping outside or pulling it down folds it back into the capsule.
    ///
    /// The calendar stays built while hidden: creating it took long enough on device to
    /// stall the opening frames. It's laid out at its own width whatever the glass's size,
    /// so the morph never makes it lay out again.
    private var calendarCard: some View {
        DayCalendar(selection: date, today: now) { picked in
            navigate(to: picked)
            // Leave the new selection visible for a moment before folding away.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                closeCalendar()
            }
        }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: max(min(dockWidth - 32, 380), 0))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: \.size) { calendarSize = $0 }
            // The glass uncovers it; the fade only keeps the capsule's middle from showing
            // the calendar beneath its label, so it starts once the label has gone.
            .animation(pickingDate ? .easeOut(duration: 0.2).delay(0.08) : .easeIn(duration: 0.15)) {
                $0.opacity(pickingDate ? 1 : 0)
            }
            .allowsHitTesting(pickingDate)
            .accessibilityHidden(!pickingDate)
            .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
                if drag.translation.height > 50 { closeCalendar() }
            }, isEnabled: pickingDate)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { closeCalendar() }
    }
    /// Reduce Motion swaps the glass's size at once; only the contents cross-fade.
    private var calendarAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)
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
                    // As quick as the persona button's menu.
                    LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
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
                // The pressed glass swells into the relative-date pill above it, so the pill
                // leaves as soon as a press starts. Tracked alongside: on the high-priority
                // press above, tracking makes it start at touch-down and swallow taps.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
                    .updating($pressingDate) { pressing, state, _ in state = pressing })
                .onChange(of: pressingDate) { _, pressing in
                    guard pressing, showingRelativeDate else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showingRelativeDate = false }
                }
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
        // Its own size even inside the grown glass, which the glass shrinks back to.
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { capsuleSize = $0 }
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
                    // Release the glass press before it starts to grow.
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
        daySwipeInteraction.holdsPageWork = true
        withAnimation(calendarAnimation) {
            calendarTransitionActive = true
            pickingDate = true
        }
    }
    private func closeCalendar() {
        guard pickingDate else { return }
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(800)) }
        withAnimation(calendarAnimation, completionCriteria: .logicallyComplete) {
            pickingDate = false
            calendarTransitionActive = false
        } completion: {
            // Only once the glass is back in the capsule: building the new day's neighbours
            // mid-fold made it stutter on device.
            if !pickingDate { daySwipeInteraction.holdsPageWork = false }
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
    /// Closes the open editor, moves the day view to `item`'s day and opens the item there, so
    /// Go to original item shows where the original is rather than only its details.
    private func openOnItsDay(_ item: PlanItem) {
        editing = nil
        Task { @MainActor in
            // Let the sheet finish closing before the day changes under it.
            try? await Task.sleep(for: .milliseconds(450))
            if persona != nil { persona = nil }
            navigate(to: item.day.date())
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 450))
            editing = store.item(item.id) ?? item
        }
    }
    private func goToToday() {
        navigate(to: Calendar.current.startOfDay(for: Date()))
    }
    private var filterButtons: some View {
        let reminderCount = reminderItems.count
        let reviewCount = reviewItems.count
        let deadlineCount = deadlineItems.count
        let showReminders = showingReminders || reminderCount > 0
        let showReview = reviewing || reviewCount > 0
        let showDeadlines = showingDeadlines || deadlineCount > 0
        let transition: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .trailing))
        return HStack(spacing: 10) {
            if showDeadlines {
                Button {
                    // A button fading out after a day change still takes taps; state is read live.
                    guard showingDeadlines || !deadlineItems.isEmpty else { return }
                    setFilter(showingDeadlines ? .all : .deadlines)
                } label: {
                    filterIcon("flag.fill", tint: .red, count: deadlineCount, isActive: showingDeadlines)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingDeadlines ? "Show full day" : "Show \(deadlineCount) items with deadlines")
                .accessibilityValue(showingDeadlines ? "Deadline filter on" : "Deadline filter off")
                .accessibilityAddTraits(showingDeadlines ? .isSelected : [])
                .accessibilityHint("Toggles unfinished items with a deadline for this day")
                .transition(transition)
            }
            if showReminders {
                Button {
                    guard showingReminders || !reminderItems.isEmpty else { return }
                    setFilter(showingReminders ? .all : .reminders)
                } label: {
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
                Button {
                    guard reviewing || !reviewItems.isEmpty else { return }
                    setReviewing(!reviewing)
                } label: {
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
        .frame(width: 152, height: 44, alignment: .trailing)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32), value: showDeadlines)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32), value: showReminders)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32), value: showReview)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!showReminders && !showReview && !showDeadlines)
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
        // Items carried on from this day stay in their place as quiet entries. They count
        // towards completion on their live day, but a filter takes each row that has its dot.
        let moved = Planner.movedItems(from: day, in: store.items, now: now)
        let filtered = (visible + moved).filter { matches($0, filter, on: day) }
        // Every row stays mounted and the filter only collapses the others. A row inserted when
        // a filter cleared had no earlier position, so it appeared at its final spot while the
        // rows around it were still sliding back, overlapping them.
        let shown = Set(filtered.map(\.id))
        // A carried item keeps its old time on its scheduled day; elsewhere it is untimed.
        let keepsTime = { (item: PlanItem) in item.minute != nil && (!item.isCarried(now: now) || item.day == day) }
        let order = { (a: PlanItem, b: PlanItem) in
            if a.minute != b.minute { return (a.minute ?? -1) < (b.minute ?? -1) }
            return a.createdAt < b.createdAt
        }
        let anyTimeItems = (visible + moved).filter { !keepsTime($0) }.sorted(by: order)
        let timedItems = (visible + moved).filter(keepsTime).sorted(by: order)
        return ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Spacer(minLength: 0)
                    if reviewing {
                        Text("\(filtered.count) to review").font(.caption).foregroundStyle(reviewTint)
                    } else if showingReminders {
                        Text("\(filtered.count) with reminders").font(.caption).foregroundStyle(.blue)
                    } else if filter == .deadlines {
                        Text("\(filtered.count) with deadlines").font(.caption).foregroundStyle(.red)
                    } else if !visible.isEmpty {
                        // Cancelled items are left out of the total: nothing is asked of them.
                        Text("\(visible.filter(\.isComplete).count)/\(visible.filter { !$0.isCancelled }.count) complete")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
                if filter == .all && visible.isEmpty && moved.isEmpty {
                    // Just a quiet line: the add button below already starts the day.
                    Text("Nothing planned")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                    // Once the last section has gone, rather than on top of it.
                    .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.15)))
                }
                if !anyTimeItems.isEmpty {
                    sectionHeading("Anytime")
                        .modifier(FilterCollapse(collapsed: !anyTimeItems.contains { shown.contains($0.id) }))
                        .transition(sectionRemoval)
                    anytimeItems(items: anyTimeItems, shown: shown, day: day, filter: filter)
                        .padding(.horizontal, 16)
                        .transition(sectionRemoval)
                }
                if !timedItems.isEmpty {
                    sectionHeading("Scheduled")
                        .modifier(FilterCollapse(collapsed: !timedItems.contains { shown.contains($0.id) }))
                        .transition(sectionRemoval)
                    scheduledItems(items: timedItems, shown: shown, day: day, filter: filter)
                        .padding(.horizontal, 16)
                        .transition(sectionRemoval)
                }
                SettingsLink(isEnabled: { daySwipeInteraction.allowsItemActions })
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
        .modifier(ScrollsToNowInTimeView(proxy: proxy))
        }
    }
    /// A section whose last item was deleted leaves quickly: with the list's half-second
    /// animation it lingered under the empty day that took its place.
    private var sectionRemoval: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.15)))
    }
    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
    }
    /// Use the same measured-row layout as Scheduled, without the clock-axis placement.
    private func anytimeItems(items: [PlanItem], shown: Set<UUID>, day: Day, filter: DayFilter) -> some View {
        let contentKey = TimelineContentKey(items: items, day: day, order: items.map(\.id),
                                            markers: items.map { item in [DayFilter.review, .reminders, .deadlines].map { matches(item, $0, on: day) } },
                                            filter: filter.rawValue, showNow: false, timeNotes: [], typeSize: dynamicTypeSize)
        return DayTimelineLayout(startMinute: 0, laneCount: 1, contentKey: contentKey, compactOnly: true, progress: 0) {
            // The same rows as Scheduled, with the same pair of List and Time view copies and
            // modifiers; as plain rows they made each filter animation drop frames on a phone.
            ForEach(items) { item in
                ForEach([false, true], id: \.self) { timedVariant in
                    row(item, filter: filter, day: day, sharedSchedule: true, timeBelowTitle: timedVariant)
                        .modifier(FilterCollapse(collapsed: !shown.contains(item.id)))
                        .layoutValue(key: TimelineCollapsedKey.self, value: !shown.contains(item.id))
                        .modifier(ModeRowVariant(isTimed: timedVariant, compactSortPriority: 0))
                        .layoutValue(key: TimelineTimedVariantKey.self, value: timedVariant)
                }
            }
        }
        // Blend the row copies with each other before compositing over the page.
        .compositingGroup()
        // An empty asynchronous canvas, like the scale and connectors behind Scheduled, has
        // SwiftUI render the group off the main thread. Without it every filter animation here
        // dropped a frame several times a second on a phone, while Scheduled stayed smooth.
        .background { Canvas(rendersAsynchronously: true) { _, _ in }.allowsHitTesting(false).accessibilityHidden(true) }
        .accessibilityElement(children: .contain)
    }

    /// All of the day's timed items; those not in `shown` are collapsed by the filter.
    private func scheduledItems(items: [PlanItem], shown: Set<UUID>, day: Day, filter: DayFilter) -> some View {
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
            // A carried entry is drawn as quietly as a finished item.
            return TimelineEntry(id: item.id, minute: minute(start), endMinute: item.end.map(minute),
                                 complete: item.isSettled || item.movedAway(from: day, now: now))
        }.sorted { $0.minute < $1.minute }
        let currentMinute: Double? = day == Day(now) ? Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)) : nil
        let firstMinute = min(entries.map(\.minute).min() ?? 360, currentMinute ?? 360)
        let startMinute = min(360, floor(firstMinute / 60) * 60)
        let lanes = TimelineEntry.durationLanes(for: entries)
        let isToday = day == Day(now)
        let showNow = filter == .all && isToday
        // The group dividers stay mounted on today and only collapse under a filter.
        let inProgress = isToday ? items.filter { $0.isInProgress(now: now) } : []
        let active = showNow ? inProgress : []
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
        let contentKey = TimelineContentKey(items: items, day: day, order: compactItems.map(\.id),
                                            markers: items.map { item in [DayFilter.review, .reminders, .deadlines].map { matches(item, $0, on: day) } },
                                            filter: filter.rawValue, showNow: showNow,
                                            timeNotes: items.map { timeNote($0, day: day) != nil },
                                            typeSize: dynamicTypeSize)
        return ModeTimelineLayout(startMinute: startMinute, laneCount: (lanes.values.max() ?? 0) + 1,
                                  contentKey: contentKey) {
            if isToday, let first = past.first(where: { item in !inProgress.contains { $0.id == item.id } }) {
                let order = (compactOrder[first.id] ?? 0) - 1
                compactSectionDivider("Past")
                    .modifier(FilterCollapse(collapsed: !showNow))
                    .layoutValue(key: TimelineCompactOrderKey.self, value: order)
                    .accessibilitySortPriority(-Double(order))
            }
            if !inProgress.isEmpty {
                compactSectionDivider("In progress")
                    .modifier(FilterCollapse(collapsed: !showNow))
                    .layoutValue(key: TimelineCompactOrderKey.self, value: activeTop)
                    .accessibilitySortPriority(-Double(activeTop))
            }
            if isToday, let first = upcoming.first {
                let order = (compactOrder[first.id] ?? 0) - 1
                compactSectionDivider("Upcoming")
                    .modifier(FilterCollapse(collapsed: !showNow))
                    .layoutValue(key: TimelineCompactOrderKey.self, value: order)
                    .accessibilitySortPriority(-Double(order))
            }
            ForEach(items) { item in
                ForEach([false, true], id: \.self) { timedVariant in
                    row(item, filter: filter, day: day, sharedSchedule: true, timeBelowTitle: timedVariant)
                        .modifier(FilterCollapse(collapsed: !shown.contains(item.id)))
                        .layoutValue(key: TimelineCollapsedKey.self, value: !shown.contains(item.id))
                        .modifier(ModeRowVariant(isTimed: timedVariant,
                                                 compactSortPriority: showNow ? -Double(compactOrder[item.id] ?? 0) : 0))
                        .layoutValue(key: TimelineCompactOrderKey.self, value: compactOrder[item.id] ?? 0)
                        .layoutValue(key: TimelineTimedVariantKey.self, value: timedVariant)
                        .layoutValue(key: TimelineMinuteKey.self, value: entries.first(where: { $0.id == item.id })?.minute ?? 0)
                }
                if let start = item.start() {
                    // Keep one visible time label across both modes. The rows
                    // reserve its measured space but never crossfade its text, also
                    // when a filter opens a panel below the row.
                    scheduleLabel(item, start: start, day: day)
                        .multilineTextAlignment(.trailing)
                        .modifier(ModeScheduleColumn(width: scheduleColumnWidth))
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(SharedLabelVisibility(shown: shown.contains(item.id)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .layoutValue(key: TimelineSharedTimeInsetKey.self, value: ItemCard.trailingInset)
                }
                if let entry = entries.first(where: { $0.id == item.id }) {
                    TimelineConnector(complete: entry.complete)
                        .opacity(shown.contains(item.id) ? 1 : 0)
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
                TimelineScale(entries: entries.filter { shown.contains($0.id) }, startMinute: startMinute, date: beginning, lanes: lanes)
                    .equatable()
                    .frame(height: DayTimelineLayout.top * 2 + CGFloat(1440 - startMinute) * DayTimelineLayout.pointsPerMinute)
                // The minute tick only moves this small marker, never redrawing the tall scale.
                if let currentMinute, currentMinute >= startMinute {
                    // Laid out rather than offset, and a view of its own below a spacer: scrolling
                    // to an offset or padded view finds the top of the timeline instead.
                    VStack(spacing: 0) {
                        Color.clear.frame(width: 1, height: DayTimelineLayout.top + CGFloat(currentMinute - startMinute) * DayTimelineLayout.pointsPerMinute)
                        Color.clear.frame(width: 1, height: 1).id(TimelineNowMarker.anchorID)
                    }
                    .accessibilityHidden(true)
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
    private func compactSectionDivider(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 0)
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
    private func row(_ item: PlanItem, filter: DayFilter, day: Day, sharedSchedule: Bool = false,
                     showsMenu: Bool = true, timeBelowTitle: Bool = false) -> some View {
        let reviewing = filter == .review
        let showingReminders = filter == .reminders
        // On the days an item was carried on from, it stays in its place as a quiet entry pointing
        // to where it went. It is the same item as on its live day, so completing or opening it
        // here acts on that copy; it isn't counted, reviewed or reminded about here, but keeps an
        // orange dot while unfinished so the earlier day still shows it was left open.
        let carried = carriedDestination(item, from: day)
        let review = matches(item, .review, on: day)
        let reminder = matches(item, .reminders, on: day)
        let deadline = matches(item, .deadlines, on: day)
        // A carried entry keeps its time on its scheduled day; elsewhere a carried item is untimed.
        let showsTime = carried != nil ? day == item.day : !item.isCarried(now: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                CompletionButton(item: item, day: day, isEnabled: { daySwipeInteraction.allowsItemActions },
                                 keepsCarriedArrow: carried != nil) {
                    Group {
                        if carried != nil {
                            OutlinedCompletionCircle(glyph: .chevron)
                                .foregroundStyle(.tertiary)
                        } else if let progress = timeProgress(item) {
                            ProgressCircle(progress: progress)
                        } else {
                            // A completed item's tick is drawn by the button over this.
                            OutlinedCompletionCircle(glyph: item.isCancelled ? .cross : .none)
                                .foregroundStyle(item.isCancelled ? .tertiary : .primary)
                        }
                    }
                }
                .accessibilityValue([carried.map { "Carried to \($0)" }, item.isCancelled ? "Cancelled" : nil,
                                     carried == nil ? timeProgress(item).flatMap { $0 >= 1 ? "Time passed" : $0 > 0 ? "\(Int($0 * 100))% of the time passed" : nil } : nil,
                                     review ? "Needs review" : nil, reminder ? "Reminder set" : nil,
                                     deadline ? item.deadline.map { "Due \($0.formatted(date: .abbreviated, time: .shortened))" } : nil].compactMap { $0 }.joined(separator: ", "))
                Button {
                    guard daySwipeInteraction.allowsItemActions else { return }
                    editing = item
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            itemTitle(item, isCarriedEntry: carried != nil)
                                .fixedSize(horizontal: false, vertical: true)
                            if let carried {
                                Text("Carried to \(carried)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            if timeBelowTitle, let start = item.start(), showsTime {
                                scheduleLabel(item, start: start, day: day)
                                    .frame(width: scheduleColumnWidth, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .modifier(SharedScheduleVisibility(shared: sharedSchedule))
                                    .accessibilityHidden(sharedSchedule)
                                    .alignmentGuide(.scheduleLeading) { $0[.leading] }
                                    .alignmentGuide(.scheduleTop) { $0[.top] }
                            }
                            if !item.people.isEmpty || !item.locations.isEmpty {
                                itemDetailsLine(item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !timeBelowTitle, let start = item.start(), showsTime {
                            scheduleLabel(item, start: start, day: day)
                                .multilineTextAlignment(.trailing)
                                // The shared label's column, also in the lifted copy, so lifting
                                // moves the same layout rather than cross-fading to another.
                                .frame(width: scheduleColumnWidth, alignment: .trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .modifier(SharedScheduleVisibility(shared: sharedSchedule))
                                .accessibilityHidden(sharedSchedule)
                                .alignmentGuide(.scheduleLeading) { $0[.leading] }
                                .alignmentGuide(.scheduleTop) { $0[.top] }
                                .layoutPriority(1)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(ItemCardPressStyle())
                    .accessibilityValue([carried.map { "Carried to \($0)" },
                                         sharedSchedule && showsTime ? item.start().map { timeLabel(item, start: $0, day: day) } : nil,
                                         timeNote(item, day: day, width: .wide),
                                         // A carried entry's circle doesn't show a tick, so say it here.
                                         item.isCancelled ? "Cancelled" : carried != nil && item.isComplete ? "Completed" : nil].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint((review ? "Needs review. " : "") + (reminder ? "Reminder set. " : "") + "Open details and edit")
                    .accessibilityAction(named: item.isCancelled ? "Uncancel" : "Cancel") { setCancelled(item, !item.isCancelled, on: day) }
            }
            // Always present, collapsed outside a filter, so it opens and moves with its row in
            // the filter's one animation. A panel inserted only when filtering started had no
            // earlier position: the timeline layout put it straight at its final spot, ahead of
            // its moving row, so it used to wait for the rows to settle before fading in.
            let showsPanel = filter != .all && matches(item, filter, on: day)
            itemStatusPanel(item, filter: panelFilter, day: day)
                .padding(.leading, 52).padding(.bottom, 12)
                // The panel expands by revealing its full-size contents, not by squeezing
                // and remeasuring its action buttons on each frame of the height animation.
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: showsPanel ? nil : 0, alignment: .top)
                .clipped()
                .opacity(showsPanel ? 1 : 0)
                .allowsHitTesting(showsPanel)
                .accessibilityHidden(!showsPanel)
        }
        // Dots show only in the full day; a filtered row's panel already says why it is there.
        .padding(.trailing, filter != .all ? 0 : (review ? 14.0 : 0) + (reminder ? 14.0 : 0) + (deadline ? 14.0 : 0))
        .overlay(alignment: .trailing) {
            rowMarkers(item, filter: filter, day: day)
        }
        // Every item has the same faint fill: open, ticked, cancelled or carried.
        .modifier(ItemCard())
        .itemMenuOnHold(item, day: day, isEnabled: { daySwipeInteraction.allowsItemActions }, showsMenu: showsMenu) {
            AnyView(row(item, filter: filter, day: day, showsMenu: false, timeBelowTitle: timeBelowTitle))
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.primary.opacity(0.07))
    }
    /// Where an item went, if `day` is one it was carried on from.
    private func carriedDestination(_ item: PlanItem, from day: Day) -> String? {
        guard item.movedAway(from: day, now: now) else { return nil }
        let live = item.liveDay(now: now)
        return live == Day(now) ? "today" : live.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
    /// The dots of every filter the row is in, in the full day only.
    private func rowMarkers(_ item: PlanItem, filter: DayFilter, day: Day) -> some View {
        HStack(spacing: 8) {
            if filter == .all && matches(item, .review, on: day) {
                Circle().fill(reviewTint).frame(width: 6, height: 6)
            }
            if filter == .all && matches(item, .reminders, on: day) {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
            if filter == .all && matches(item, .deadlines, on: day) {
                Circle().fill(.red).frame(width: 6, height: 6)
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
    private func setCancelled(_ item: PlanItem, _ cancelled: Bool, on day: Day) {
        guard daySwipeInteraction.allowsItemActions else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.setCancelled(item, cancelled, on: day) }
    }
    private func setReviewing(_ value: Bool) {
        setFilter(value ? .review : .all)
    }
    private func setFilter(_ value: DayFilter) {
        guard value != filter else { return }
        filterTransition &+= 1
        let transition = filterTransition
        daySwipeInteraction.isFiltering = true
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
        withAnimation(reviewAnimation, completionCriteria: .removed) {
            filter = value
            if value != .all { panelFilter = value }
        } completion: {
            // A second tap owns the pause until its own transition is finished.
            guard transition == filterTransition else { return }
            daySwipeInteraction.isFiltering = false
        }
    }
    private func itemStatusPanel(_ item: PlanItem, filter: DayFilter, day: Day) -> some View {
        let reminder = filter == .reminders
        let deadline = filter == .deadlines
        let message: String
        if reminder, let time = item.displayedReminder(now: now) {
            message = time.formatted(date: Day(time) == day ? .omitted : .abbreviated, time: .shortened)
                + (item.reminders.count > 1 ? " · \(item.reminders.count) reminders" : "")
        } else if deadline, let due = item.deadline {
            // The reminder panel's format: a custom pattern is built on first use, which stalled the
            // filter's opening animation the first time.
            let when = due.formatted(date: Day(due) == day ? .omitted : .abbreviated, time: .shortened)
            message = due <= now ? "Was due \(when)" : "Due \(when)"
        } else if let carried = carriedDestination(item, from: day) {
            message = "Unfinished, carried to \(carried)"
        } else {
            message = item.end != nil ? "This time has ended" : "The scheduled time has passed"
        }
        var actions = [FilteredItemAction(title: "Complete", symbol: "checkmark") {
            withAnimation(self.reviewAnimation) { self.store.toggle(item, on: day) }
        }]
        if deadline {
            actions.append(FilteredItemAction(title: "Change", symbol: "calendar") { self.editing = item })
            actions.append(FilteredItemAction(title: "Remove", symbol: "flag.slash") {
                guard var updated = self.store.item(item.id) else { return }
                updated.deadline = nil
                do { try withAnimation(self.reviewAnimation) { try self.store.save(updated) } }
                catch { self.store.errorMessage = error.localizedDescription }
            })
        } else if reminder {
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
        return FilteredItemPanel(symbol: deadline ? "flag" : reminder ? "alarm" : "exclamationmark.triangle",
                                 message: message, tint: deadline ? .red : reminder ? .blue : reviewTint,
                                 itemTitle: item.title, actions: actions.map { action in
            FilteredItemAction(title: action.title, symbol: action.symbol) {
                guard daySwipeInteraction.allowsItemActions else { return }
                action.action()
            }
        })
    }
    private func itemTitle(_ item: PlanItem, isCarriedEntry: Bool = false) -> some View {
        Text(item.title).font(.body.weight(.medium))
            .settledTitleStyle(item, isCarriedEntry: isCarriedEntry)
    }
    private func scheduleLabel(_ item: PlanItem, start: Date, day: Day) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // The same light grey as the row's other small text (people, places, carried, time left).
            Text(timeLabel(item, start: start, day: day))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let note = timeNote(item, day: day) {
                Text(note)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
    // Today only: how long an item in progress has left, or how soon an upcoming one starts.
    private func timeNote(_ item: PlanItem, day: Day, width: Duration.UnitsFormatStyle.UnitWidth = .narrow) -> String? {
        guard day == Day(now), !item.isSettled, let start = item.start() else { return nil }
        let target: Date
        if item.isInProgress(now: now), let end = item.end { target = end }
        else if start > now { target = start }
        else { return nil }
        // Round up so the note never says 0 while there is still time to go.
        let minutes = (target.timeIntervalSince(now) / 60).rounded(.up)
        let amount = Duration.seconds(max(1, minutes) * 60)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: width, maximumUnitCount: 2))
        return target == start ? "in \(amount)" : "\(amount) left"
    }
    // How far an unfinished item's time has run, or nil once it's complete or cancelled.
    // Anytime and carried items have no time today, so they stay at 0; a point
    // time is reached all at once, and a range runs from its start to its end.
    private func timeProgress(_ item: PlanItem) -> Double? {
        guard !item.isSettled else { return nil }
        guard !item.isCarried(now: now), let start = item.start() else { return 0 }
        guard let end = item.end, end > start else { return start <= now ? 1 : 0 }
        return min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
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
        item.personas = persona.map { [$0] } ?? []
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
        // By position, so switching between the review and reminder panels relabels the
        // buttons rather than inserting new ones.
        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
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
    /// While List and Time view switch, each timed row's time is drawn by one shared label that
    /// travels with the row; at rest the row draws its own, like its title.
    var switching = false
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
            // The rows hand their time to the shared labels at once, in the same place.
            mode.switching = true
            withAnimation(ViewMode.animation(reduceMotion: reduceMotion)) { mode.showingTime.toggle() }
            // Neighbouring pages update once the switch has finished animating, and the rows
            // take their time back.
            previewSync?.cancel()
            previewSync = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                previewMode.showingTime = mode.showingTime
                mode.switching = false
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
    let compactSortPriority: Double
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let active = mode.showingTime == isTimed
        content
            .opacity(active ? 1 : 0)
            // Both variants share a position, so additive blending keeps
            // identical pixels fully opaque instead of dipping to 75%
            // halfway through a normal crossfade. Only while switching: a row
            // blended this way that moved in from off screen (a filter
            // closing up the list above) stayed undrawn until the move ended.
            .blendMode(mode.switching ? .plusLighter : .normal)
            .animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .accessibilitySortPriority(mode.showingTime ? 0 : compactSortPriority)
    }
}

/// Brings the current time into view whenever Time view opens on today.
private struct ScrollsToNowInTimeView: ViewModifier {
    let proxy: ScrollViewProxy
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: mode.showingTime) { _, showingTime in
            guard showingTime else { return }
            // Alongside the rows' move, so the timeline arrives already showing now.
            withAnimation(ViewMode.animation(reduceMotion: reduceMotion)) {
                proxy.scrollTo(TimelineNowMarker.anchorID, anchor: .center)
            }
        }
    }
}

/// Keep UIKit's month layout and intrinsic sizing inside the dock's animated glass.
/// Multi-date selection reports taps on a highlighted day too, allowing that tap to
/// close the calendar. The viewed date is a blue circle; today is UIKit's own blue number.
/// (Adding today to the selection drew both as the same circle.)
private struct DayCalendar: UIViewRepresentable {
    let selection: Date
    let today: Date
    let onPick: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = .current
        view.locale = .current
        // A colour tint is what lets UIKit set today apart: with the label colour, today's
        // number looked like every other day.
        view.tintColor = .systemBlue
        context.coordinator.today = Day(today)
        view.wantsDateDecorations = false
        let selection = UICalendarSelectionMultiDate(delegate: context.coordinator)
        view.selectionBehavior = selection
        context.coordinator.selection = selection
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.onPick = onPick
        let currentDay = Day(today)
        if context.coordinator.today != currentDay {
            // The calendar stays built while hidden, so redraw its days when the date changes.
            context.coordinator.today = currentDay
            view.calendar = .current
        }
        let day = Day(selection)
        guard context.coordinator.day != day else { return }
        context.coordinator.day = day
        let components = Coordinator.components(of: selection)
        context.coordinator.selection?.setSelectedDates([components], animated: false)
        view.setVisibleDateComponents(components, animated: false)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? 360
        let height = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel).height
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UICalendarSelectionMultiDateDelegate {
        var onPick: (Date) -> Void
        weak var selection: UICalendarSelectionMultiDate?
        var day: Day?
        var today: Day?
        init(onPick: @escaping (Date) -> Void) { self.onPick = onPick }

        static func components(of date: Date) -> DateComponents {
            Calendar.current.dateComponents([.calendar, .era, .year, .month, .day], from: date)
        }
        func multiDateSelection(_ selection: UICalendarSelectionMultiDate, didSelectDate dateComponents: DateComponents) {
            guard let date = Calendar.current.date(from: dateComponents) else { return }
            selection.setSelectedDates([Self.components(of: date)], animated: false)
            day = Day(date)
            onPick(date)
        }
        func multiDateSelection(_ selection: UICalendarSelectionMultiDate, didDeselectDate dateComponents: DateComponents) {
            guard let date = Calendar.current.date(from: dateComponents) else { return }
            selection.setSelectedDates([Self.components(of: date)], animated: false)
            day = Day(date)
            onPick(date)
        }
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
// An unfinished item's circle: a light grey outline until its time comes, then
// traced clockwise in dark grey as the time runs, so it reads as ready to tick off once closed.
private struct ProgressCircle: View {
    let progress: Double
    @Environment(\.colorSchemeContrast) private var contrast
    private static let lineWidth = CompletionCircle.lineWidth

    var body: some View {
        ZStack {
            // Increase Contrast keeps the untouched outline clearly visible.
            Circle().stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.25), lineWidth: Self.lineWidth)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(Self.lineWidth / 2)
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
                        Text("This updates the reminder time for the original item and all its linked items.")
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

// Cache the composed gradient and mask as one rasterized layer. Even a still
// masked gradient otherwise adds compositing work behind the live glass backdrop.
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
    private var renderedStyle: UIUserInterfaceStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        container.addSublayer(gradient)
        container.mask = ringMask
        container.shouldRasterize = true
        layer.addSublayer(container)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: GlowRingView, _) in
            view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("GlowRingView is created programmatically") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = traitCollection.displayScale
        let style = traitCollection.userInterfaceStyle
        // Filter/layout updates can visit this view without changing the glow. Reassigning
        // gradient properties would invalidate the raster cache during those animations.
        guard maskSize != bounds.size || maskScale != scale || renderedStyle != style else { return }
        renderedStyle = style
        let frame = bounds.insetBy(dx: -Self.spill, dy: -Self.spill)
        let side = hypot(frame.width, frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = frame
        container.rasterizationScale = scale
        ringMask.frame = container.bounds
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        gradient.colors = Self.colors.map { UIColor($0).resolvedColor(with: traitCollection).cgColor }
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

// The reserved schedule label supplies its exact position through the nested row stacks.
private enum ScheduleLeading: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.leading] }
}
private enum ScheduleTop: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.top] }
}
private extension HorizontalAlignment {
    static let scheduleLeading = HorizontalAlignment(ScheduleLeading.self)
}
private extension VerticalAlignment {
    static let scheduleTop = VerticalAlignment(ScheduleTop.self)
}

/// Only the small shared label reads the mode; the day and its endpoint rows stay mounted.
private struct ModeScheduleColumn: ViewModifier {
    let width: CGFloat
    @Environment(ViewMode.self) private var mode
    func body(content: Content) -> some View {
        content.frame(width: width, alignment: mode.showingTime ? .leading : .trailing)
    }
}

private struct TimelineCollapsedKey: LayoutValueKey {
    static let defaultValue = false
}

/// Collapses a row, heading or section that a filter hides, keeping it mounted so it
/// returns from where it is rather than appearing at its final spot.
private struct FilterCollapse: ViewModifier {
    let collapsed: Bool

    func body(content: Content) -> some View {
        content
            // Keep the contents at their natural height while the outer frame closes.
            // Otherwise shrinking Anytime rows repeatedly compress their buttons/text.
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: collapsed ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}

private struct TimelineSharedTimeInsetKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

private struct TimelineConnectorLaneKey: LayoutValueKey {
    static let defaultValue: Int? = nil
}

// Everything that can change a row's measured size or compact order.
/// The row's time label gives way to the shared label only while List and Time switch.
private struct SharedScheduleVisibility: ViewModifier {
    let shared: Bool
    @Environment(ViewMode.self) private var mode: ViewMode?

    func body(content: Content) -> some View {
        content.opacity(shared && mode?.switching == true ? 0 : 1)
    }
}

/// The shared time label, shown only while List and Time view switch.
private struct SharedLabelVisibility: ViewModifier {
    let shown: Bool
    @Environment(ViewMode.self) private var mode: ViewMode?

    func body(content: Content) -> some View {
        content.opacity(shown && mode?.switching == true ? 1 : 0)
    }
}

private struct TimelineContentKey: Equatable {
    let items: [PlanItem]
    let day: Day
    let order: [UUID]
    let markers: [[Bool]]
    let filter: Int
    let showNow: Bool
    let timeNotes: [Bool]
    let typeSize: DynamicTypeSize
}

// Measure the two endpoint layouts once, then only interpolate positions while
// animating. Repeated text measurement during each frame caused uneven movement.
private struct DayTimelineLayout: Layout {
    let startMinute: Double
    let laneCount: Int
    let contentKey: TimelineContentKey
    var compactOnly = false
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
        if compactOnly {
            // Anytime shares Scheduled's cache and fixed endpoint proposals. The filter
            // moves/reveals measured rows, never compressing and remeasuring their text.
            for subview in subviews {
                // A row's Time view copy lies on its List view copy, as in Scheduled.
                if subview[TimelineTimedVariantKey.self], let last = cache.compact.last {
                    cache.compact.append(last)
                    cache.timed.append(last)
                    cache.proposals.append(ProposedViewSize(last.size))
                    continue
                }
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                let frame = CGRect(x: 0, y: compactBottom, width: width, height: height)
                cache.compact.append(frame)
                cache.timed.append(frame)
                cache.proposals.append(ProposedViewSize(width: width, height: height))
                compactBottom += height
            }
            cache.compactHeight = compactBottom
            cache.timedHeight = compactBottom
            cache.width = width
            cache.start = startMinute
            cache.gutter = gutter
            return
        }
        for index in subviews.indices {
            let subview = subviews[index]
            if let lane = subview[TimelineConnectorLaneKey.self] {
                // The preceding timed row supplies a fixed endpoint, its card's leading edge.
                // Connector bounds never interpolate, so Canvas does not redraw each frame.
                let row = lastTimedRow
                let x = 54 + CGFloat(lane) * 6 + 3
                let y = Self.top + CGFloat(subview[TimelineMinuteKey.self] - startMinute) * Self.pointsPerMinute
                let frame = CGRect(x: x, y: y, width: max(1, row.minX - x), height: max(1, row.midY - y + 1))
                cache.compact.append(frame)
                cache.timed.append(frame)
                cache.proposals.append(ProposedViewSize(width: frame.width, height: frame.height))
                continue
            }
            if subview[TimelineSharedTimeInsetKey.self] != nil {
                let first = cache.compact[index - 2], second = cache.timed[index - 1]
                let size = subview.sizeThatFits(.unspecified)
                // Follow the reserved label in each endpoint: beside the title in List,
                // beneath it in Time. Status panels don't affect either anchor.
                func labelFrame(in row: CGRect, variant: Int) -> CGRect {
                    let dimensions = subviews[variant].dimensions(in: ProposedViewSize(row.size))
                    return CGRect(x: row.minX + dimensions[HorizontalAlignment.scheduleLeading],
                                  y: row.minY + dimensions[VerticalAlignment.scheduleTop],
                                  width: size.width, height: size.height)
                }
                cache.compact.append(labelFrame(in: first, variant: index - 2))
                cache.timed.append(labelFrame(in: second, variant: index - 1))
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
            let collapsed = subview[TimelineCollapsedKey.self]
            // A row collapsed by a filter keeps its spot without pushing later rows down.
            let timeTop = marker ? max(0, timeBottom) : collapsed ? max(0, timeY)
                : max(0, max(timeY - timeHeight / 2, timeBottom + 8))
            cache.compact.append(CGRect(x: 0, y: compactBottom, width: width, height: compactHeight))
            cache.timed.append(CGRect(x: gutter, y: timeTop, width: timeWidth, height: timeHeight))
            cache.proposals.append(ProposedViewSize(width: width, height: compactHeight))
            compactBottom += compactHeight
            if !marker {
                if !collapsed { timeBottom = timeTop + timeHeight }
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
            let rowTop = cache.compact[index].minY
            cache.compact[index].origin.y = compactBottom
            if !subviews[index][TimelineMarkerKey.self] {
                cache.compact[index + 1].origin.y = compactBottom
                if index + 2 < subviews.count, subviews[index + 2][TimelineSharedTimeInsetKey.self] != nil {
                    cache.compact[index + 2].origin.y += compactBottom - rowTop
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
    static let anchorID = "timeline-now"
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
    /// While the calendar is open or folding, the pager leaves refreshing its page and building
    /// neighbours for later, so that work never shares frames with the glass morph.
    var holdsPageWork = false {
        didSet { if oldValue && !holdsPageWork { pageWorkResumed?() } }
    }
    /// Filtering still updates the visible page, but neighbour layout can wait.
    var isFiltering = false {
        didSet { if oldValue && !isFiltering { pageWorkResumed?() } }
    }
    var pageWorkResumed: (() -> Void)?
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
    let panelFilter: Int
    let minute: Int
    let typeSize: DynamicTypeSize
    let insets: EdgeInsets
    let reduceMotion: Bool

    func hasSameUnfilteredContent(as other: Self) -> Bool {
        // The two neighbouring pages always show All. Filter and status-panel changes
        // belong to the visible page and must not invalidate those neighbours.
        items == other.items && minute == other.minute && typeSize == other.typeSize
            && insets == other.insets && reduceMotion == other.reduceMotion
    }
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
        interaction.pageWorkResumed = { [weak coordinator] in coordinator?.refreshIfIdle() }
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
        if !revision.hasSameUnfilteredContent(as: coordinator.latestRevision) { coordinator.previewsDirty = true }
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
        coordinator.interaction.pageWorkResumed = nil
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
        private var settlingDay: Day?
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
            guard !dragging, animator == nil, requestedDay == day, !interaction.holdsPageWork else { return }
            if displayedRevision != latestRevision {
                host.content = latestContent
                displayedRevision = latestRevision
            }
            scheduleWarm()
        }
        private func scheduleWarm() {
            guard warmTask == nil, !dragging, animator == nil, requestedDay == day, size.width > 0,
                  !interaction.isFiltering else { return }
            warmTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.warmTask = nil
                guard !self.dragging, self.animator == nil, self.requestedDay == self.day,
                      !self.interaction.holdsPageWork, !self.interaction.isFiltering else { return }
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
                for scrollView in pageScrollViews() {
                    // The same touch may have started scrolling the page: stop it, and hide its
                    // indicator at once so it doesn't slide across the screen with the page.
                    scrollView.showsVerticalScrollIndicator = false
                    scrollView.panGestureRecognizer.isEnabled = false
                    scrollView.panGestureRecognizer.isEnabled = true
                }
                dragging = true
                dragOrigin = offset
            }
            offset = min(size.width, max(-size.width, dragOrigin + translation))
            guard !reduceMotion else { return }
            setTranslation(offset)
        }
        private func pageScrollViews() -> [UIScrollView] {
            func scrollViews(in view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            return ([host] + Array(previews.values)).flatMap { scrollViews(in: $0.view) }
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
        private func settle(direction: Int?, notify: Bool, destination: Day? = nil) {
            warmTask?.cancel()
            warmTask = nil
            settlingDirection = direction
            settlingDay = destination ?? direction.flatMap {
                Calendar.current.date(byAdding: .day, value: $0, to: day.date()).map { Day($0) }
            }
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
            let destination = settlingDay
            let notify = notifyOnSettle
            settlingDirection = nil
            settlingDay = nil
            notifyOnSettle = false
            if let direction { promote(direction: direction, destination: destination, preserving: 0) }
            else { offset = 0; setTranslation(0) }
            interaction.isPaging = false
            for scrollView in pageScrollViews() { scrollView.showsVerticalScrollIndicator = true }
            if let direction, notify { onSwipe(direction) }
            refreshIfIdle()
        }
        private func promote(direction: Int, destination: Day? = nil, preserving translation: CGFloat) {
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
            day = destination ?? Day(date)
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
            let destination = settlingDay
            let shouldNotify = notify && notifyOnSettle
            settlingDirection = nil
            settlingDay = nil
            notifyOnSettle = false
            if let direction {
                promote(direction: direction, destination: destination, preserving: visibleOffset + CGFloat(direction) * size.width)
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
            if animator != nil, settlingDay == selected { return }
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
            } else if !reduceMotion, size.width > 0, let container {
                // A distant jump (including holding the date to return to today) moves
                // one screen in chronological direction, using the actual destination.
                warmTask?.cancel()
                warmTask = nil
                for preview in previews.values { remove(preview) }
                previews.removeAll()
                let direction = delta > 0 ? 1 : -1
                let destination = Self.makeHost(latestContent, isForeground: false)
                install(destination, in: container)
                destination.view.isUserInteractionEnabled = false
                destination.view.accessibilityElementsHidden = true
                previews[direction] = destination
                positionPages()
                destination.view.layoutIfNeeded()
                settle(direction: direction, notify: false, destination: selected)
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
