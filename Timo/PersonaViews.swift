import SwiftUI
import UIKit

// Persona colours live in GuideActivity.swift, which the widget compiles too.

/// A small glowing sphere in a persona's gradient. With no persona, it blends all of them.
struct PersonaOrb: View {
    let persona: Persona?
    var size: CGFloat = 22
    var glows = true

    var body: some View {
        ZStack {
            if let persona {
                Circle().fill(LinearGradient(colors: persona.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                let colors = Persona.allCases.map { $0.colors[0] }
                Circle().fill(AngularGradient(colors: colors + [colors[0]], center: .center))
            }
            // A soft highlight gives the gradient its roundness.
            Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                         center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: size * 0.6))
        }
        .frame(width: size, height: size)
        .shadow(color: (persona?.colors.last ?? .purple).opacity(glows ? 0.35 : 0), radius: size * 0.22)
        .accessibilityHidden(true)
    }

    @MainActor private static var images: [String: UIImage] = [:]
    /// The orb as a full-colour image, for places that only take images, such as menus.
    @MainActor static func image(for persona: Persona?, scale: CGFloat) -> UIImage {
        let key = "\(persona?.rawValue ?? "all")@\(scale)"
        if let cached = images[key] { return cached }
        let renderer = ImageRenderer(content: PersonaOrb(persona: persona, size: 20, glows: false))
        renderer.scale = scale
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
        images[key] = image
        return image
    }
}

/// The persona switcher also offers a view of active CloudKit shares.
enum PersonaSelection: Hashable {
    case all, persona(Persona), shared

    var itemPersona: Persona? {
        if case .persona(let persona) = self { return persona }
        return nil
    }

    var title: String {
        switch self {
        case .all: "All"
        case .persona(let persona): persona.title
        case .shared: "Shared"
        }
    }

    static func menuOrder(includesShared: Bool) -> [Self] {
        [.all] + Persona.allCases.map(Self.persona) + (includesShared ? [.shared] : [])
    }

    /// Swipes cycle through the history pages and skip All.
    func cycled(by offset: Int, in choices: [Self]) -> Self {
        let pages = Array(choices.dropFirst())
        guard let index = pages.firstIndex(of: self) else {
            return (offset > 0 ? pages.first : pages.last) ?? .all
        }
        return pages[(index + offset + pages.count) % pages.count]
    }
}

/// The top-left control. Tapping it opens a menu, grown out of the capsule, listing All and
/// every persona with its orb; choosing one switches to it.
struct PersonaSwitcher: View {
    @Binding var selection: PersonaSelection
    let choices: [PersonaSelection]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var orbSize: CGFloat = 20

