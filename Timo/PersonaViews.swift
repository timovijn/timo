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
                        Text("\(items.filter(\.isComplete).count)/\(items.count) complete")
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
                            .padding(.leading, 12).padding(.trailing, 20)
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
    private func row(_ item: PlanItem, day: Day) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { store.toggle(item, on: day) }
            } label: {
                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(item.isComplete ? .secondary : .primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isComplete ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
            .sensoryFeedback(.success, trigger: item.isComplete)
            Button { open(item) } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .foregroundStyle(item.isComplete ? .secondary : .primary)
                            .strikethrough(item.isComplete, pattern: .solid, color: Color.secondary.opacity(0.45))
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
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue([
                item.start().map { $0.formatted(date: .omitted, time: .shortened) },
                item.seriesID != nil ? "Repeating" : nil,
                item.isCarried(now: now) ? "Carried from \(item.day.date().formatted(date: .abbreviated, time: .omitted))" : nil,
                item.isComplete ? "Completed" : nil
            ].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Open details and edit")
        }
        .deletableOnHold(item)
    }
}

/// A tidy card of an item, shown above its menu while the item is held.
struct ItemPreview: View {
    let item: PlanItem
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 300

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium)).foregroundStyle(.primary)
                    .strikethrough(item.isComplete, color: .secondary)
                    .lineLimit(3)
                Text(when).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: min(width, 360), alignment: .leading)
        .background(Color(.systemBackground))
    }
    private var when: String {
        let day = item.day.date()
        let calendar = Calendar.current
        let dayText = calendar.isDateInToday(day) ? "Today" : calendar.isDateInTomorrow(day) ? "Tomorrow"
            : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        guard let start = item.start() else { return dayText }
        return dayText + " · " + start.formatted(date: .omitted, time: .shortened)
    }
}

/// Holding an item shows its card with a Delete option. A single item is deleted straight
/// away; a repeating one asks first, beside the item, since every occurrence goes with it.
private struct DeletableOnHold: ViewModifier {
    let item: PlanItem
    let isEnabled: () -> Bool
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingSeries = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(role: .destructive) {
                    guard isEnabled() else { return }
                    if item.seriesID == nil { delete() } else { confirmingSeries = true }
                } label: {
                    Label(item.seriesID == nil ? "Delete" : "Delete repeating item", systemImage: "trash")
                }
                .tint(.red)
            } preview: {
                ItemPreview(item: item)
            }
            .confirmationDialog("Delete all occurrences of this repeating item?", isPresented: $confirmingSeries, titleVisibility: .visible) {
                Button("Delete all occurrences", role: .destructive, action: delete)
            }
    }
    private func delete() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { store.delete(item, children: false) }
    }
}

extension View {
    func deletableOnHold(_ item: PlanItem, isEnabled: @escaping () -> Bool = { true }) -> some View {
        modifier(DeletableOnHold(item: item, isEnabled: isEnabled))
    }
}
