import SwiftUI

extension Persona {
    /// Each persona's own gradient, light to deep, so its orb can be told apart at a glance.
    var colors: [Color] {
        switch self {
        case .health: return [.mint, .green]
        case .work: return [.cyan, .blue]
        case .family: return [.yellow, .orange]
        case .friends: return [.pink, .red]
        case .personal: return [.purple, .indigo]
        }
    }
}

extension Persona {
    /// The persona's deeper colour, for text and tints.
    var color: Color { colors[1] }

}

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

extension Persona {
    /// The menu's order: All first, then each persona.
    static let menuOrder: [Persona?] = [nil] + allCases.map { $0 }
}

/// The top-left control. Tapping it opens a menu, grown out of the capsule, listing All and
/// every persona with its orb; choosing one switches to it.
struct PersonaSwitcher: View {
    @Binding var selection: Persona?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var orbSize: CGFloat = 20

    var body: some View {
        Menu {
            Picker("Persona", selection: Binding(get: { selection }, set: choose)) {
                ForEach(Persona.menuOrder, id: \.self) { persona in
                    Label {
                        Text(persona?.title ?? "All")
                    } icon: {
                        Image(uiImage: PersonaOrb.image(for: persona, scale: displayScale))
                    }
                    .tag(persona)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                PersonaOrb(persona: selection, size: orbSize)
                Text(selection?.title ?? "All")
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
                if let selection {
                    Capsule().fill(selection.color.opacity(0.22))
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
        .accessibilityValue(selection?.title ?? "All")
        .accessibilityHint("Opens the list of personas")
    }
    private func choose(_ persona: Persona?) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.3)) { selection = persona }
    }
}

/// The persona pages over the day view. Changing persona cross-fades the pages, so each
/// page's gradient wash blends into the next instead of sliding across.
struct PersonaPages: View {
    let persona: Persona?
    let now: Date
    let open: (PlanItem) -> Void
    let add: () -> Void

    var body: some View {
        ZStack {
            if let persona {
                PersonaHistoryView(persona: persona, now: now, open: open, add: add)
                    .id(persona)
                    .transition(.opacity)
            }
        }
    }
}

/// Everything in one persona, past and present, grouped by day with the newest day first.
struct PersonaHistoryView: View {
    let persona: Persona
    let now: Date
    let open: (PlanItem) -> Void
    let add: () -> Void
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let days = Planner.history(of: persona, in: store.items, now: now)
        let items = days.flatMap(\.items)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The persona itself is named by the glowing button above; like the day view,
                // the page only adds how much of it is done.
                HStack {
                    Spacer(minLength: 0)
                    if !items.isEmpty {
                        Text("\(items.filter(\.isComplete).count)/\(items.filter { !$0.isCancelled }.count) complete")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
                if days.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in \(persona.title) yet", systemImage: "circle.dashed")
                    } description: {
                        Text("Give an item the \(persona.title) persona and it will be gathered here, with everything before and after it.")
                    } actions: {
                        Button("Add an item", systemImage: "plus", action: add).buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 280)
                }
                ForEach(days) { entry in
                    Text(heading(entry.day))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(entry.items) { item in
                        row(item, day: entry.day)
                            .padding(.horizontal, 16)
                    }
                }
                Text("timo").font(.system(.footnote, design: .rounded).weight(.medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: items.map(\.id))
        }
        .scrollEdgeEffectHidden(true, for: .vertical)
    }
    private func heading(_ day: Day) -> String {
        let calendar = Calendar.current
        let date = day.date()
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
    private func row(_ item: PlanItem, day: Day, showsMenu: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item, on: day) }
            } label: {
                Image(systemName: item.stateSymbol)
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(item.isCancelled ? .tertiary : item.isComplete ? .secondary : .primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.completionActionLabel)
            .sensoryFeedback(.success, trigger: item.isComplete)
            Button { open(item) } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .settledTitleStyle(item)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.isCarried(now: now) {
                            Text("Carried from \(item.day.date().formatted(.dateTime.day().month(.abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        if item.seriesID != nil {
                            Image(systemName: "repeat").accessibilityHidden(true)
                        }
                        if let start = item.start() {
                            Text(start, format: .dateTime.hour().minute())
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 2).contentShape(Rectangle())
            }
            .buttonStyle(ItemCardPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue([
                item.start().map { $0.formatted(date: .omitted, time: .shortened) },
                item.seriesID != nil ? "Repeating" : nil,
                item.isCarried(now: now) ? "Carried from \(item.day.date().formatted(date: .abbreviated, time: .omitted))" : nil,
                item.isComplete ? "Completed" : nil,
                item.isCancelled ? "Cancelled" : nil
            ].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Open details and edit")
            .accessibilityAction(named: item.isCancelled ? "Uncancel" : "Cancel") {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.setCancelled(item, !item.isCancelled, on: day) }
            }
        }
        .modifier(ItemCard())
        .itemMenuOnHold(item, day: day, showsMenu: showsMenu) { AnyView(row(item, day: day, showsMenu: false)) }
    }
}