    var body: some View {
        Menu {
            Picker("Persona", selection: Binding(get: { selection }, set: choose)) {
                ForEach(choices, id: \.self) { choice in
                    Label {
                        Text(choice.title)
                    } icon: {
                        if choice == .shared {
                            Image(systemName: "person.2.fill")
                        } else {
                            Image(uiImage: PersonaOrb.image(for: choice.itemPersona, scale: displayScale))
                        }
                    }
                    .tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                if selection == .shared {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: orbSize * 0.7, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: orbSize, height: orbSize)
                        .accessibilityHidden(true)
                } else {
                    PersonaOrb(persona: selection.itemPersona, size: orbSize)
                }
                Text(selection.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            // The label swaps at once; the menu folding back into the capsule is the motion.
            .transaction { $0.animation = nil }
            // The toolbar draws the glass capsule around this, matching the other bar buttons.
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .background {
                // Tints the toolbar's glass with the persona, like an active filter button.
                // The glass reaches 10 points past the label on each side.
                if let color = selection.itemPersona?.color {
                    Capsule().fill(color.opacity(0.22))
                        .padding(.horizontal, -10)
                        .allowsHitTesting(false)
                }
            }
            // Like the label, the tint changes at once rather than fading with the page.
            .transaction { $0.animation = nil }
        }
        .menuOrder(.fixed)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityLabel("Persona")
        .accessibilityValue(selection.title)
        .accessibilityHint("Opens the list of personas. Swipe up or down to cycle through them.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }
    private func choose(_ choice: PersonaSelection) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.3)) { selection = choice }
    }
    private func step(_ offset: Int) { choose(selection.cycled(by: offset, in: choices)) }
}

/// A horizontal swipe across a persona page. It only begins for a clearly sideways drag, so the
/// page's vertical scrolling is left alone, and recognises alongside the scroll view.
private struct PersonaSwipe: UIGestureRecognizerRepresentable {
    /// Called once per swipe; `true` for a swipe to the left, which goes forward like the day pager.
    let swiped: (Bool) -> Void
    /// Bracket the drag, so the rows under the finger can hold off opening or completing.
    let began: () -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began: began()
        case .cancelled, .failed: ended()
        default: break
        }
        guard pan.state == .ended else { return }
        ended()
        let move = pan.translation(in: pan.view)
        guard abs(move.x) > 24, abs(move.x) > abs(move.y) else { return }
        swiped(move.x < 0)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The persona pages over the day view. Changing persona cross-fades the pages, so each
/// page's gradient wash blends into the next instead of sliding across. Swiping left or right
/// cycles through the personas, never back to All.
struct PersonaPages: View {
    @Binding var selection: PersonaSelection
    let choices: [PersonaSelection]
    let sharedPeople: [CloudSync.Person]
    @Binding var sharedPersonID: String?
    let now: Date
    let add: () -> Void
    @Binding var months: Int
    let history: (PersonaSelection) -> [PersonaDay]
    /// The top filter buttons' filter, and whether a row is in it on a day.
    let filter: DayView.DayFilter
    let matches: (PlanItem, Day) -> Bool
    /// The day list's own row, so a persona page shows each item exactly as the day view does.
    let row: (PlanItem, Day) -> AnyView
    /// The day pager's swipe gate, shared so a sideways swipe never opens the item it started on.
    let swipeBegan: () -> Void
    let swipeEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if selection != .all {
                let choice = selection
                PersonaHistoryView(selection: choice, now: now, add: add, months: $months, filter: filter,
                                   history: { history(choice) }, matches: matches, row: row)
                .id(choice == .shared ? sharedPersonID : nil)
                .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
                    if choice == .shared && !sharedPeople.isEmpty {
                        SharedPeopleFilter(people: sharedPeople, selection: $sharedPersonID)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                }
                .id(choice)
                .transition(.opacity)
                // Like the day pager: swiping left goes forward.
                .gesture(PersonaSwipe(swiped: { forward in step(forward ? 1 : -1) },
                                      began: swipeBegan, ended: swipeEnded))
            }
        }
    }
    private func step(_ offset: Int) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.3)) {
            selection = selection.cycled(by: offset, in: choices)
        }
    }
}

/// Stays above the history so the filter is reachable from any day in the list.
private struct SharedPeopleFilter: View {
    let people: [CloudSync.Person]
    @Binding var selection: String?
    private var name: String { people.first { $0.id == selection }?.name ?? "Everyone" }

