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
    @State private var search = SearchPull()
    /// The filter on the search's results; the day's own filter stays as it was underneath.
    @State private var searchFilter: DayFilter = .all
    /// How far ahead search lists repeating items; "Show 3 more months" adds to it.
    @State private var searchMonths = 3
    private var searchHorizon: Day { PersonaHistoryView.horizon(months: searchMonths, from: now) }
    /// The filter on a persona page, its own like search's; choosing another persona clears it.
    @State private var personaFilter: DayFilter = .all
    /// How far ahead a persona page lists repeating items, kept here so the filters count the same days.
    @State private var personaMonths = 3
    private var personaHorizon: Day { PersonaHistoryView.horizon(months: personaMonths, from: now) }
    @State private var pickingDate = false
    @State private var calendarTransitionActive = false
    /// The calendar's size, which the glass it sits on grows to.
    @State private var calendarSize = CGSize(width: 360, height: 340)
    /// The day capsule's own size, which the glass folds back to.
    @State private var capsuleSize = CGSize(width: 222, height: 56)
    @State private var dockWidth: CGFloat = 402
    @State private var timelineOverflow = TimelineOverflow()
    @ScaledMetric(relativeTo: .subheadline) private var dateLabelWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .caption) private var scheduleColumnWidth: CGFloat = 90
    // Only the views that move or fade read the mode, so switching never
    // rebuilds DayView or the day's content.
    @State private var viewMode = ViewMode(persisted: true)
    // Neighbouring pages follow after the animation instead of during it.
    @State private var previewMode = ViewMode(persisted: false)
    /// Counts the days picked in the calendar, so the relative date shows once it has folded.
    @State private var calendarPicks = 0
    /// The item in its focussed state, from holding it or tapping its Live Activity.
    @State private var focused: Focused?
    private enum FocusSource { case day, persona, search }
    private struct Focused {
        /// This time in focus, so a card still closing can't clear the next one.
        let token = UUID()
        let id: UUID
        let day: Day
        let source: FocusSource
        let filter: DayFilter
        let timeBelowTitle: Bool
        var detailsRevision = 0
        /// The card goes back to its place.
        var ending = false
    }
    private var focusedItemIsGone: Bool { focused.map { store.item($0.id) == nil } ?? false }
    /// Actions and search changes can remove a row without deleting its underlying item.
    private var focusedInlineItemIsHidden: Bool {
        guard let focused, let item = store.item(focused.id) else { return false }
        switch focused.source {
        case .day:
            guard !search.isOpen, persona == nil, focused.day == day else { return true }
            guard focused.filter != .all else { return false }
            let appears = item.shows(on: focused.day, now: now) || item.movedAway(from: focused.day, now: now)
                || item.visits(focused.day, now: now)
            return !appears || !matches(item, filter, on: focused.day)
        case .search:
            guard search.isOpen, !search.query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
            return !filteredSearchResults.contains { entry in
                entry.day == focused.day && entry.items.contains { $0.id == focused.id }
            }
        case .persona:
            guard persona != nil, !search.isOpen else { return true }
            return !matches(item, personaFilter, on: focused.day) || !personaDays.contains { entry in
                entry.day == focused.day && entry.items.contains { $0.id == focused.id }
            }
        }
    }
    @State private var pickedFromCalendar = false
    enum DayFilter: Int { case all, review, reminders, deadlines }
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
    private var reminderItems: [PlanItem] { (visible + moved + visiting).filter { matches($0, .reminders, on: day) } }
    private var deadlineItems: [PlanItem] { (visible + moved + visiting).filter { matches($0, .deadlines, on: day) } }
    /// Items from other days with an upcoming reminder or open deadline on the viewed day.
    private var visiting: [PlanItem] { Planner.visitingItems(on: day, in: store.items, now: now) }
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
    /// Whether `item` on `day` is in the filter. A row is in a filter when it has that filter's
    /// dot, except that an item left open keeps its orange dot but leaves the review filter. A
    /// "Carried to" entry gets no reminder dot, as reminders are about its live day.
    private func matches(_ item: PlanItem, _ filter: DayFilter, on day: Day) -> Bool {
        // An item from another day is here only for the reminder or deadline that falls today.
        if item.visits(day, now: now) {
            switch filter {
            case .reminders: return item.reminds(on: day, now: now)
            case .deadlines: return item.isDue(on: day)
            case .all, .review: return false
            }
        }
        switch filter {
        case .all: return true
        case .review: return hasDot(item, .review, on: day) && !item.suggestionDismissed
        case .reminders, .deadlines: return hasDot(item, filter, on: day)
        }
    }
    /// Whether the row for `item` on `day` shows the filter's dot in the full day. The orange
    /// dot stays while the item is unfinished and late, even once it has been left open. A
    /// planned item's upcoming reminders and open deadline stay visible even on other dates.
    /// Visitors only get the dot for the reminder or deadline that brings them to this day.
    private func hasDot(_ item: PlanItem, _ filter: DayFilter, on day: Day) -> Bool {
        let carried = item.movedAway(from: day, now: now)
        switch filter {
        case .all: return false
        case .review: return !item.isSettled && (carried || isLate(item))
        case .reminders:
            return item.visits(day, now: now) ? item.reminds(on: day, now: now) : !carried && hasOpenReminder(item)
        case .deadlines:
            return item.visits(day, now: now) ? item.isDue(on: day) : item.hasOpenDeadline
        }
    }
    private func hasOpenReminder(_ item: PlanItem) -> Bool {
        !item.isSettled && item.reminders.contains { $0 > now }
    }
    private func needsReview(_ item: PlanItem) -> Bool {
        !item.isSettled && !item.suggestionDismissed && isLate(item)
    }
    private func isLate(_ item: PlanItem) -> Bool {
        // A carried item is already late and shown as untimed, so its old time isn't flagged.
        !item.isCarried(now: now) && item.isElapsed(now: now)
    }
    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ZStack(alignment: .bottom) {
                    DayPager(day: day,
                             content: pageContent(for: date, filter: filter, mode: viewMode, insets: viewport.safeAreaInsets,
                                                  overflow: timelineOverflow, pull: search),
                             adjacentContent: { adjacentDay in
                                 pageContent(for: adjacentDay.date(), filter: .all, mode: previewMode, insets: viewport.safeAreaInsets)
                             },
                             revision: DayPageRevision(items: store.items, sharedZones: store.cloud.sharedZones, filter: filter.rawValue, panelFilter: panelFilter.rawValue,
                                                       minute: Int(now.timeIntervalSinceReferenceDate / 60), typeSize: dynamicTypeSize,
                                                       insets: viewport.safeAreaInsets, reduceMotion: reduceMotion, focusedID: focused?.id, focusEnding: focused?.ending ?? false, focusDetailsRevision: focused?.detailsRevision ?? 0),
                             reduceMotion: reduceMotion,
                             onSwipe: { move($0) },
                             interaction: daySwipeInteraction)
                        .ignoresSafeArea(.container, edges: .vertical)
                    TimelineOverflowIndicators(overflow: timelineOverflow, insets: viewport.safeAreaInsets,
                                               date: date, relativeDateLabel: relativeDateLabel,
                                               calendarPicks: calendarPicks, calendarIsOpen: calendarTransitionActive)
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
                        .offset(y: DayDockLayout.lowering(for: viewport.safeAreaInsets.bottom))
                }
                // The day view stays alive underneath, so returning to All is instant.
                .opacity(persona == nil ? 1 : 0)
                .allowsHitTesting(persona == nil)
                .accessibilityHidden(persona != nil)
                .overlay {
                    ZStack(alignment: .bottomTrailing) {
                        PersonaPages(persona: $persona, now: now, add: add, months: $personaMonths, filter: personaFilter,
                                     matches: { matches($0, personaFilter, on: $1) },
                                     row: { AnyView(row($0, filter: personaFilter, day: $1, source: .persona)) },
                                     swipeBegan: daySwipeInteraction.begin, swipeEnded: daySwipeInteraction.end)
                            .contentMargins(.bottom, 94 - DayDockLayout.lowering(for: viewport.safeAreaInsets.bottom), for: .scrollContent)
                            .environment(search)
                        if persona != nil {
                            // Sits where the day dock's add button does, and stays put as pages slide.
                            addButton
                                .frame(height: 72)
                                .padding(.horizontal, 20).padding(.bottom, 4)
                                .offset(y: DayDockLayout.lowering(for: viewport.safeAreaInsets.bottom))
                                .transition(.opacity)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    // Above the dock, on the day view and on persona pages alike.
                    UndoDeletionBar().padding(.bottom, 92 - DayDockLayout.lowering(for: viewport.safeAreaInsets.bottom))
                }
                // Under the top controls, which stay in reach while searching.
                .overlay { SearchBackdrop(search: search) }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PersonaSwitcher(selection: $persona)
                        // The search button sits beside it, in the search layer above.
                        .onGeometryChange(for: CGPoint.self) { CGPoint(x: $0.frame(in: .global).maxX, y: $0.frame(in: .global).midY) }
                            action: { search.anchor = $0 }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // On a day they narrow the day; on a persona page its list, and while searching the results.
                    filterButtons
                }.sharedBackgroundVisibility(.hidden)
            }
            .sheet(item: $editing) { item in
                // A persona page or search can open an item from any day.
                ItemEditor(item: item, viewingDay: persona == nil && !search.isOpen ? day : item.liveDay(now: now),
                           range: store.isOriginal(item) ? store.dateRange(of: item) : nil, openItem: openOnItsDay)
                    .environmentObject(store)
            }
            .sheet(item: $changingReminder) { item in
                ReminderTimeEditor(item: item).environmentObject(store)
            }
            .onChange(of: date) { _, _ in
                if focused?.source == .day { focused = nil }
                filter = .all; store.showDay(day); timelineOverflow.day = day
            }
            // Deleted, here or on another device: nothing is left to close, and the page waits.
            .onChange(of: focusedItemIsGone) { _, gone in if gone { focused = nil } }
            .onChange(of: focusedInlineItemIsHidden) { _, hidden in
                if hidden { withAnimation(reviewAnimation) { focused = nil } }
            }
            .onChange(of: focused?.ending) { _, ending in
                if ending != false { FocusedCardAnchor.cancelPendingReveal() }
            }
            .onAppear { timelineOverflow.day = day }
            // A tapped Live Activity. It follows today's items, some of which began on an earlier day.
            .onOpenURL { url in
                guard url.scheme == "timo", url.host == "item", let id = UUID(uuidString: url.lastPathComponent),
                      let item = store.item(id) else { return }
                focusOnToday(item)
            }
            .onChange(of: store.reminderItemToFocus, initial: true) { _, id in
                guard let id else { return }
                store.reminderItemToFocus = nil
                guard let item = store.item(id) else { return }
                let today = Day(Date())
                let target = item.shows(on: today, now: Date()) ? today : item.liveDay(now: Date())
                focusOnDay(item, on: target)
            }
            // Resolving the last item in a filter returns to the full day rather than an empty list.
            .onChange(of: activeFilterCount) { _, count in
                if count == 0 { setFilter(.all) }
            }
            // Leaving search puts the filters back to the day's; resolving the last result in a
            // filter, or a search with none, returns to all results.
            .onChange(of: search.isOpen) { _, isOpen in
                if isOpen { store.generateRepeats(through: searchHorizon) } else { searchFilter = .all; searchMonths = 3 }
            }
            .onChange(of: searchFilter == .all ? nil : filterCount(searchFilter, in: searchResults)) { _, count in
                if count == 0 { withAnimation(reviewAnimation) { searchFilter = .all } }
            }
            // Each persona's page starts on all its items; resolving the last in a filter returns there.
            .onChange(of: persona) { _, _ in
                if focused?.source == .persona { focused = nil }
                personaFilter = .all; personaMonths = 3
            }
            .onChange(of: personaFilter == .all || search.isOpen ? nil : filterCount(personaFilter, in: personaDays)) { _, count in
                if count == 0 { withAnimation(reviewAnimation) { personaFilter = .all } }
            }
            .onAppear {
                store.showDay(day)
                search.isEnabled = { [daySwipeInteraction] in !pickingDate && daySwipeInteraction.allowsItemActions }
            }
            .onReceive(timer) { refresh($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh(Date()); store.refreshReminders(); store.cloud.resume() }
                else { daySwipeInteraction.cancelExternalDrag() }
            }
        }
        // Above the top controls too: the field takes their row.
        .overlay {
            // The day list's own rows, so results complete, open and take focus as they do there, and
            // open the same status panel under a filter.
            SearchLayer(pull: search, now: now, results: filteredSearchResults, persona: persona,
                        showsMore: store.repeats(searchResults.flatMap(\.items), after: searchHorizon),
                        showMore: {
                            searchMonths += 3
                            store.generateRepeats(through: searchHorizon)
                        },
                        row: { AnyView(row($0, filter: searchFilter, day: $1, source: .search)) })
        }
        // Observe outside taps without intercepting buttons, long presses or scrolling.
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            guard let focused, !FocusedCardAnchor.isHolding,
                  !FocusedCardAnchor.contains(tap.location, id: focused.id, day: focused.day) else { return }
            closeFocus()
        }, isEnabled: focused != nil && !pickingDate)
        .background {
            // ⌘F, without a button on screen.
            Button("Search") { search.open(reduceMotion: reduceMotion) }
                .keyboardShortcut("f")
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .tint(.primary)
    }
    private func pageContent(for date: Date, filter: DayFilter, mode: ViewMode, insets: EdgeInsets,
                             overflow: TimelineOverflow? = nil, pull: SearchPull? = nil) -> AnyView {
        AnyView(dayList(for: date, filter: filter)
            .contentMargins(.top, insets.top, for: .scrollContent)
            .contentMargins(.bottom, DayDockLayout.contentInset(for: insets.bottom), for: .scrollContent)
            // The indicator runs only between the top controls and the dock, never under the glass.
            .contentMargins(.top, insets.top, for: .scrollIndicators)
            .contentMargins(.bottom, DayDockLayout.contentInset(for: insets.bottom), for: .scrollIndicators)
            .environment(mode)
            .environment(overflow)
            .environment(pull)
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
                        .overlay(alignment: .top) { calendarTodayButton }
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
    /// The halo keeps the capsule's size behind the glass while it grows into the calendar.
    private var capsuleDecorations: some View {
        Color.clear
            .frame(width: capsuleSize.width, height: capsuleSize.height)
            .background {
                // Keep one glow alive so reversing a day swipe reverses its fade
                // from the current brightness rather than restarting its entrance.
                TodayDateGlow(isVisible: day == Day(now) && !calendarTransitionActive)
            }
    }

    /// The calendar, on the same glass as the day capsule it opens from. Choosing a day,
    /// tapping outside or pulling it down folds it back into the capsule.
    ///
    /// The calendar stays built while hidden: creating it took long enough on device to
    /// stall the opening frames. It's laid out at its own width whatever the glass's size,
    /// so the morph never makes it lay out again.
    private var calendarCard: some View {
        DayCalendar(selection: date, today: now, onDismiss: closeCalendar) { pickFromCalendar($0) }
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
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { closeCalendar() }
    }
    /// Floats above the open calendar rather than in it, so the calendar keeps its size. It rides
    /// the top of the glass as it grows and leaves as soon as it starts to fold.
    @ViewBuilder private var calendarTodayButton: some View {
        if pickingDate {
            Button { pickFromCalendar(Calendar.current.startOfDay(for: Date())) } label: {
                Text("Today")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectTransition(.materialize)
            // A zero-height frame on the glass's top edge, so the button sits wholly above it.
            .padding(.bottom, 10)
            .frame(height: 0, alignment: .bottom)
            .accessibilityLabel("Go to today")
        }
    }
    private func pickFromCalendar(_ picked: Date) {
        pickedFromCalendar = true
        navigate(to: picked)
        // Leave the new selection visible for a moment before folding away.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            closeCalendar()
        }
    }
    /// Reduce Motion swaps the glass's size at once; only the contents cross-fade.
    private var calendarAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)
    }
    private var dayNavigation: some View {
        HStack(spacing: 0) {
            Button {
                guard daySwipeInteraction.allowsDayNavigation else { return }
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
                            guard daySwipeInteraction.allowsDayNavigation else { return }
                            goToToday()
                        }
                )
                .onTapGesture {
                    guard daySwipeInteraction.allowsDayNavigation else { return }
                    openCalendar()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Choose a day")
                .accessibilityValue(relativeDateLabel + ", " + date.formatted(date: .complete, time: .omitted))
                .accessibilityHint("Tap or swipe up for the calendar, or hold for today")
                .accessibilityAction { openCalendar() }
                .accessibilityAction(named: "Go to today") { goToToday() }
            Button {
                guard daySwipeInteraction.allowsDayNavigation else { return }
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
        // Restart the picked day's relative label as the capsule returns, so it remains
        // visible after the calendar has folded.
        if pickedFromCalendar {
            pickedFromCalendar = false
            calendarPicks += 1
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
    private func closeFocus() {
        guard let focused, !focused.ending else { return }
        withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
            self.focused?.ending = true
        }
        if reduceMotion { finishInlineFocus(focused.token) }
    }

    private func finishInlineFocus(_ token: UUID) {
        guard focused?.token == token, focused?.ending == true else { return }
        focused = nil
    }

    private func inlineFocusPhase(on day: Day) -> InlineFocusPhase {
        guard let focused, focused.source == .day, focused.day == day else { return InlineFocusPhase() }
        return InlineFocusPhase(id: focused.id, ending: focused.ending, revision: focused.detailsRevision)
    }

    /// Today's page with the item in its focussed state.
    private func focusOnToday(_ item: PlanItem) {
        focusOnDay(item, on: Day(Date()))
    }
    /// Reminders can arrive before the scheduled day, or be opened on a later day.
    private func focusOnDay(_ item: PlanItem, on target: Day) {
        let editorWasOpen = editing != nil
        let pageChanges = persona != nil || search.isOpen || day != target
        focused = nil
        editing = nil
        Task { @MainActor in
            // Only what's in the way is waited for: a tap on a Live Activity should land at once.
            // Let a sheet finish closing before the day changes under it.
            if editorWasOpen { try? await Task.sleep(for: .milliseconds(450)) }
            if persona != nil { persona = nil }
            if search.isOpen { search.close(reduceMotion: reduceMotion) }
            navigate(to: target.date())
            // Another day's page can hold the same item (a range over several days).
            if pageChanges { try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 250)) }
            // A frame at a time, as the rows can take a moment when this opened the app.
            for _ in 0..<180 {
                if FocusedCardAnchor.focusCentred(item.id) { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
            editing = store.item(item.id) ?? item
        }
    }
    private func openOnItsDay(_ item: PlanItem) { openOnItsDay(item, on: item.day.date()) }
    private func openOnItsDay(_ item: PlanItem, on shownDay: Date) {
        editing = nil
        Task { @MainActor in
            // Let the sheet finish closing before the day changes under it.
            try? await Task.sleep(for: .milliseconds(450))
            if persona != nil { persona = nil }
            if search.isOpen { search.close(reduceMotion: reduceMotion) }
            navigate(to: shownDay)
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 450))
            editing = store.item(item.id) ?? item
        }
    }
    private func goToToday() {
        navigate(to: Calendar.current.startOfDay(for: Date()))
    }
    /// The filter the top buttons show and set: the search's while searching, a persona page's on
    /// one, otherwise the day's.
    private var shownFilter: DayFilter { search.isOpen ? searchFilter : persona != nil ? personaFilter : filter }
    /// The persona page's days, before any filter.
    private var personaDays: [PersonaDay] {
        persona.map { Planner.history(of: $0, in: store.items, now: now, repeatsThrough: personaHorizon) } ?? []
    }
    /// The list the filters count and narrow instead of a day: search's results, or a persona page.
    private var listedDays: [PersonaDay]? { search.isOpen ? searchResults : persona != nil ? personaDays : nil }
    /// The search's results, scoped to the chosen persona, before any filter.
    private var searchResults: [PersonaDay] {
        search.isOpen ? Planner.search(search.query, in: store.items, now: now, persona: persona, repeatsThrough: searchHorizon) : []
    }
    /// How many rows a filter keeps: of the search's results or the persona page, otherwise of the
    /// day. A filter is a property of each row, so it means the same for a list as for a day. A
    /// running range listed on two days of a persona page counts once.
    private func filterCount(_ value: DayFilter, in results: [PersonaDay]) -> Int {
        guard search.isOpen || persona != nil else {
            switch value {
            case .all: return 0
            case .review: return reviewItems.count
            case .reminders: return reminderItems.count
            case .deadlines: return deadlineItems.count
            }
        }
        return Set(results.flatMap { entry in entry.items.filter { matches($0, value, on: entry.day) }.map(\.id) }).count
    }
    /// The results the search shows: scoped to the persona, then narrowed by its filter.
    private var filteredSearchResults: [PersonaDay] {
        let results = searchResults
        guard searchFilter != .all else { return results }
        return results.compactMap { entry in
            let items = entry.items.filter { matches($0, searchFilter, on: entry.day) }
            return items.isEmpty ? nil : PersonaDay(day: entry.day, items: items)
        }
    }
    private func toggleFilter(_ value: DayFilter) {
        guard search.isOpen || persona != nil else { setFilter(filter == value ? .all : value); return }
        withAnimation(reviewAnimation) {
            if search.isOpen {
                searchFilter = searchFilter == value ? .all : value
            } else {
                personaFilter = personaFilter == value ? .all : value
            }
            if shownFilter != .all { panelFilter = shownFilter }
        }
    }
    private var filterButtons: some View {
        let results = listedDays ?? []
        let reminderCount = filterCount(.reminders, in: results)
        let reviewCount = filterCount(.review, in: results)
        let deadlineCount = filterCount(.deadlines, in: results)
        let reviewing = shownFilter == .review
        let showingReminders = shownFilter == .reminders
        let showingDeadlines = shownFilter == .deadlines
        let showReminders = showingReminders || reminderCount > 0
        let showReview = reviewing || reviewCount > 0
        let showDeadlines = showingDeadlines || deadlineCount > 0
        let scope = search.isOpen ? "results" : "items"
        let transition: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .trailing))
        return HStack(spacing: 10) {
            if showDeadlines {
                Button {
                    // A button fading out after a day change still takes taps; state is read live.
                    guard shownFilter == .deadlines || filterCount(.deadlines, in: listedDays ?? []) > 0 else { return }
                    toggleFilter(.deadlines)
                } label: {
                    filterIcon("flag.fill", tint: .red, count: deadlineCount, isActive: showingDeadlines)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingDeadlines ? "Show all \(scope)" : "Show \(deadlineCount) \(scope) with deadlines")
                .accessibilityValue(showingDeadlines ? "Deadline filter on" : "Deadline filter off")
                .accessibilityAddTraits(showingDeadlines ? .isSelected : [])
                .accessibilityHint(search.isOpen ? "Toggles results with an open deadline"
                                   : "Toggles unfinished items with a deadline, including deadlines on other days")
                .transition(transition)
            }
            if showReminders {
                Button {
                    guard shownFilter == .reminders || filterCount(.reminders, in: listedDays ?? []) > 0 else { return }
                    toggleFilter(.reminders)
                } label: {
                    filterIcon("alarm.fill", tint: .blue, count: reminderCount, isActive: showingReminders)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingReminders ? "Show all \(scope)" : "Show \(reminderCount) \(scope) with reminders")
                .accessibilityValue(showingReminders ? "Reminder filter on" : "Reminder filter off")
                .accessibilityAddTraits(showingReminders ? .isSelected : [])
                .accessibilityHint(search.isOpen ? "Toggles results with an upcoming reminder"
                                   : "Toggles unfinished items with an upcoming reminder, including reminders on other days")
                .transition(transition)
            }
            if showReview {
                Button {
                    guard shownFilter == .review || filterCount(.review, in: listedDays ?? []) > 0 else { return }
                    toggleFilter(.review)
                } label: {
                    filterIcon("exclamationmark.triangle.fill", tint: reviewTint, count: reviewCount, isActive: reviewing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reviewing ? "Show all \(scope)" : "Review \(reviewCount) \(scope)")
                .accessibilityValue(reviewing ? "Review filter on" : "Review filter off")
                .accessibilityAddTraits(reviewing ? .isSelected : [])
                .accessibilityHint(search.isOpen ? "Toggles results needing review"
                                   : persona != nil ? "Toggles items needing review" : "Toggles items needing review for this day")
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
        // Items from other days whose reminder or deadline falls on this day: mounted like every
        // row, but shown only under that filter, at that time.
        let visitors = Planner.visitingItems(on: day, in: store.items, now: now)
        let visitTimes = Dictionary(uniqueKeysWithValues: visitors.compactMap { item in
            item.visitTime(on: day, now: now).map { (item.id, Calendar.current.dateComponents([.hour, .minute], from: $0)) }
        })
        let filtered = (visible + moved + visitors).filter { matches($0, filter, on: day) }
        // Every row stays mounted and the filter only collapses the others. A row inserted when
        // a filter cleared had no earlier position, so it appeared at its final spot while the
        // rows around it were still sliding back, overlapping them.
        let shown = Set(filtered.map(\.id))
        // A carried item keeps its old time on its scheduled day; elsewhere it is untimed.
        let keepsTime = { (item: PlanItem) in item.minute != nil && (!item.isCarried(now: now) || item.day == day) }
        // A visitor sorts by when its reminder or deadline falls on this day.
        let sortMinute = { (item: PlanItem) in
            visitTimes[item.id].map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) } ?? item.minute
        }
        let order = { (a: PlanItem, b: PlanItem) in
            if sortMinute(a) != sortMinute(b) { return (sortMinute(a) ?? -1) < (sortMinute(b) ?? -1) }
            return a.createdAt < b.createdAt
        }
        // Explicit date ranges are scheduled for the full day. Once carried beyond their
        // range they become Anytime, just like a carried timed item.
        let isFullDay = { (item: PlanItem) in item.endDay != nil && item.appears(on: day) }
        let fullDayItems = (visible + moved).filter(isFullDay).sorted(by: order)
        let anyTimeItems = (visible + moved).filter { !keepsTime($0) && !isFullDay($0) }.sorted(by: order)
        let timedItems = ((visible + moved).filter(keepsTime) + visitors).sorted(by: order)
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
                .id(DayScrollTarget.top)
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
                if !fullDayItems.isEmpty || !timedItems.isEmpty {
                    sectionHeading("Scheduled")
                        .modifier(FilterCollapse(collapsed: !(fullDayItems + timedItems).contains { shown.contains($0.id) }, keepsSpaceInTimeView: !timedItems.isEmpty))
                        .transition(sectionRemoval)
                    if !fullDayItems.isEmpty {
                        scheduledSectionDivider("Full day")
                            .padding(.horizontal, 16)
                            .modifier(ModeSectionHeaderFade(collapsesInTimeView: true))
                            .modifier(FilterCollapse(collapsed: !fullDayItems.contains { shown.contains($0.id) }))
                            .transition(sectionRemoval)
                        anytimeItems(items: fullDayItems, shown: shown, day: day, filter: filter)
                            .padding(.horizontal, 16)
                            .modifier(FullDayTimelineSpacing(visible: !timedItems.isEmpty && fullDayItems.contains { shown.contains($0.id) }))
                            .transition(sectionRemoval)
                    }
                    if !timedItems.isEmpty {
                        scheduledItems(items: timedItems, shown: shown, day: day, filter: filter)
                            .padding(.horizontal, 16)
                            .transition(sectionRemoval)
                    }
                }
                SettingsLink(isEnabled: { daySwipeInteraction.allowsItemActions })
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                FilterScrollRoom(filtered: filter != .all)
            }
            .readableWidth()
            // One SwiftUI scroll surface resizes continuously with the rows.
            // A UIKit List cell used to resize separately and interrupt the morph.
            // The view-mode animation lives on the mode-reading views below.
            .animation(reviewAnimation, value: filter)
            .animation(filter == .all ? ItemStatusMotion.animation(reduceMotion: reduceMotion) : reviewAnimation,
                       value: filtered.map(\.id))
            .transaction { transaction in
                if reduceMotion && !ViewMode.crossFades(reduceMotion: true) { transaction.animation = nil }
            }
        }
        .scrollEdgeEffectHidden(true, for: .vertical)
        .modifier(PullsToSearch())
        .modifier(ScrollsToNowInTimeView(proxy: proxy))
        .modifier(ScrollsToFilteredItem(proxy: proxy, filter: filter.rawValue, animation: reviewAnimation,
                                        target: (anyTimeItems + fullDayItems).first { shown.contains($0.id) }.map { .anytime($0.id) }
                                            ?? timedItems.first { shown.contains($0.id) }.map { .scheduled($0.id) }))
        .modifier(TimelineOverflowScroll(proxy: proxy))
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
    /// Untimed rows for Anytime and Full day, without clock-axis placement.
    private func anytimeItems(items: [PlanItem], shown: Set<UUID>, day: Day, filter: DayFilter) -> some View {
        let contentKey = TimelineContentKey(items: items, sharedZones: store.cloud.sharedZones, day: day, order: items.map(\.id),
                                            markers: items.map { item in [DayFilter.review, .reminders, .deadlines].map { hasDot(item, $0, on: day) } },
                                            filter: filter.rawValue, showNow: false, timeNotes: [], typeSize: dynamicTypeSize, inlineFocus: inlineFocusPhase(on: day))
        return AnytimeLayout(contentKey: contentKey) {
            // The same rows as Scheduled, with the same pair of List and Time view copies and
            // modifiers; as plain rows they made each filter animation drop frames on a phone.
            ForEach(items) { item in
                ForEach([false, true], id: \.self) { timedVariant in
                    row(item, filter: filter, day: day, sharedSchedule: true, timeBelowTitle: timedVariant)
                        .modifier(FilterCollapse(collapsed: !shown.contains(item.id)))

                        .layoutValue(key: TimelineCollapsedKey.self, value: !shown.contains(item.id))
                        .modifier(ModeRowVariant(isTimed: timedVariant, compactSortPriority: 0))
                        .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
                        // A target for opening a filter; both copies sit in the same place.
                        .id(timedVariant ? AnyHashable("anytime-time-\(item.id)") : AnyHashable("anytime-\(item.id)"))
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
        // Drive the measured layout itself, including its first filter change.
        .animation(reviewAnimation, value: filter)
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: contentKey.markers)
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: items.map(\.isSettled))
        .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
    }

    /// All of the day's timed items; those not in `shown` are collapsed by the filter.
    private func scheduledItems(items: [PlanItem], shown: Set<UUID>, day: Day, filter: DayFilter) -> some View {
        let calendar = Calendar.current
        let beginning = calendar.startOfDay(for: day.date())
        let end = calendar.date(byAdding: .day, value: 1, to: beginning)!
        let entries = items.compactMap { item -> TimelineEntry? in
            func minute(_ date: Date) -> Double {
                if date < beginning { return 0 }
                if date >= end { return 1440 }
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
            func onDay(_ date: Date) -> Bool { date >= beginning && date < end }
            // A visitor from another day sits at its reminder or deadline here, without a track.
            if item.visits(day, now: now), let time = item.visitTime(on: day, now: now) {
                return TimelineEntry(id: item.id, minute: minute(time), endMinute: nil, complete: false,
                                     reminderMinutes: item.reminders.filter { $0 > now && onDay($0) }.map(minute),
                                     deadlineMinute: item.isDue(on: day) ? item.deadline.map(minute) : nil,
                                     visiting: true)
            }
            guard let start = item.start() else { return nil }
            // A carried entry is drawn as quietly as a finished item.
            let complete = item.isSettled || item.movedAway(from: day, now: now)
            return TimelineEntry(id: item.id, minute: minute(start), endMinute: item.end.map(minute), complete: complete,
                                 // Only an open item's reminders and deadline still mean something.
                                 reminderMinutes: complete ? [] : item.reminders.filter(onDay).map(minute),
                                 deadlineMinute: complete ? nil : item.deadline.flatMap { onDay($0) ? minute($0) : nil },
                                 review: matches(item, .review, on: day))
        }.sorted { $0.minute < $1.minute }
        let currentMinute: Double? = day == Day(now) ? Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)) : nil
        let firstMinute = min(entries.map(\.minute).min() ?? 360, currentMinute ?? 360)
        let startMinute = min(360, floor(firstMinute / 60) * 60)
        let lanes = TimelineEntry.durationLanes(for: entries)
        let isToday = day == Day(now)
        let scaleHeight = DayTimelineLayout.top * 2 + CGFloat(1440 - startMinute) * DayTimelineLayout.pointsPerMinute
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
        let contentKey = TimelineContentKey(items: items, sharedZones: store.cloud.sharedZones, day: day, order: compactItems.map(\.id),
                                            markers: items.map { item in [DayFilter.review, .reminders, .deadlines].map { hasDot(item, $0, on: day) } },
                                            filter: filter.rawValue, showNow: showNow,
                                            timeNotes: items.map { timeNote($0, day: day) != nil },
                                            typeSize: dynamicTypeSize, inlineFocus: inlineFocusPhase(on: day))
        let laneCount = (lanes.values.max() ?? 0) + 1
        let timeIndicatorWidth = DayTimelineLayout.gutter(laneCount: laneCount) - 8
        return ModeTimelineLayout(startMinute: startMinute, laneCount: laneCount,
                                  contentKey: contentKey) {
            if isToday, let first = past.first(where: { item in !inProgress.contains { $0.id == item.id } }) {
                let order = (compactOrder[first.id] ?? 0) - 1
                compactSectionDivider("Past")
                    .modifier(FilterCollapse(collapsed: !showNow))
                    .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
                    .layoutValue(key: TimelineCompactOrderKey.self, value: order)
                    .accessibilitySortPriority(-Double(order))
            }
            if !inProgress.isEmpty {
                compactSectionDivider("In progress")
                    .modifier(FilterCollapse(collapsed: !showNow))
                    .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
                    .layoutValue(key: TimelineCompactOrderKey.self, value: activeTop)
                    .accessibilitySortPriority(-Double(activeTop))
            }
            if isToday, let first = upcoming.first {
                let order = (compactOrder[first.id] ?? 0) - 1
                compactSectionDivider("Upcoming")
                    .modifier(FilterCollapse(collapsed: !showNow))
                    .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
                    .layoutValue(key: TimelineCompactOrderKey.self, value: order)
                    .accessibilitySortPriority(-Double(order))
            }
            ForEach(items) { item in
                ForEach([false, true], id: \.self) { timedVariant in
                    row(item, filter: filter, day: day, sharedSchedule: true, timeBelowTitle: timedVariant)
                        .modifier(TimelineOverflowReport(id: item.id, day: day, minute: entries.first(where: { $0.id == item.id })?.minute ?? 0,
                                                                         isTimed: timedVariant, shown: shown.contains(item.id)))
                        // Each copy has its own id, so opening a filter scrolls to the one the mode shows.
                        .id(timedVariant ? AnyHashable(item.id) : AnyHashable("list-\(item.id)"))
                        .modifier(FilterCollapse(collapsed: !shown.contains(item.id)))

                        .layoutValue(key: TimelineCollapsedKey.self, value: !shown.contains(item.id))
                        .modifier(ModeRowVariant(isTimed: timedVariant,
                                                 compactSortPriority: showNow ? -Double(compactOrder[item.id] ?? 0) : 0))
                        .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
                        .layoutValue(key: TimelineCompactOrderKey.self, value: compactOrder[item.id] ?? 0)
                        .layoutValue(key: TimelineTimedVariantKey.self, value: timedVariant)
                        .layoutValue(key: TimelineMinuteKey.self, value: entries.first(where: { $0.id == item.id })?.minute ?? 0)

                }
                if let start = item.start() {
                    // Keep one visible time label across both modes. The rows
                    // reserve its measured space but never crossfade its text, also
                    // when a filter opens a panel below the row.
                    ModeScheduleLabel(label: scheduleLabel(item, start: start, day: day))
                        .geometryGroup()
                        .multilineTextAlignment(.trailing)
                        .modifier(ModeScheduleColumn(width: scheduleColumnWidth))
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(SharedLabelVisibility(shown: shown.contains(item.id)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .layoutValue(key: TimelineSharedTimeInsetKey.self, value: ItemCard.trailingInset)
                }
                if let entry = entries.first(where: { $0.id == item.id }) {
                    TimelineConnector(complete: entry.complete, focused: focused?.id == item.id && focused?.day == day && focused?.ending == false)
                        .opacity(shown.contains(item.id) && !entry.visiting ? 1 : 0)
                        .modifier(ModeFade(visibleInTimeView: true))
                        .layoutValue(key: TimelineConnectorLaneKey.self, value: lanes[item.id] ?? 0)
                        .layoutValue(key: TimelineMinuteKey.self, value: entry.minute)
                    // The reminder and deadline filters join their dots on the track to the
                    // item's card, the way its own connector joins its start. They stay laid out
                    // and only fade, so they move with the rows when a filter opens or closes;
                    // inserted and removed, a fading one stayed behind while the rows moved.
                    let marks: [(minute: Double, color: Color, filter: DayFilter)] =
                        entry.reminderMinutes.map { ($0, Color.blue, .reminders) }
                        + (entry.deadlineMinute.map { [($0, Color.red, .deadlines)] } ?? [])
                    ForEach(marks.indices, id: \.self) { index in
                        TimelineMarkConnector(color: marks[index].color, rising: marks[index].minute > entry.minute)
                            .opacity(filter == marks[index].filter && shown.contains(item.id) ? 1 : 0)
                            .modifier(ModeFade(visibleInTimeView: true))
                            .layoutValue(key: TimelineConnectorLaneKey.self, value: lanes[item.id] ?? 0)
                            .layoutValue(key: TimelineMarkKey.self, value: true)
                            .layoutValue(key: TimelineMinuteKey.self, value: marks[index].minute)
                    }
                }
            }
        }
        .coordinateSpace(name: TimelineOverflow.space)
        // Blend the row variants with each other before compositing over the page.
        .compositingGroup()
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                TimelineOverflowAnchor()
                // Fill the clock-and-track gutter. Cards can shift vertically to make
                // room, so elapsed time stops before them.
                if let currentMinute, currentMinute >= startMinute {
                    Rectangle()
                        .fill(TimelineNowMarker.passedWash)
                        .frame(width: timeIndicatorWidth,
                               height: DayTimelineLayout.top + CGFloat(currentMinute - startMinute) * DayTimelineLayout.pointsPerMinute)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // Given the passed hour and the hour label the current time covers rather than the
                // minute, so the hour labels only redraw a few times an hour.
                TimelineScale(startMinute: startMinute, date: beginning,
                              passedMinute: currentMinute.map { floor($0 / 60) * 60 },
                              coveredHour: currentMinute.flatMap { minute in
                                  let nearest = (minute / 60).rounded()
                                  return abs(nearest * 60 - minute) < TimelineNowMarker.coverMinutes ? Int(nearest) : nil
                              })
                    .equatable()
                    .frame(height: scaleHeight)
                // Every item's track stays in place and fades with the filter, so tracks a filter
                // hides or shows crossfade with the rows; the review filter turns its items' orange.
                ForEach(entries.filter { !$0.visiting }, id: \.id) { entry in
                    TimelineTrack(entry: entry, lane: lanes[entry.id] ?? 0, startMinute: startMinute,
                                  orange: filter == .review && entry.review, focused: focused?.id == entry.id && focused?.day == day && focused?.ending == false)
                        .opacity(filter == .all || shown.contains(entry.id) ? 1 : 0)
                }
                // The minute tick only moves this small marker, never redrawing the tall scale.
                if let currentMinute, currentMinute >= startMinute {
                    // Laid out rather than offset, and a view of its own below a spacer: scrolling
                    // to an offset or padded view finds the top of the timeline instead.
                    VStack(spacing: 0) {
                        Color.clear.frame(width: 1, height: DayTimelineLayout.top + CGFloat(currentMinute - startMinute) * DayTimelineLayout.pointsPerMinute)
                        Color.clear.frame(width: 1, height: 1).id(TimelineNowMarker.anchorID)
                    }
                    .accessibilityHidden(true)
                    TimelineNowMarker(time: now)
                        // End beside the last track, leaving a gap before the cards.
                        .frame(width: timeIndicatorWidth)
                        .offset(y: DayTimelineLayout.top + CGFloat(currentMinute - startMinute) * DayTimelineLayout.pointsPerMinute
                                - TimelineNowMarker.height / 2)
                }
            }
            .modifier(ModeFade(visibleInTimeView: true))
            // The page is hosted, so the filter's own transaction doesn't reach in here: without
            // this the tracks and the review filter's orange swapped in one frame.
            .animation(reviewAnimation, value: filter)
        }
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: active.map(\.id))
        .accessibilityElement(children: .contain)
        // Drive the measured layout itself, including its first filter change.
        .animation(reviewAnimation, value: filter)
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: contentKey.markers)
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: items.map(\.isSettled))
        .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: inlineFocusPhase(on: day))
    }
    private func compactSectionDivider(_ title: String) -> some View {
        scheduledSectionDivider(title)
            .modifier(ModeSectionHeaderFade())
            .layoutValue(key: TimelineMarkerKey.self, value: true)
    }
    private func scheduledSectionDivider(_ title: String) -> some View {
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
        .allowsHitTesting(false)
    }
    private func row(_ item: PlanItem, filter: DayFilter, day: Day, sharedSchedule: Bool = false, source: FocusSource = .day,
                     timeBelowTitle: Bool = false) -> some View {
        // On the days an item was carried on from, it stays in its place as a quiet entry pointing
        // to where it went. It is the same item as on its live day, so completing or opening it
        // here acts on that copy; it isn't counted, reviewed or reminded about here, but keeps an
        // orange dot while unfinished so the earlier day still shows it was left open.
        let carried = carriedDestination(item, from: day)
        let originDate = item.day.date()
        let originStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        let carriedFrom = carried == nil && item.isCarried(now: now) && day == item.liveDay(now: now)
            ? originDate.formatted(Calendar.current.isDate(originDate, equalTo: now, toGranularity: .year) ? originStyle : originStyle.year())
            : nil
        let review = hasDot(item, .review, on: day)
        let reminder = hasDot(item, .reminders, on: day)
        let deadline = hasDot(item, .deadlines, on: day)
        let visiting = item.visits(day, now: now)
        // A carried entry keeps its time on its scheduled day; elsewhere a carried item is untimed.
        let showsTime = carried != nil ? day == item.day : !item.isCarried(now: now)
        let isFocusSource = focused?.id == item.id && focused?.day == day && focused?.source == source
        // Both measured endpoints include the details, like filter panels. Anytime measures
        // its List copy even in Time view, so expanding only the visible copy leaves no space.
        let inlineExpanded = isFocusSource && focused?.ending == false
        let inlineToken = isFocusSource && focused?.timeBelowTitle == timeBelowTitle ? focused?.token : nil
        let markerInset: CGFloat = filter != .all ? 0 : (review ? 14 : 0) + (reminder ? 14 : 0) + (deadline ? 14 : 0)
        let canUseHeader = { !FocusedCardAnchor.isHolding }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                CompletionButton(item: item, day: day, isEnabled: { daySwipeInteraction.allowsItemActions && canUseHeader() },
                                 keepsCarriedArrow: carried != nil) {
                    Group {
                        if carried != nil {
                            OutlinedCompletionCircle(glyph: .chevron)
                                .foregroundStyle(.tertiary)
                        } else {
                            // The outline stays mounted; only the elapsed arc draws/retracts.
                            ProgressCircle(progress: timeProgress(item) ?? 0, settled: item.isSettled)
                        }
                    }
                }
                .accessibilityValue([carried.map { "Carried to \($0)" }, carriedFrom.map { "Carried from \($0)" }, item.isCancelled ? "Cancelled" : nil,
                                     carried == nil ? timeProgress(item).flatMap { $0 >= 1 ? "Time passed" : $0 > 0 ? "\(Int($0 * 100))% of the time passed" : nil } : nil,
                                     review ? (item.suggestionDismissed ? "Left open" : "Needs review") : nil, reminder ? "Reminder set" : nil,
                                     deadline ? item.deadline.map { "Deadline \($0.formatted(date: .abbreviated, time: .shortened))" } : nil].compactMap { $0 }.joined(separator: ", "))
                Button {
                    guard daySwipeInteraction.allowsItemActions, canUseHeader() else { return }
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
                            if let carriedFrom {
                                Text("Carried from \(carriedFrom)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            if let range = store.dateRange(of: item) {
                                Text(range.lowerBound.date().formatted(date: .abbreviated, time: .omitted) + " – " + range.upperBound.date().formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.tertiary)
                            } else if let endDay = item.endDay, endDay > item.day {
                                Text(item.day.date().formatted(date: .abbreviated, time: .omitted) + " – " + endDay.date().formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            if visiting, item.start() == nil {
                                // A timed visitor's time already names its day.
                                Text("Anytime, \(item.day.date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            if timeBelowTitle, let start = item.start(), showsTime {
                                // Time view has room beside the time for its note.
                                let inline = !dynamicTypeSize.isAccessibilitySize
                                scheduleLabel(item, start: start, day: day, inline: inline)
                                    .frame(width: inline ? nil : scheduleColumnWidth, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .modifier(SharedScheduleVisibility(shared: sharedSchedule))
                                    .accessibilityHidden(sharedSchedule)
                                    .alignmentGuide(.scheduleLeading) { $0[.leading] }
                                    .alignmentGuide(.scheduleTop) { $0[.top] }
                            }
                            if !item.people.isEmpty || !item.locations.isEmpty || store.cloud.isShared(item) {
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
                    .accessibilityValue([carried.map { "Carried to \($0)" }, carriedFrom.map { "Carried from \($0)" },
                                         sharedSchedule && showsTime ? item.start().map { timeLabel(item, start: $0, day: day) } : nil,
                                         timeNote(item, day: day, width: .wide),
                                         // A carried entry's circle doesn't show a tick, so say it here.
                                         item.isCancelled ? "Cancelled" : carried != nil && item.isComplete ? "Completed" : nil].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint((review && !item.suggestionDismissed ? "Needs review. " : "") + (reminder ? "Reminder set. " : "") + "Open details and edit")
                    .accessibilityAction(named: item.isCancelled ? "Uncancel" : "Cancel") { setCancelled(item, !item.isCancelled, on: day) }
            }
            .overlay(alignment: .trailing) {
                rowMarkers(item, filter: filter, day: day).offset(x: markerInset)
            }
            // Isolate only header content; the filter panel must keep its own
            // expansion geometry rather than joining the dot/time motion group.
            .geometryGroup()
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
                // Its blue, red or orange line sits 3 points under the row's last line, as the
                // row's grey lines do under each other, rather than below the row's 8-point
                // padding. Outside the clip, which would otherwise cut off its top.
                .padding(.top, showsPanel ? 3 - 8 : 0)
                .opacity(showsPanel ? 1 : 0)
                .allowsHitTesting(showsPanel)
                .accessibilityHidden(!showsPanel)
            InlineFocusedDetails(item: item, day: day, expanded: inlineExpanded, token: inlineToken,
                                 close: closeFocus, collapsed: finishInlineFocus,
                                 contentChanged: {
                if isFocusSource { focused?.detailsRevision += 1 }
            }, heightChanged: { height in
                guard inlineExpanded, focused?.ending == false, focused?.token == inlineToken else { return }
                FocusedCardAnchor.revealInline(item.id, extraHeight: max(0, height + InlineFocusedDetails.topInset), animated: !reduceMotion)
            })
        }
        // Dots show only in the full day; a filtered row's panel already says why it is there.
        .padding(.trailing, markerInset)
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: [item.isComplete, item.isCancelled, review, reminder, deadline])
        // Every item has the same faint fill: open, ticked, cancelled or carried. An item from
        // another day, here for its reminder or deadline, has a dashed outline instead.
        .modifier(ItemCard(dashed: visiting))
        .itemFocus(item.id, day: day, isEnabled: {
            guard daySwipeInteraction.allowsItemActions,
                  focused?.ending != false || focused?.id != item.id || focused?.day != day
                    || focused?.source != source else { return false }
            // The day and persona rows stay mounted behind search. Only the visible surface
            // can supply a marker, including when a notification asks to focus an item.
            switch source {
            case .day: return !search.isOpen && persona == nil
            case .persona: return !search.isOpen && persona != nil
            case .search: return search.isOpen
            }
        }) {
            withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
                focused = Focused(id: item.id, day: day, source: source, filter: filter,
                                  timeBelowTitle: timeBelowTitle)
            }
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
        let review = hasDot(item, .review, on: day)
        let reminder = hasDot(item, .reminders, on: day)
        let deadline = hasDot(item, .deadlines, on: day)
        return HStack(spacing: 0) {
            marker(reviewTint, visible: review)
            marker(.blue, visible: reminder)
                .padding(.leading, reminder && review ? 8 : 0)
            marker(.red, visible: deadline)
                .padding(.leading, deadline && (review || reminder) ? 8 : 0)
        }
        .opacity(filter == .all ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: filter)
        .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: [review, reminder, deadline])
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
    private func marker(_ color: Color, visible: Bool) -> some View {
        // Mounted even when hidden: removing a conditional dot could drop its exit fade
        // when the hosted page replaced its content during completion.
        Circle().fill(color).frame(width: 6, height: 6)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: visible)
            .frame(width: visible ? 6 : 0, alignment: .trailing)
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
            if store.cloud.isShared(item) {
                if !item.people.isEmpty || !item.locations.isEmpty {
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 2, height: 2)
                        .accessibilityHidden(true)
                }
                Text("Shared").layoutPriority(1)
            }
        }
        // The size of every small line in a row: carried, time, and the filters' blue, red and orange.
        .font(.caption).foregroundStyle(.tertiary)
        .lineLimit(1).truncationMode(.tail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            item.people.isEmpty ? nil : "People: " + item.people.joined(separator: ", "),
            item.locations.isEmpty ? nil : "Locations: " + item.locations.joined(separator: ", "),
            store.cloud.isShared(item) ? "Shared" : nil
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
    // Filter timing is independent of the focussed card's expansion implementation.
    private var reviewAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.5) }
    private func setCancelled(_ item: PlanItem, _ cancelled: Bool, on day: Day) {
        guard daySwipeInteraction.allowsItemActions else { return }
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(500)) }
        withAnimation(ItemStatusMotion.animation(reduceMotion: reduceMotion)) { store.setCancelled(item, cancelled, on: day) }
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
            message = "Reminder " + time.formatted(date: Day(time) == day ? .omitted : .abbreviated, time: .shortened)
                + (item.reminders.count > 1 ? " · \(item.reminders.count) reminders" : "")
        } else if deadline, let due = item.deadline {
            // The reminder panel's format: a custom pattern is built on first use, which stalled the
            // filter's opening animation the first time.
            let when = due.formatted(date: Day(due) == day ? .omitted : .abbreviated, time: .shortened)
            message = due <= now ? "Deadline passed · \(when)" : "Deadline \(when)"
        } else if let carried = carriedDestination(item, from: day) {
            message = "Unfinished, carried to \(carried)"
        } else {
            message = item.endDay != nil ? "The scheduled days have ended" : item.end != nil ? "This time has ended" : "The scheduled time has passed"
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
        // Replace a filter’s contents atomically inside the persistent reveal frame.
        // Reusing its symbols animated deadline glyphs over review labels on first opening.
        .id(filter)
        .transition(.identity)
    }
    private func itemTitle(_ item: PlanItem, isCarriedEntry: Bool = false) -> some View {
        Text(item.title).font(.body.weight(.medium))
            .settledTitleStyle(item, isCarriedEntry: isCarriedEntry)
    }
    private func scheduleLabel(_ item: PlanItem, start: Date, day: Day, inline: Bool = false) -> ScheduleLabel {
        ScheduleLabel(time: timeLabel(item, start: start, day: day), note: timeNote(item, day: day), inline: inline)
    }
    // Today only: how long an item in progress has left, or how soon an upcoming one starts.
    // Ticking an item off early keeps the note; cancelling drops it.
    private func timeNote(_ item: PlanItem, day: Day, width: Duration.UnitsFormatStyle.UnitWidth = .narrow) -> String? {
        guard day == Day(now), !item.isCancelled, let start = item.start() else { return nil }
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
            .accessibilityLabel(symbol == "alarm" || symbol == "flag" ? message : "Warning: " + message)
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
final class FrameRateBoost: NSObject {
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

/// Anytime uses the same compact row measurements and filter collapse in both modes.
private struct AnytimeLayout<Content: View>: View {
    let contentKey: TimelineContentKey
    @ViewBuilder let content: Content

    var body: some View {
        DayTimelineLayout(startMinute: 0, laneCount: 1, contentKey: contentKey, compactOnly: true, progress: 0) { content }
    }
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
                                       progress: mode.showingTime ? 1 : 0, reservesTimeHeight: mode.showingTime) { content }
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
            // Switch the visible endpoint copy immediately; animate its position rather
            // than crossfading opaque cards and exposing the now line beneath them.
            .animation(nil) { $0.opacity(active ? 1 : 0) }
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .accessibilitySortPriority(mode.showingTime ? 0 : compactSortPriority)
    }
}