/// Each item sits on its own faint, slightly rounded card with a small gap to the next, quiet
/// enough to leave the title in charge. Increase Contrast makes the card a little firmer.
/// Pressing the item (its title, not its circle) settles the card in a touch, springing back on
/// release, without shading it: holding hands over to the system's own lift. Reduce Motion
/// keeps it still.
struct ItemCard: ViewModifier {
    /// Space between the card's trailing edge and the time; the day view's shared time label
    /// is placed outside the row, so it uses the same inset.
    static let trailingInset: CGFloat = 12
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set inside the lifted card, which draws one card around the row and its dates.
    @Environment(\.itemCardPlain) private var plain
    @State private var pressed = false

    static func tint(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.07 : 0.022)
    }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, Self.trailingInset)
            .padding(.vertical, 2)
            .environment(\.itemCardPressed, $pressed)
            .background(plain ? .clear : Self.tint(contrast), in: Self.shape)
            // Opaque underneath, so the native lift shows the card itself rather than the
            // dimmed screen through it.
            .background(plain ? .clear : Color(.systemBackground), in: Self.shape)
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            // A quick press in, then a soft spring back so letting go feels physical.
            .animation(reduceMotion ? nil : pressed ? .easeOut(duration: 0.1) : .spring(duration: 0.35, bounce: 0.3),
                       value: pressed)
    }
}

extension EnvironmentValues {
    /// The press state of the enclosing item card, set by `ItemCardPressStyle`.
    @Entry var itemCardPressed: Binding<Bool>? = nil
    /// Set by `ItemMenuOnHold` for the copy of the row inside the lifted card.
    @Entry var itemCardPlain = false
}

/// For the button that opens an item: its press is shown by the whole card rather than by
/// dimming the title, so the item reads as one thing being pressed.
struct ItemCardPressStyle: ButtonStyle {
    @Environment(\.itemCardPressed) private var cardPressed

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in cardPressed?.wrappedValue = isPressed }
            // A hold lifts the item into its menu while the button stays pressed; the card
            // behind lets go by then rather than staying pressed in under the dimmed screen.
            .task(id: configuration.isPressed) {
                guard configuration.isPressed else { return }
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled else { return }
                cardPressed?.wrappedValue = false
            }
    }
}

/// Holding an item lifts it, the native way: the rest of the screen dims, so it's clear which
/// item is held, and the item rises as its own card grown to show its history (created, and
/// completed or cancelled) under its details, with Cancel (or Uncancel) and Delete in the Liquid
/// Glass menu beneath. The lifted card is a copy of the row drawn by `preview` at the row's
/// width, with the history added. Cancelling acts on this item only, or this one occurrence of a repeating
/// item, on the day it is viewed from. Delete is the same for every item: a single item goes
/// straight away, and for a repeating one Delete opens, within the same menu, which occurrences
/// to delete. Either way an Undo button follows.
private struct ItemMenuOnHold<Preview: View>: ViewModifier {
    let item: PlanItem
    let day: Day
    let isEnabled: () -> Bool
    /// Off for the lifted copy of the row itself.
    let showsMenu: Bool
    @ViewBuilder let preview: () -> Preview
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.undoManager) private var undoManager
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if showsMenu {
            content
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
                .contentShape(.contextMenuPreview, ItemCard.shape)
                .contextMenu {
                    menuItems
                } preview: {
                    // One card: the row's own card is left plain, and this draws it around the
                    // row and its history together.
                    VStack(alignment: .leading, spacing: 0) {
                        preview()
                            .environment(\.itemCardPlain, true)
                        Text(item.history)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // In line with the title, past the completion circle.
                            .padding(.leading, 52).padding(.trailing, ItemCard.trailingInset)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: width)
                    .background(ItemCard.tint(contrast))
                    .background(Color(.systemBackground))
                }
                // The gap between cards stays outside what is lifted.
                .padding(.vertical, 3)
        } else {
            content
        }
    }
    @ViewBuilder private var menuItems: some View {
        Button {
            guard isEnabled() else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.setCancelled(item, !item.isCancelled, on: day) }
        } label: {
            if item.isCancelled {
                Label("Uncancel", systemImage: "arrow.uturn.backward.circle")
            } else {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }
        if item.seriesID == nil {
            Button(role: .destructive) {
                guard isEnabled() else { return }
                delete(.all)
            } label: {
                Label { Text("Delete") } icon: { Image.redTrash }
            }
        } else {
            // A submenu, shown with the system's chevron, so the choices open in place.
            Menu {
                RepeatDeletionButtons(item: item) { scope in
                    guard isEnabled() else { return }
                    delete(scope)
                }
            } label: {
                // A submenu can't take the destructive role in SwiftUI: the bin is drawn red
                // here, and DestructiveSubmenu reddens the title and chevron.
                Label { Text("Delete") } icon: { Image.redTrash }
            }
        }
    }
    private func delete(_ scope: RepeatDeletion) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            store.delete(item, children: false, scope: scope, undoManager: undoManager)
        }
    }
}