    var body: some View {
        Menu {
            Picker("Shared with", selection: $selection) {
                Text("Everyone").tag(nil as String?)
                ForEach(people) { person in
                    Text(person.name).tag(Optional(person.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(name).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .menuOrder(.fixed)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityLabel("Shared with")
        .accessibilityValue(name)
    }
}

/// Everything in one persona, past and present, grouped by day with the newest day first.
struct PersonaHistoryView: View {
    let selection: PersonaSelection
    let now: Date
    let add: () -> Void
    /// How far ahead repeating items are listed; the button at the top adds three months at a time.
    @Binding var months: Int
    /// The top filter buttons narrow the list as they narrow a day.
    let filter: DayView.DayFilter
    let history: () -> [PersonaDay]
    let matches: (PlanItem, Day) -> Bool
    let row: (PlanItem, Day) -> AnyView
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(idType: PersonaHistoryRow.ID.self)
    @State private var visibleDays: ClosedRange<Day>?
    @State private var scrollInsets = EdgeInsets()

    var body: some View {
        let horizon = Self.horizon(months: months, from: now)
        let all = history()
        let items = Self.unique(all.flatMap(\.items))
        let days = filter == .all ? all : all.compactMap { entry in
            let kept = entry.items.filter { matches($0, entry.day) }
            return kept.isEmpty ? nil : PersonaDay(day: entry.day, items: kept)
        }
        let filtered = filter == .all ? items.count : Self.unique(days.flatMap(\.items)).count
        let more = store.repeats(items, after: horizon)
        let today = Self.todayAnchor(days, now: now)
        let rows = days.flatMap { entry in
            [PersonaHistoryRow.heading(entry.day)] + entry.items.map { .item($0, entry.day) }
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // The furthest days are at the top, so more of them come in above.
                if more {
                    MoreRepeatsButton {
                        let top = days.first?.day
                        months += 3
                        store.generateRepeats(through: Self.horizon(months: months, from: now))
                        // Stay where the list was; the new months are above.
                        if let top {
                            Task { @MainActor in
                                // Once the new days are laid out: before, it scrolled to where they'd go.
                                try? await Task.sleep(for: .milliseconds(60))
                                scrollPosition.scrollTo(id: PersonaHistoryRow.ID(day: top), anchor: .top)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 12)
                }
                // The persona itself is named by the glowing button above; like the day view,
                // the page only adds how much of it is done, or how many rows a filter keeps.
                HStack {
                    Spacer(minLength: 0)
                    if filter == .review {
                        Text("\(filtered) to review").font(.caption).foregroundStyle(.orange)
                    } else if filter == .reminders {
                        Text("\(filtered) with reminders").font(.caption).foregroundStyle(.blue)
                    } else if filter == .deadlines {
                        Text("\(filtered) with deadlines").font(.caption).foregroundStyle(.red)
                    } else if !items.isEmpty {
                        Text("\(items.filter(\.isComplete).count)/\(items.filter { !$0.isCancelled }.count) complete")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
                if all.isEmpty && selection == .shared {
                    ContentUnavailableView("No Shared Items", systemImage: "person.2",
                                           description: Text("Items you share or receive appear here."))
                        .frame(minHeight: 280)
                } else if all.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in \(selection.title) yet", systemImage: "circle.dashed")
                    } description: {
                        Text("Give an item the \(selection.title) persona and it will be gathered here, with everything before and after it.")
                    } actions: {
                        Button("Add an item", systemImage: "plus", action: add).buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 280)
                }
                ForEach(rows) { entry in
                    switch entry {
                    case .heading(let day):
                        Text(Self.heading(day, now: now))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                    case .item(let item, let day):
                        row(item, day).padding(.horizontal, 16)
                    }
                }
                SettingsLink()
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            .scrollTargetLayout()
            .readableWidth()
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: rows.map(\.id))
        }
        .scrollPosition($scrollPosition, anchor: .top)
        .scrollEdgeEffectHidden(true, for: .vertical)
        .onScrollTargetVisibilityChange(idType: PersonaHistoryRow.ID.self, threshold: 0.01) { targets in
            let days = targets.map(\.day)
            guard let first = days.min(), let last = days.max(), visibleDays != first...last else { return }
            visibleDays = first...last
        }
        .onScrollGeometryChange(for: EdgeInsets.self, of: \.contentInsets) { _, insets in
            scrollInsets = insets
        }
        .overlay {
            TodayPill(day: today, visibleDays: $visibleDays, scrollInsets: $scrollInsets) {
                guard let today else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                    scrollPosition.scrollTo(id: PersonaHistoryRow.ID(day: today), anchor: .top)
                }
            }
        }
        .modifier(PullsToSearch())
        // Opens on today, with what's ahead above it: once the days generated for the list are in,
        // as they come in above today and would push it out of view.
        .task {
            store.generateRepeats(through: horizon)
            await Task.yield()
            let days = history()
            if let target = Self.todayAnchor(days, now: now) {
                scrollPosition.scrollTo(id: PersonaHistoryRow.ID(day: target), anchor: .top)
            }
        }
    }
    /// The last day repeating items are listed on, `months` ahead.
    static func horizon(months: Int, from now: Date) -> Day {
        Day(Calendar.current.date(byAdding: .month, value: months, to: now) ?? now)
    }
    /// Where a newest-first list of days opens: today, or the nearest day before it, or failing
    /// that the nearest one ahead.
    static func todayAnchor(_ days: [PersonaDay], now: Date) -> Day? {
        let today = Day(now)
        return days.first { $0.day <= today }?.day ?? days.last?.day
    }
    /// A running range is listed on its own day and on today, but counted once.
    private static func unique(_ items: [PlanItem]) -> [PlanItem] {
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }
    /// Also titles the days of search results.
    static func heading(_ day: Day, now: Date) -> String {
        let calendar = Calendar.current
        let date = day.date()
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// Each heading and card can be laid out independently, even on days with many carried items.
private enum PersonaHistoryRow: Identifiable {
    case heading(Day)
    case item(PlanItem, Day)

    struct ID: Hashable {
        let day: Day
        var itemID: UUID? = nil
    }

    var id: ID {
        switch self {
        case .heading(let day): ID(day: day)
        case .item(let item, let day): ID(day: day, itemID: item.id)
        }
    }
}

/// A small glass "Today" at the top or bottom of a persona page once today has scrolled out of
/// sight, where Time view shows its earlier and later counts; tapping it scrolls back to today.
private struct TodayPill: View {
    let day: Day?
    @Binding var visibleDays: ClosedRange<Day>?
    @Binding var scrollInsets: EdgeInsets
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kept through the exit animation, so the pill fades where it was.
    @State private var lastEdge = VerticalEdge.bottom
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }
    private var edge: VerticalEdge? {
        guard let day, let visibleDays else { return nil }
        if day > visibleDays.upperBound { return .top }
        if day < visibleDays.lowerBound { return .bottom }
        return nil
    }

    var body: some View {
        let shown = edge ?? lastEdge
        let visible = edge != nil
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: shown == .top ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                Text("Today").font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .compositingGroup()
        .opacity(visible ? 1 : 0)
        .offset(y: visible || reduceMotion ? 0 : (shown == .top ? -4 : 4))
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .accessibilityLabel(shown == .top ? "Today, above" : "Today, below")
        .accessibilityHint("Scrolls back to today")
        // 6 points from the glass of the top controls or the dock, like Time view's counts.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: shown == .top ? .top : .bottom)
        .padding(.top, scrollInsets.top - 10 + 6)
        .padding(.bottom, scrollInsets.bottom - 26 + 6)
        .ignoresSafeArea(.container, edges: .vertical)
        .animation(animation, value: visible)
        .onChange(of: edge) { _, edge in if let edge { lastEdge = edge } }
    }
}

/// Above a list of days whose repeating items stop a few months ahead: shows three more months.
struct MoreRepeatsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Show 3 more months of repeating items", systemImage: "arrow.up")
                .font(.subheadline)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .accessibilityHint("Lists repeating items three months further ahead")
    }
}

/// Completion and reopening update immediately, with one shared circle/title/layout animation.
struct CompletionButton<Icon: View>: View {
    let item: PlanItem
    let day: Day
    var isEnabled: () -> Bool = { true }
    var keepsCarriedArrow = false
    @ViewBuilder let icon: () -> Icon
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCheck: Bool { item.isComplete && !keepsCarriedArrow }
    private var showsCross: Bool { item.isCancelled && !keepsCarriedArrow }
    private var glyphKind: Int { showsCheck ? -1 : showsCross ? 1 : 0 }

    var body: some View {
        Button {
            guard isEnabled(), let current = store.item(item.id) else { return }
            if !current.isSettled { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65) }
            if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(500)) }
            withAnimation(ItemStatusMotion.animation(reduceMotion: reduceMotion)) {
                store.toggle(current, on: day)
            }
        } label: {
            ZStack {
                icon()
                // The same two strokes reshape between check and cross.
                CompletionStatusGlyph(kind: glyphKind)
                    .allowsHitTesting(false)
            }
            .frame(width: CompletionCircle.diameter, height: CompletionCircle.diameter)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.completionActionLabel)
    }
}

enum ItemStatusMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }
}