/// Brings the current time into view whenever Time view opens on today, and when today's
/// page appears in Time view (on launch, or built as a neighbour before it's swiped to).
private struct ScrollsToNowInTimeView: ViewModifier {
    let proxy: ScrollViewProxy
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
        .onAppear {
            guard mode.showingTime else { return }
            // After the first layout, which has to place the marker before it can be scrolled to.
            Task { @MainActor in proxy.scrollTo(TimelineNowMarker.anchorID, anchor: .center) }
        }
        .onChange(of: mode.showingTime) { _, showingTime in
            guard showingTime else { return }
            // Alongside the rows' move, so the timeline arrives already showing now. A moment
            // later, once the scroll view has the content's Time view height: issued in the same
            // update as the switch, or on the next run loop, the scroll was dropped whenever List
            // view had been scrolled down (it stayed where List view had been).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(ViewMode.animation(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(TimelineNowMarker.anchorID, anchor: .center)
                }
            }
        }
    }
}

private enum DayScrollTarget: Hashable { case top }

/// Native scroll targets participate in the same transaction as the filter layout.
private struct ScrollsToFilteredItem: ViewModifier {
    enum Target: Equatable { case anytime(UUID), scheduled(UUID) }
    let proxy: ScrollViewProxy
    /// `DayFilter`'s raw value; 0 is all.
    let filter: Int
    let animation: Animation?
    let target: Target?
    @Environment(ViewMode.self) private var mode