extension Image {
    /// The bin in system red, kept red by menus that would otherwise draw icons in black.
    static var redTrash: Image {
        Image(uiImage: UIImage(systemName: "trash")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal) ?? UIImage())
    }
}

extension View {
    func itemMenuOnHold<Preview: View>(_ item: PlanItem, day: Day, isEnabled: @escaping () -> Bool = { true },
                                       showsMenu: Bool = true, @ViewBuilder preview: @escaping () -> Preview) -> some View {
        modifier(ItemMenuOnHold(item: item, day: day, isEnabled: isEnabled, showsMenu: showsMenu, preview: preview))
    }
}

extension PlanItem {
    /// When the item was made, and when it was completed or cancelled.
    var history: String {
        var lines = ["Created " + Self.stamp(createdAt)]
        if let completedAt { lines.append("Completed " + Self.stamp(completedAt)) }
        if let cancelledAt { lines.append("Cancelled " + Self.stamp(cancelledAt)) }
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
        if store.startsSeries(item) {
            Button("Original item only", role: .destructive) { perform(.occurrence) }
        } else {
            Button("This linked item only", role: .destructive) { perform(.occurrence) }
            Button("This and following linked items", role: .destructive) { perform(.following) }
        }
        Button("Original and all linked items", role: .destructive) { perform(.all) }
    }
}

/// The Undo offered after a deletion: a small glass capsule above the dock naming what went,
/// like Mail's Undo Send. It stays a few seconds (longer with VoiceOver, which also announces
/// it); the system's own undo (shake, or three fingers) works as well.
struct UndoDeletionBar: View {
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        if let deletion = store.lastDeletion {
            HStack(spacing: 14) {
                Text("Deleted “\(deletion.title)”")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Button("Undo") {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { store.undo(deletion) }
                }
                .fontWeight(.semibold)
                .accessibilityHint("Puts back what was deleted")
            }
            .font(.subheadline)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectTransition(.materialize)
            .padding(.horizontal, 24)
            .task(id: deletion.id) {
                AccessibilityNotification.Announcement("Deleted \(deletion.title). Undo available.").post()
                try? await Task.sleep(for: .seconds(voiceOver ? 10 : 5))
                if store.lastDeletion?.id == deletion.id {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { store.lastDeletion = nil }
                }
            }
        }
    }
}

extension View {
    /// Completed titles are struck through and dimmed; cancelled ones fade further, so they
    /// read as called off rather than done.
    func settledTitleStyle(_ item: PlanItem) -> some View {
        foregroundStyle(item.isCancelled ? .tertiary : item.isComplete ? .secondary : .primary)
            .strikethrough(item.isSettled, pattern: .solid, color: Color.secondary.opacity(0.45))
    }
}

extension PlanItem {
    /// The completion circle: ticked when done, a quiet ✘ when cancelled, otherwise open.
    var stateSymbol: String { isComplete ? "checkmark.circle.fill" : isCancelled ? "xmark.circle" : "circle" }
    /// What tapping the circle does, for VoiceOver. A cancelled item's circle restores it.
    var completionActionLabel: String {
        isCancelled ? "Uncancel \(title)" : isComplete ? "Mark \(title) incomplete" : "Complete \(title)"
    }
}