/// Every completion circle shares one diameter and stroke, so open, traced, ticked, cancelled
/// and carried circles never differ in size. They're drawn rather than SF Symbols: a symbol's
/// circle sits inside padding of its own and came out about 18 points across in a 22-point
/// frame, beside a drawn 22-point open circle.
enum CompletionCircle {
    static let diameter: CGFloat = 22
    static let lineWidth: CGFloat = 1.6
}

/// An outlined completion circle, empty, with a cancelled ✘ or with a carried chevron.
struct OutlinedCompletionCircle: View {
    enum Glyph: Equatable { case none, cross, chevron }
    var glyph: Glyph = .none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: CompletionCircle.lineWidth)
            CrossMark(progress: glyph == .cross ? 1 : 0)
                .stroke(style: StrokeStyle(lineWidth: CompletionCircle.lineWidth, lineCap: .round))
                .padding(CompletionCircle.diameter * 0.32)
            ChevronMark()
                .trim(from: 0, to: glyph == .chevron ? 1 : 0)
                .stroke(style: StrokeStyle(lineWidth: CompletionCircle.lineWidth, lineCap: .round, lineJoin: .round))
                .frame(width: CompletionCircle.diameter * 0.18, height: CompletionCircle.diameter * 0.36)
                .offset(x: CompletionCircle.diameter * 0.03)
        }
        .frame(width: CompletionCircle.diameter, height: CompletionCircle.diameter)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: glyph)
    }
}