    func body(content: Content) -> some View {
        content.onChange(of: filter) { _, current in
            // List’s collapsing rows already bring the first match up.
            guard mode.showingTime else { return }
            let id: AnyHashable
            if current == 0 {
                id = AnyHashable(DayScrollTarget.top)
            } else {
                guard let target else { return }
                switch target {
                case .anytime(let itemID): id = AnyHashable("anytime-time-\(itemID)")
                case .scheduled(let itemID): id = AnyHashable(itemID)
                }
            }
            withAnimation(animation) { proxy.scrollTo(id, anchor: .top) }
        }
    }
}

/// Allow even a late final item to reach the top, without adding anything to each row.
private struct FilterScrollRoom: View {
    let filtered: Bool
    @Environment(ViewMode.self) private var mode

    var body: some View {
        Color.clear
            .containerRelativeFrame(.vertical) { height, _ in filtered && mode.showingTime ? height : 0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Keep UIKit's month layout and intrinsic sizing inside the dock's animated glass.
/// Multi-date selection reports taps on a highlighted day too, allowing that tap to
/// close the calendar. The viewed date is a blue circle; today is UIKit's own blue number.
/// (Adding today to the selection drew both as the same circle.)
private struct DayCalendar: UIViewRepresentable {
    let selection: Date
    let today: Date
    let onDismiss: () -> Void
    let onPick: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onDismiss: onDismiss) }
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
        // Keep dismissal in UIKit so a SwiftUI ancestor gesture cannot consume date taps.
        let pull = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pulled(_:)))
        pull.cancelsTouchesInView = false
        pull.delaysTouchesBegan = false
        pull.delaysTouchesEnded = false
        pull.delegate = context.coordinator
        view.addGestureRecognizer(pull)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onDismiss = onDismiss
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

    final class Coordinator: NSObject, UICalendarSelectionMultiDateDelegate, UIGestureRecognizerDelegate {
        var onPick: (Date) -> Void
        var onDismiss: () -> Void
        weak var selection: UICalendarSelectionMultiDate?
        var day: Day?
        var today: Day?
        init(onPick: @escaping (Date) -> Void, onDismiss: @escaping () -> Void) {
            self.onPick = onPick; self.onDismiss = onDismiss
        }
        @objc func pulled(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, gesture.translation(in: gesture.view).y > 50 else { return }
            onDismiss()
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > abs(velocity.x)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

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

/// Which Time view rows lie beyond the part of the page between the top controls and the
/// dock, for the small counts at its edges. Rows only write here when they cross an edge.
/// The counts live outside the day page: drawn over its scroll view, a tap on them while the
/// page was still moving only stopped the scroll.
@Observable
private final class TimelineOverflow {
    enum Edge { case above, below }
    private struct Key: Hashable { let day: Day; let id: UUID }
    private var edges: [Key: Edge] = [:]
    @ObservationIgnored private var minutes: [Key: Double] = [:]
    /// Each row's middle on the timeline, measured: overlapping cards are pushed down past their
    /// time, so the minute alone doesn't say where a card is.
    @ObservationIgnored private var centres: [Key: CGFloat] = [:]
    /// How far past the page's content margins rows stay in sight: to the glass of the top
    /// controls and of the dock.
    @ObservationIgnored var reach = EdgeInsets()
    /// The day on screen; a page that slid aside as a neighbour may still have rows listed.
    /// A new day drops the last target: the page that takes the tracker over saw it as a new
    /// request and jumped to where the previous day's row had been.
    var day = Day(Date()) { didSet { if day != oldValue { target = nil; readyTarget = nil } } }
    /// Where an indicator's tap scrolls to, carried out by the page, which owns the scroll view:
    /// the middle of the nearest hidden row on the timeline, and a count so a second tap on the
    /// same row still asks again.
    struct Target: Equatable { let y: CGFloat; let request: Int }
    private(set) var target: Target?
    /// Published by the anchor after layout, so a request is never consumed before it exists.
    private(set) var readyTarget: Target?
    func markTargetReady(_ target: Target) {
        guard self.target == target else { return }
        readyTarget = target
    }
    /// Requests so far, and the last one a page carried out, so a page that gains the tracker
    /// later doesn't carry it out again.
    @ObservationIgnored private var requests = 0
    @ObservationIgnored var handled = 0
    /// The view at the target that the page scrolls to. A plain view laid out at that point:
    /// asked for a row itself, the scroll found it where List view would place it, at the top
    /// of the timeline, so a tap only worked when the two happened to be close.
    static func anchorID(for target: Target) -> String { "timeline-overflow-target-\(target.request)" }
    static let space = "timeline"

    func set(_ edge: Edge?, for id: UUID, on day: Day, minute: Double, centre: CGFloat? = nil) {
        let key = Key(day: day, id: id)
        minutes[key] = minute
        // The count must never advertise a row until its scroll position is available.
        if let centre { centres[key] = centre }
        if edges[key] != edge { edges[key] = edge }
    }
    func count(_ edge: Edge) -> Int { edges.filter { $0.key.day == day && $0.value == edge }.count }
    /// Scrolls to the hidden row closest to the visible part: the lowest above, the highest below.
    func scroll(to edge: Edge) {
        let keys = edges.filter { $0.key.day == day && $0.value == edge }.map(\.key)
        let place = { (key: Key) in self.centres[key] ?? CGFloat(self.minutes[key] ?? 0) }
        guard let key = edge == .above ? keys.max(by: { place($0) < place($1) }) : keys.min(by: { place($0) < place($1) }),
              let y = centres[key] else { return }
        requests += 1
        target = Target(y: y, request: requests)
    }
}

/// The plain view an indicator's tap scrolls to, behind the timeline's rows.
private struct TimelineOverflowAnchor: View {
    @Environment(TimelineOverflow.self) private var overflow: TimelineOverflow?

    var body: some View {
        if let target = overflow?.target {
            VStack(spacing: 0) {
                Color.clear.frame(width: 1, height: max(0, target.y))
                Color.clear.frame(width: 1, height: 1)
                    .id(TimelineOverflow.anchorID(for: target))
                    .onGeometryChange(for: Int.self) { _ in target.request } action: { _ in
                        overflow?.markTargetReady(target)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Reports whether a Time view row lies wholly above or below the visible part of the page.
/// Only the day on screen has the tracker in its environment.
private struct TimelineOverflowReport: ViewModifier {
    let id: UUID
    let day: Day
    let minute: Double
    let isTimed: Bool
    let shown: Bool
    @Environment(ViewMode.self) private var mode
    @Environment(TimelineOverflow.self) private var overflow: TimelineOverflow?
    private struct Position: Equatable {
        let edge: TimelineOverflow.Edge?
        let centre: CGFloat
    }
    // Updating measured coordinates must not invalidate the row on every animation frame.
    private final class Measurement { var position: Position? }
    @State private var measurement = Measurement()

    func body(content: Content) -> some View {
        let active = isTimed && shown && mode.showingTime
        content
            // One geometry report supplies both visibility and target position. Separate
            // callbacks allowed the pill's count to change before its new target was ready.
            .onGeometryChange(for: Position.self) { proxy in
                let centre = proxy.frame(in: .named(TimelineOverflow.space)).midY
                guard let overflow, let page = proxy.bounds(of: .scrollView) else {
                    return Position(edge: nil, centre: centre)
                }
                let edge: TimelineOverflow.Edge?
                if proxy.size.height <= page.minY - overflow.reach.top { edge = .above }
                else if page.maxY + overflow.reach.bottom <= 0 { edge = .below }
                else { edge = nil }
                return Position(edge: edge, centre: centre)
            } action: { position in
                measurement.position = position
                if active {
                    overflow?.set(position.edge, for: id, on: day, minute: minute, centre: position.centre)
                }
            }
            // Also publish when the row becomes visible or a cached page gains the tracker.
            .onChange(of: overflow.map { _ in active }, initial: true) { _, tracking in
                let position = tracking == true ? measurement.position : nil
                overflow?.set(position?.edge, for: id, on: day, minute: minute, centre: position?.centre)
            }
            .onDisappear { overflow?.set(nil, for: id, on: day, minute: minute) }
    }
}

/// Carries out an indicator's scroll request on the page's own scroll view.
private struct TimelineOverflowScroll: ViewModifier {
    let proxy: ScrollViewProxy
    @Environment(TimelineOverflow.self) private var overflow: TimelineOverflow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: overflow?.readyTarget) { _, target in
            guard let target, let overflow, overflow.target == target,
                  target.request > overflow.handled else { return }
            // A newer tap cancels the older request, and every request has its own laid-out anchor.
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                proxy.scrollTo(TimelineOverflow.anchorID(for: target), anchor: .center)
            }
            overflow.handled = target.request
        }
    }
}

/// The dock's glass ends 12 points above its safe-area anchor. Lower it towards a
/// 24-point screen-edge margin, without raising it on screens with a small bottom inset.
enum DayDockLayout {
    static func lowering(for bottomSafeArea: CGFloat) -> CGFloat {
        max(0, bottomSafeArea - 12)
    }

    static func contentInset(for bottomSafeArea: CGFloat) -> CGFloat {
        bottomSafeArea + 94 - lowering(for: bottomSafeArea)
    }

    /// How far above the screen's bottom the dock's glass starts.
    static func glassTop(for bottomSafeArea: CGFloat) -> CGFloat {
        contentInset(for: bottomSafeArea) - 26
    }
}

/// Small glass counts at the top and bottom of Time view for scheduled items scrolled out of
/// sight; tapping one brings the nearest of them into view.
private struct TimelineOverflowIndicators: View {
    let overflow: TimelineOverflow
    let insets: EdgeInsets
    let date: Date
    let relativeDateLabel: String
    let calendarPicks: Int
    let calendarIsOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingRelativeDate = true
    @State private var relativeDatePillHeight: CGFloat = 20
    @State private var lastEarlierCount = 1
    @State private var lastLaterCount = 1
    private var showsRelativeDate: Bool { showingRelativeDate && !calendarIsOpen }
    private var pillAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }
    private struct RelativeDateShowing: Equatable {
        let date: Date
        let calendarPicks: Int
        let calendarIsOpen: Bool
    }
    /// How far the counts sit from the glass of the top controls and the dock.
    static let gap: CGFloat = 6

    var body: some View {
        // What's in sight runs between the glass of the top controls, which ends 10 points above
        // the bar's edge, and the glass of the dock, which starts 26 points into its 94 (its top
        // padding and the room above the capsule).
        let top = insets.top - 10
        let bottom = DayDockLayout.contentInset(for: insets.bottom) - 26
        VStack {
            indicator(.above)
            Spacer(minLength: 0)
            indicator(.below)
                // Move the rendered pill, leaving the list and the earlier count's layout alone.
                .offset(y: showsRelativeDate ? -(relativeDatePillHeight + Self.gap) : 0)
        }
        .overlay(alignment: .bottom) {
            // Keep the glass alive: inserting and removing it made the later pill move on
            // a different schedule from the material's appearance and disappearance.
            Text(relativeDateLabel)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { relativeDatePillHeight = $0 }
                .glassEffect(.regular, in: .capsule)
                .modifier(PillVisibility(isVisible: showsRelativeDate, reduceMotion: reduceMotion, animation: pillAnimation))
                .contentTransition(.opacity)
                .animation(pillAnimation, value: relativeDateLabel)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(pillAnimation, value: showsRelativeDate)
        .padding(.top, top + Self.gap).padding(.bottom, bottom + Self.gap)
        .ignoresSafeArea(.container, edges: .vertical)
        // Past the page's margins, which are the bar and the whole dock. Counting from the page's
        // bounds plus the margins again, a row still in plain view counted as out of sight.
        .onAppear { overflow.reach = EdgeInsets(top: 10, leading: 0, bottom: 26, trailing: 0) }
        // Only these small overlays observe the timer; it never rebuilds the pager or day list.
        .task(id: RelativeDateShowing(date: date, calendarPicks: calendarPicks, calendarIsOpen: calendarIsOpen)) {
            guard !calendarIsOpen else { showingRelativeDate = false; return }
            showingRelativeDate = true
            do {
                try await Task.sleep(for: .seconds(1.5))
                try Task.checkCancellation()
                showingRelativeDate = false
            } catch { /* A new selection restarts the display time. */ }
        }
    }
    private func indicator(_ edge: TimelineOverflow.Edge) -> some View {
        let count = overflow.count(edge)
        // The pill remains rendered during its exit animation; keep its last positive label.
        let displayedCount = count > 0 ? count : (edge == .above ? lastEarlierCount : lastLaterCount)
        let noun = displayedCount == 1 ? "item" : "items"
        return Button {
            overflow.scroll(to: edge)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: edge == .above ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                Text(edge == .above ? "\(displayedCount) earlier" : "\(displayedCount) later")
                    .font(.caption.weight(.medium)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        // Counts briefly reset while the next page reports its visible rows. Retain the
        // material through that hand-off rather than destroying and rebuilding the glass.
        .modifier(PillVisibility(isVisible: count > 0, reduceMotion: reduceMotion, animation: pillAnimation,
                                 hiddenOffset: edge == .above ? -4 : 4))
        .contentTransition(.opacity)
        .allowsHitTesting(count > 0)
        .accessibilityHidden(count == 0)
        .accessibilityLabel(edge == .above ? "\(displayedCount) earlier \(noun) above" : "\(displayedCount) later \(noun) below")
        .accessibilityHint("Scrolls to the nearest one")
        .animation(pillAnimation, value: count)
        .onChange(of: count, initial: true) { _, count in
            guard count > 0 else { return }
            if edge == .above { lastEarlierCount = count }
            else { lastLaterCount = count }
        }
    }

    /// Every dock pill enters and leaves with the same fade, travel and timing.
    private struct PillVisibility: ViewModifier {
        let isVisible: Bool
        let reduceMotion: Bool
        let animation: Animation?
        var hiddenOffset: CGFloat = 4

        func body(content: Content) -> some View {
            content
                .compositingGroup()
                .opacity(isVisible ? 1 : 0)
                .offset(y: isVisible || reduceMotion ? 0 : hiddenOffset)
                .animation(animation, value: isVisible)
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

/// Separate full-day cards from the clock scale without changing the compact list spacing.
private struct FullDayTimelineSpacing: ViewModifier {
    let visible: Bool
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.bottom, visible && mode.showingTime ? 20 : 0)
            .animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
    }
}

// Headers travel across rows mid-transition. Leave quickly, and only
// return once the rows have nearly settled into the list.
private struct ModeSectionHeaderFade: ViewModifier {
    var collapsesInTimeView = false
    @Environment(ViewMode.self) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(mode.showingTime ? 0 : 1)
            .animation(reduceMotion ? ViewMode.animation(reduceMotion: true)
                       : mode.showingTime ? .easeOut(duration: 0.12) : .easeIn(duration: 0.18).delay(0.32),
                       value: mode.showingTime)
            .accessibilityHidden(mode.showingTime)
            // Full day's divider lives above the rows rather than inside the timeline layout.
            // Collapse its reserved height in step with the mode change as its text fades.
            .frame(height: collapsesInTimeView && mode.showingTime ? 0 : nil, alignment: .top)
            .clipped()
            .animation(ViewMode.animation(reduceMotion: reduceMotion), value: mode.showingTime)
    }
}

// Use the button's native pressed state so scrolling cancels the highlight
// automatically and opening still happens immediately on release.
// An unfinished item's circle: a light grey outline until its time comes, then
// traced clockwise in dark grey as the time runs, so it reads as ready to tick off once closed.
private struct ProgressCircle: View {
    let progress: Double
    let settled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private static let lineWidth = CompletionCircle.lineWidth

    var body: some View {
        ZStack {
            // Increase Contrast keeps the untouched outline clearly visible.
            Circle().stroke(settled ? Color(.tertiaryLabel) : Color.primary.opacity(contrast == .increased ? 0.45 : 0.25),
                            lineWidth: Self.lineWidth)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: progress)
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
    var reminderMinutes: [Double] = []
    var deadlineMinute: Double? = nil
    /// In the orange review filter; its track lights orange there.
    var review = false
    /// From another day, here for a reminder or deadline: no track or lane of its own.
    var visiting = false

    /// Every entry gets a track beside the axis; points move aside like ranges do.
    static func durationLanes(for entries: [TimelineEntry]) -> [UUID: Int] {
        // Visitors take no lane, so the full day's layout doesn't change for them; their dot
        // sits on the first track, where the filter has faded any other item's.
        let own = entries.filter { !$0.visiting }
        let assignments = TimelineLanes.assign(starts: own.map(\.minute), ends: own.map(\.endMinute))
        return Dictionary(uniqueKeysWithValues: zip(own.map(\.id), assignments))
    }
    /// Leave breathing room between the time labels and the first track.
    static func laneX(_ lane: Int) -> CGFloat { TimelineNowMarker.axisX + 8 + CGFloat(lane) * laneSpacing }
    /// Wide enough that parallel tracks read as separate bars rather than one thick one.
    static let laneSpacing: CGFloat = 10
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
/// A timed row's time with its time-left note: beneath it in List view, beside it after a
/// dot in Time view. The same three texts are laid out either way, so the shared label can
/// slide the note across during a switch rather than crossfade it.
private struct ScheduleLabel: View {
    let time: String
    let note: String?
    var inline: Bool
    var body: some View {
        // The same light grey as the row's other small text (people, places, carried).
        ScheduleLabelLayout(inline: inline ? 1 : 0) {
            Text(time).font(.caption.monospacedDigit())
            if let note {
                Text("·").font(.caption).opacity(inline ? 1 : 0)
                Text(note).font(.caption.monospacedDigit()).lineLimit(1)
            }
        }
        .foregroundStyle(.tertiary)
    }
}

/// The shared label follows List/Time view, and with it the mode's animation.
private struct ModeScheduleLabel: View {
    var label: ScheduleLabel
    @Environment(ViewMode.self) private var mode
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        var label = label
        label.inline = mode.showingTime && !typeSize.isAccessibilitySize
        return label
    }
}

private struct ScheduleLabelLayout: Layout {
    /// 0 stacks the note under the time, 1 puts it on the time's line; values between blend.
    var inline: CGFloat
    var animatableData: CGFloat {
        get { inline }
        set { inline = newValue }
    }
    private static let spacing: CGFloat = 2, gap: CGFloat = 4

    private func layout(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        // Stacked, the texts wrap to the column as the old VStack did; on one line they keep their ideal widths.
        let column = ProposedViewSize(width: proposal.width, height: nil)
        guard subviews.count == 3 else {
            let size = subviews.first?.sizeThatFits(column) ?? .zero
            return (size, subviews.map { _ in CGRect(origin: .zero, size: size) })
        }
        let time = subviews[0], dot = subviews[1], note = subviews[2]
        let time0 = time.sizeThatFits(column), note0 = note.sizeThatFits(column)
        let time1 = time.sizeThatFits(.unspecified), note1 = note.sizeThatFits(.unspecified)
        let dotSize = dot.sizeThatFits(.unspecified)
        let width0 = max(time0.width, note0.width)
        let stacked = [CGRect(origin: CGPoint(x: width0 - time0.width, y: 0), size: time0),
                       CGRect(origin: CGPoint(x: width0 + Self.gap, y: 0), size: dotSize),
                       CGRect(origin: CGPoint(x: width0 - note0.width, y: time0.height + Self.spacing), size: note0)]
        // The note shares the time's baseline.
        func baseline(_ subview: LayoutSubview, _ size: CGSize) -> CGFloat {
            subview.dimensions(in: ProposedViewSize(size))[VerticalAlignment.firstTextBaseline]
        }
        let timeBaseline = baseline(time, time1)
        let dotX = time1.width + Self.gap
        let line = [CGRect(origin: .zero, size: time1),
                    CGRect(origin: CGPoint(x: dotX, y: timeBaseline - baseline(dot, dotSize)), size: dotSize),
                    CGRect(origin: CGPoint(x: dotX + dotSize.width + Self.gap, y: timeBaseline - baseline(note, note1)), size: note1)]
        let t = min(1, max(0, inline))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let frames = zip(stacked, line).map { a, b in
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        // The dot is hidden while stacked, so it doesn't count towards the stacked size.
        let size0 = CGSize(width: width0, height: stacked[2].maxY)
        let size1 = CGSize(width: line[2].maxX, height: line.map(\.maxY).max() ?? 0)
        return (CGSize(width: mix(size0.width, size1.width), height: mix(size0.height, size1.height)), frames)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = layout(proposal, subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

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
    /// The Scheduled heading keeps its own space in Time view so its axis stays below the
    /// heading. Anytime rows and their heading collapse identically in both modes.
    var keepsSpaceInTimeView = false
    @Environment(ViewMode.self) private var mode: ViewMode?

    func body(content: Content) -> some View {
        let closes = collapsed && !(keepsSpaceInTimeView && mode?.showingTime == true)
        content
            // Keep the contents at their natural height while the outer frame closes.
            // Otherwise shrinking Anytime rows repeatedly compress their buttons/text.
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: closes ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}

private struct TimelineSharedTimeInsetKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

/// A reminder or deadline connector: it carries its dot, so its frame starts at the track
/// and spans up or down to the card.
private struct TimelineMarkKey: LayoutValueKey {
    static let defaultValue = false
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

private struct InlineFocusPhase: Equatable {
    var id: UUID? = nil
    var ending = false
    var revision = 0
}

private struct TimelineContentKey: Equatable {
    let items: [PlanItem]
    /// "Shared" can add a line to a row.
    var sharedZones: Set<String> = []
    let day: Day
    let order: [UUID]
    let markers: [[Bool]]
    let filter: Int
    let showNow: Bool
    let timeNotes: [Bool]
    let typeSize: DynamicTypeSize
    var inlineFocus = InlineFocusPhase()

}

// Measure the two endpoint layouts once, then only interpolate positions while
// animating. Repeated text measurement during each frame caused uneven movement.
private struct DayTimelineLayout: Layout {
    let startMinute: Double
    let laneCount: Int
    let contentKey: TimelineContentKey
    var compactOnly = false
    var progress: Double
    /// Set at once when switching to Time view (it isn't animated): the content takes its full
    /// Time view height from the first frame, so the scroll to now has room to land. Growing
    /// with the rows, the content was still List-sized when the scroll began and clamped it,
    /// which left the timeline where List view had been about every other switch.
    var reservesTimeHeight = false
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    static func gutter(laneCount: Int) -> CGFloat {
        84 + CGFloat(max(0, laneCount - 1)) * TimelineEntry.laneSpacing
    }
    private var gutter: CGFloat { Self.gutter(laneCount: laneCount) }
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
                let y = Self.top + CGFloat(subview[TimelineMinuteKey.self] - startMinute) * Self.pointsPerMinute
                let frame: CGRect
                if subview[TimelineMarkKey.self] {
                    let r = TimelineMarkConnector.dotRadius, x = TimelineEntry.laneX(lane) - r
                    frame = CGRect(x: x, y: min(y, row.midY) - r, width: max(1, row.minX - x), height: abs(row.midY - y) + 2 * r)
                } else {
                    let x = TimelineEntry.laneX(lane) + TimelineTrack.dotSize / 2
                    frame = CGRect(x: x, y: y, width: max(1, row.minX - x), height: max(1, row.midY - y + 1))
                }
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
            // A row collapsed by a filter waits where it will appear, after the rows shown above
            // it, without pushing later rows down. At its bare time it slid across the cards
            // between there and its place when the filter closed.
            let timeTop = marker ? max(0, timeBottom) : max(0, max(timeY - timeHeight / 2, timeBottom + 8))
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
        return CGSize(width: width, height: max(mix(cache.compactHeight, cache.timedHeight),
                                                reservesTimeHeight ? cache.timedHeight : 0))
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


/// A vector curve, so its stroke colour interpolates with the dot and bar. Canvas
/// colours switched immediately even when the surrounding view had an animation.
private struct TimelineConnectorCurve: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.5
        let start = CGPoint(x: inset, y: inset)
        let end = CGPoint(x: max(inset, rect.width - inset), y: max(inset, rect.height - inset))
        // Symmetric handles scale with the gap, keeping a horizontal tangent at both
        // ends instead of the tight, uneven bends from fixed 9/11-point handles.
        let handle = (end.x - start.x) * 0.5
        return Path { path in
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + handle, y: start.y),
                          control2: CGPoint(x: end.x - handle, y: end.y))
        }
    }
}

/// Both parts use the same animation policy, including when focus or completion ends.
private struct TimelineTrackTransition: ViewModifier {
    let complete: Bool
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: complete)
            .animation(FocusedItemMotion.animation(reduceMotion: reduceMotion), value: focused)
    }
}

private struct TimelineConnector: View {
    let complete: Bool
    let focused: Bool

    var body: some View {
        TimelineConnectorCurve()
            .stroke(focused ? TimelineTrack.focusedBar : complete ? TimelineTrack.finishedBar : TimelineTrack.openBar,
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .modifier(TimelineTrackTransition(complete: complete, focused: focused))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A reminder's or deadline's dot on the item's track, with a curve to the card's middle.
/// `rising` when the mark comes after the item's start, so the card lies above it.
private struct TimelineMarkConnector: View {
    static let dotRadius: CGFloat = 4
    let color: Color
    let rising: Bool
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let r = Self.dotRadius
            let dot = CGPoint(x: r, y: rising ? size.height - r : r)
            let card = CGPoint(x: size.width, y: rising ? r : size.height - r)
            var connector = Path()
            connector.move(to: dot)
            connector.addCurve(to: card, control1: CGPoint(x: dot.x + 9, y: dot.y),
                               control2: CGPoint(x: card.x - 11, y: card.y))
            context.stroke(connector, with: .color(color), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: 0, y: dot.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hour labels, tall and drawn off the main thread. The items' tracks are `TimelineTrack`s.
private struct TimelineScale: View, Equatable {
    let startMinute: Double
    let date: Date
    /// The last whole hour already reached on today; hours up to it draw dimmer.
    var passedMinute: Double? = nil
    /// The hour whose label the current-time pill sits on; it's left out rather than peeking out.
    var coveredHour: Int? = nil

    private func y(_ minute: Double) -> CGFloat {
        DayTimelineLayout.top + CGFloat(minute - startMinute) * DayTimelineLayout.pointsPerMinute
    }
    var body: some View {
        // The full-day scale is tall; rasterise it off the main thread so
        // revealing Time view does not stall the first animation frames.
        Canvas(rendersAsynchronously: true) { context, size in
            let axisX = TimelineNowMarker.axisX
            // No axis line or ticks: the hour labels and the items' tracks are the timeline.
            for hour in Int(startMinute / 60)...24 {
                let position = y(Double(hour * 60))
                let passed = passedMinute.map { Double(hour * 60) <= $0 } ?? false
                let hourDate = Calendar.current.date(byAdding: .day, value: hour == 24 ? 1 : 0, to: date)!
                let time = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: hourDate)!
                guard hour != coveredHour else { continue }
                let label = Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(passed ? HierarchicalShapeStyle.tertiary : .secondary)
                context.draw(label, at: CGPoint(x: axisX - 8, y: position), anchor: .trailing)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Dimensions shared by timeline layout and tracks.
enum TimelineTrackSize {
    static let width: CGFloat = 4
    static let dot: CGFloat = 8
}

/// One item's dot and duration bar. Views of their own rather than part of a canvas, so a
/// change of colour fades: ticking an item off greys its track, and the review filter turns
/// it orange. A canvas redrew the whole drawing in one frame.
private struct TimelineTrack: View {
    /// Cards sit wherever there's room, so their size and place don't show an item's time; the
    /// track does, and has to be bold enough to read at a glance and to follow to its card.
    static let width = TimelineTrackSize.width
    static let dotSize = TimelineTrackSize.dot
    /// Solid greys rather than translucent ones: where a dot, bar or connector crossed another,
    /// or the passed-time wash, a translucent one showed through as a darker patch.
    static let openBar = grey(light: 0.75, dark: 0.3)
    static let openDot = grey(light: 0.4, dark: 0.62)
    static let finishedBar = grey(light: 0.9, dark: 0.16)
    static let finishedDot = grey(light: 0.8, dark: 0.24)
    static let focusedBar = grey(light: 0.38, dark: 0.72)
    // Keep the review dot distinct without translucent overlaps along the track.
    static let reviewBar = Color.orange.mix(with: Color(uiColor: .systemBackground), by: 0.4)
    private static func grey(light: CGFloat, dark: CGFloat) -> Color {
        Color(UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? dark : light, alpha: 1) })
    }
    let entry: TimelineEntry
    let lane: Int
    let startMinute: Double
    let orange: Bool
    let focused: Bool

    private func y(_ minute: Double) -> CGFloat {
        DayTimelineLayout.top + CGFloat(minute - startMinute) * DayTimelineLayout.pointsPerMinute
    }
    var body: some View {
        let x = TimelineEntry.laneX(lane)
        let startY = y(entry.minute)
        let endY = entry.endMinute.map { y(max($0, entry.minute)) } ?? startY
        ZStack(alignment: .topLeading) {
            if endY > startY {
                // As tall as a round-capped stroke from start to end.
                let w = Self.width
                Capsule()
                    .fill(focused ? Self.focusedBar : orange ? Self.reviewBar : entry.complete ? Self.finishedBar : Self.openBar)
                    .frame(width: w, height: endY - startY + w)
                    .offset(x: x - w / 2, y: startY - w / 2)
            }
            let d = Self.dotSize
            Circle()
                .fill(focused ? Color.primary : orange ? Color.orange : entry.complete ? Self.finishedDot : Self.openDot)
                .frame(width: d, height: d)
                .offset(x: x - d / 2, y: startY - d / 2)
        }
        // Track colours share the item’s completion update.
        .modifier(TimelineTrackTransition(complete: entry.complete, focused: focused))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimelineNowMarker: View {
    static let height: CGFloat = 16
    static let anchorID = "timeline-now"
    static let axisX: CGFloat = 54
    /// An hour label closer than this to the current time would show beside the pill.
    static let coverMinutes: Double = 15
    /// The time passed today. Stronger in Dark appearance, where the light one's 2.5% vanished
    /// against black (cards get more lift there too), but still lighter than a card.
    static let passedWash = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.055) : UIColor.black.withAlphaComponent(0.025) })
    let time: Date
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let axisX = Self.axisX, middle = size.height / 2
                var current = Path()
                current.move(to: CGPoint(x: axisX - 4, y: middle))
                current.addLine(to: CGPoint(x: size.width, y: middle))
                context.stroke(current, with: .color(.primary.opacity(0.3)), lineWidth: 0.5)
            }
            // The current time in a dark pill in the hour column, where the eye looks for times.
            Text(time.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 5)
                .frame(height: 14)
                .background(Color.primary.opacity(0.75), in: Capsule())
                .frame(width: Self.axisX - 4, height: Self.height, alignment: .trailing)
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
    // A new navigation input interrupts settling; only the active finger gesture blocks taps.
    // Item actions retain their stricter gate so releasing a swipe cannot open or tick a row.
    var allowsDayNavigation: Bool { !swiping }
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
    let sharedZones: Set<String>
    let filter: Int
    let panelFilter: Int
    let minute: Int
    let typeSize: DynamicTypeSize
    let insets: EdgeInsets
    let reduceMotion: Bool
    // Focus recolours the visible page's existing tracks without rebuilding its neighbours.
    let focusedID: UUID?
    let focusEnding: Bool
    let focusDetailsRevision: Int

    func hasSameUnfilteredContent(as other: Self) -> Bool {
        // The two neighbouring pages always show All. Filter and status-panel changes
        // belong to the visible page and must not invalidate those neighbours.
        items == other.items && sharedZones == other.sharedZones && minute == other.minute && typeSize == other.typeSize
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
        let changed = revision != coordinator.latestRevision
        coordinator.latestRevision = revision
        if day != coordinator.day {
            coordinator.navigate(to: day)
        } else {
            coordinator.refreshIfIdle(animation: changed ? context.transaction.animation : nil)
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
        /// The animation of the SwiftUI update that brought this content, if any. Replacing
        /// the root view from UIKit drops that update's transaction, so a tick-off's dot and
        /// time otherwise jumped. Keyed on a counter so only this one swap animates.
        var animation: Animation? = nil
        var animationKey = 0
        var body: some View {
            content.transaction { transaction in
                if !policy.isForeground {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .animation(animation, value: animationKey)
        }
    }
    final class PageHost: UIHostingController<PageSurface> {
        let policy: PageAnimationPolicy
        var content: AnyView {
            get { rootView.content }
            set { setContent(newValue) }
        }
        func setContent(_ content: AnyView, animation: Animation? = nil) {
            let key = rootView.animationKey &+ (animation == nil ? 0 : 1)
            rootView = PageSurface(content: content, policy: policy, animation: animation, animationKey: key)
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
        private var previewWarmAfter: ContinuousClock.Instant?
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
        func refreshIfIdle(animation: Animation? = nil) {
            guard !dragging, animator == nil, requestedDay == day, !interaction.holdsPageWork else { return }
            if displayedRevision != latestRevision {
                let filterChanged = displayedRevision.map { $0.filter != latestRevision.filter } ?? false
                let statusChanged = displayedRevision.map {
                    $0.items.map(\.isSettled) != latestRevision.items.map(\.isSettled)
                } ?? false
                if statusChanged && !reduceMotion {
                    // Measuring two offscreen days competes with the visible tick/strike.
                    // Restart the quiet period on another toggle, without delaying the item.
                    previewWarmAfter = .now.advanced(by: .milliseconds(450))
                    warmTask?.cancel()
                    warmTask = nil
                }
                // The first hosted update can arrive without its originating transaction.
                // Measure the outgoing page and derive filter motion from displayed state,
                // including when a refresh was deferred while the calendar or pager moved.
                if filterChanged { host.view.layoutIfNeeded() }
                let pageAnimation: Animation?
                if filterChanged {
                    pageAnimation = reduceMotion ? nil : .smooth(duration: 0.5)
                } else if statusChanged {
                    pageAnimation = ItemStatusMotion.animation(reduceMotion: reduceMotion)
                } else {
                    pageAnimation = animation
                }
                host.setContent(latestContent, animation: pageAnimation)
                displayedRevision = latestRevision
            }
            scheduleWarm()
        }
        private func scheduleWarm() {
            guard warmTask == nil, !dragging, animator == nil, requestedDay == day, size.width > 0,
                  !interaction.isFiltering else { return }
            let warmAfter = previewWarmAfter
            warmTask = Task { [weak self] in
                if let warmAfter, warmAfter > .now {
                    do { try await ContinuousClock().sleep(until: warmAfter) }
                    catch { return }
                } else {
                    await Task.yield()
                }
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
                        minimumTravel: 6, cancelled: false)
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
            // The visual offset includes the interrupted slide, but the new gesture alone
            // determines intent. Otherwise a short swipe can select the opposite day.
            let travel = translation
            let projection = projected
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
            FrameRateBoost.shared.request(for: .milliseconds(500))
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

extension View {
    /// Keeps rows a comfortable reading width on iPad, centred, while the scroll view and its
    /// swipes still span the screen. On iPhone the screen is narrower, so nothing changes.
    func readableWidth() -> some View {
        frame(maxWidth: 680).frame(maxWidth: .infinity)
    }
}