/// Keep the last glyph while erasing; changing settled states reshapes its strokes.
private struct CompletionStatusGlyph: View {
    let kind: Int
    @State private var progress: CGFloat
    @State private var morph: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(kind: Int) {
        self.kind = kind
        _progress = State(initialValue: kind == 0 ? 0 : 1)
        _morph = State(initialValue: kind == 1 ? 1 : 0)
    }

    var body: some View {
        CompletionGlyphShape(progress: progress, morph: morph)
            .stroke(style: StrokeStyle(lineWidth: CompletionCircle.lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.tertiary)
            .frame(width: CompletionCircle.diameter, height: CompletionCircle.diameter)
            .accessibilityHidden(true)
            .onChange(of: kind) { _, kind in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    progress = kind == 0 ? 0 : 1
                    if kind != 0 { morph = kind == 1 ? 1 : 0 }
                }
            }
    }
}

/// Interpolate endpoints instead of cross-fading glyphs or passing through an empty circle.
private struct CompletionGlyphShape: Shape {
    var progress: CGFloat
    var morph: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, morph) }
        set { progress = newValue.first; morph = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let blend = min(1, max(0, morph))
        let drawn = min(1, max(0, progress))
        func point(_ x: CGFloat, _ y: CGFloat, _ crossX: CGFloat, _ crossY: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * (x + (crossX - x) * blend),
                    y: rect.minY + rect.height * (y + (crossY - y) * blend))
        }
        let firstStart = point(0.29, 0.52, 0.32, 0.32)
        let firstEnd = point(0.44, 0.67, 0.68, 0.68)
        let secondStart = point(0.44, 0.67, 0.68, 0.32)
        let secondEnd = point(0.72, 0.36, 0.32, 0.68)
        // Preserve sequential drawing/erasing, with equal stroke times for the cross.
        let split = 0.336 + (0.5 - 0.336) * blend
        return Path { path in
            func stroke(_ start: CGPoint, _ end: CGPoint, _ amount: CGFloat) {
                guard amount > 0 else { return }
                let amount = min(1, amount)
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x + (end.x - start.x) * amount,
                                        y: start.y + (end.y - start.y) * amount))
            }
            stroke(firstStart, firstEnd, drawn / split)
            stroke(secondStart, secondEnd, (drawn - split) / (1 - split))
        }
    }
}

private struct ChevronMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
    }
}

private struct CrossMark: Shape {
    var progress: CGFloat = 1
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let first = min(1, max(0, progress * 2))
        let second = min(1, max(0, progress * 2 - 1))
        // One continuous progress value draws in order and erases in reverse order.
        return Path { path in
            if first > 0 {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * first, y: rect.minY + rect.height * first))
            }
            if second > 0 {
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - rect.width * second, y: rect.minY + rect.height * second))
            }
        }
    }
}

/// Open items have a faint fill; completed and cancelled items have no background or outline. The outlined style
/// (over the page's background colour) is kept but currently unused. Increase Contrast makes both styles a little firmer.
/// Pressing the item (its title, not its circle) settles the card in a touch, springing back on
/// release, without shading it: holding hands over to the system's own lift. Reduce Motion
/// keeps it still.
struct ItemCard: ViewModifier {
    var outlined = false
    /// An item from another day, shown for a reminder or deadline: no fill, a dashed outline.
    var dashed = false
    var settled = false
    /// Space between the card's trailing edge and the time; the day view's shared time label
    /// is placed outside the row, so it uses the same inset.
    static let trailingInset: CGFloat = 12
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    static func tint(_ contrast: ColorSchemeContrast, colorScheme: ColorScheme) -> Color {
        // The faint light-mode tint disappears against black. Give dark cards enough
        // lift to read as separate surfaces, including in the focussed state.
        let opacity: Double = colorScheme == .dark
            ? (contrast == .increased ? 0.14 : 0.08)
            : (contrast == .increased ? 0.07 : 0.022)
        return Color.primary.opacity(opacity)
    }

    static func outline(_ contrast: ColorSchemeContrast, colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.22 : colorScheme == .dark ? 0.12 : 0.07)
    }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, Self.trailingInset)
            .padding(.vertical, 2)
            .environment(\.itemCardPressed, $pressed)
            .background(Self.tint(contrast, colorScheme: colorScheme).opacity(settled || outlined || dashed ? 0 : 1), in: Self.shape)
            // Open cards stay opaque during layout animations; settled rows reveal the page.
            .background(Color(.systemBackground).opacity(settled ? 0 : 1), in: Self.shape)
            .overlay {
                // Filled cards get a hairline edge so they read as surfaces; outlined
                // (carried) cards keep their fuller stroke in place of the fill.
                Self.shape.strokeBorder(Self.outline(contrast, colorScheme: colorScheme).opacity(dashed ? 2.5 : 1),
                                        style: StrokeStyle(lineWidth: outlined || dashed ? 1 : 0.5, dash: dashed ? [4, 3] : []))
                    .opacity(settled ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: outlined)
            .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: settled)
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            // A quick press in, then a soft spring back so letting go feels physical.
            .animation(reduceMotion ? nil : pressed ? .easeOut(duration: 0.1) : .spring(duration: 0.35, bounce: 0.3),
                       value: pressed)
    }
}

extension EnvironmentValues {
    /// The press state of the enclosing item card, set by `ItemCardPressStyle`.
    @Entry var itemCardPressed: Binding<Bool>? = nil
}

/// For the button that opens an item: its press is shown by the whole card rather than by
/// dimming the title, so the item reads as one thing being pressed.
struct ItemCardPressStyle: ButtonStyle {
    @Environment(\.itemCardPressed) private var cardPressed

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in cardPressed?.wrappedValue = isPressed }
            // Let the card settle as the hold reveals its details.
            .task(id: configuration.isPressed) {
                guard configuration.isPressed else { return }
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled else { return }
                cardPressed?.wrappedValue = false
            }
    }
}

extension PlanItem {
    /// When the item was made, and when it was completed or cancelled.
    var history: String {
        var lines = ["Created " + Self.stamp(createdAt)]
        if let completedAt { lines.append("Completed " + Self.stamp(completedAt)) }
        if let cancelledAt { lines.append("Cancelled " + Self.stamp(cancelledAt)) }
        for status in dailyStatuses ?? [] {
            let day = status.day.date().formatted(date: .abbreviated, time: .omitted)
            if let completedAt = status.completedAt { lines.append("Completed for " + day + ": " + Self.stamp(completedAt)) }
            if let cancelledAt = status.cancelledAt { lines.append("Cancelled for " + day + ": " + Self.stamp(cancelledAt)) }
        }
        return lines.joined(separator: "\n")
    }
    private static func stamp(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let day = sameYear ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
        return day + ", " + date.formatted(date: .omitted, time: .shortened)
    }
}

/// Which occurrences of a repeating item to delete, from the narrowest choice to the widest, as
/// Calendar does. On the original item, "this and following" is left out, since it would mean
/// the same as all of them.
struct RepeatDeletionButtons: View {
    let item: PlanItem
    let perform: (RepeatDeletion) -> Void
    @EnvironmentObject private var store: PlanStore

    var body: some View {
        ForEach(Self.choices(startsSeries: store.startsSeries(item)), id: \.scope) { choice in
            Button(choice.title, role: .destructive) { perform(choice.scope) }
        }
    }
    static func choices(startsSeries: Bool) -> [(title: LocalizedStringKey, scope: RepeatDeletion)] {
        startsSeries
            ? [("Original item only", .occurrence), ("Original and all linked items", .all)]
            : [("This linked item only", .occurrence), ("This and following linked items", .following),
               ("Original and all linked items", .all)]
    }
}

/// The Undo offered after Delete or Push: a small glass capsule above the dock naming what went,
/// like Mail's Undo Send. It stays a few seconds (longer with VoiceOver, which also announces
/// it); the system's own undo (shake, or three fingers) works as well.
struct UndoActionBar: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        if let action = store.lastUndo {
            HStack(spacing: 14) {
                undoMessage(action)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Button("Undo") {
                    if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
                    withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) { store.undo(action) }
                }
                .fontWeight(.semibold)
                .accessibilityHint("Reverses the last action")
            }
            .font(.subheadline)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectTransition(.materialize)
            .padding(.horizontal, 24)
            .task(id: action.id) {
                AccessibilityNotification.Announcement(announcement(action)).post()
                try? await Task.sleep(for: .seconds(voiceOver ? 10 : 5))
                if store.lastUndo?.id == action.id {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { store.lastUndo = nil }
                }
            }
        }
    }
    private func undoMessage(_ action: PlanUndo) -> Text {
        switch action {
        case .deletion: Text("Deleted “\(action.title)”")
        case .push: Text("Pushed “\(action.title)”")
        }
    }
    private func announcement(_ action: PlanUndo) -> String {
        switch action {
        case .deletion: String(localized: "Deleted \(action.title). Undo available.")
        case .push: String(localized: "Pushed \(action.title). Undo available.")
        }
    }

}

extension View {
    func settledTitleStyle(_ item: PlanItem, isCarriedEntry: Bool = false) -> some View {
        modifier(SettledTitleStyle(item: item, isCarriedEntry: isCarriedEntry))
    }
}

private struct SettledTitleStyle: ViewModifier {
    let item: PlanItem
    let isCarriedEntry: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .foregroundStyle(item.isSettled ? Color(.tertiaryLabel) : Color(.label))
            .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion), value: item.isSettled)
            .overlay {
                // Native text draws a strike on every wrapped line. Only its mask animates,
                // so revealing the strike cannot change row measurement or its transaction.
                content
                    .foregroundStyle(Color.clear)
                    .strikethrough(true, pattern: .solid, color: Color.secondary.opacity(0.45))
                    .mask {
                        Rectangle()
                            .animation(ItemStatusMotion.animation(reduceMotion: reduceMotion)) { mask in
                                mask.scaleEffect(x: item.isSettled ? 1 : 0, anchor: .leading)
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension PlanItem {
    /// What tapping the circle does, for VoiceOver. A cancelled item's circle restores it.
    var completionActionLabel: String {
        isCancelled ? "Uncancel \(title)" : isComplete ? "Mark \(title) incomplete" : "Complete \(title)"
    }
}
