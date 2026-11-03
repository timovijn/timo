import SwiftUI

/// Whether search is open, and how far the page on screen is pulled down past its top, which
/// stretches the search button. Only the page on screen has it in its environment, so a
/// neighbour's bounce never counts.
@Observable @MainActor final class SearchPull {
    /// How far past its top the page is held, while a finger is on it.
    var distance: CGFloat = 0
    var isOpen = false
    /// Whether the glass has the field's shape; until then a pull shapes it.
    private(set) var isField = false
    /// What is typed; the day view filters and counts its results too.
    var query = ""
    /// The persona button's trailing edge and middle on screen, which the search button sits beside.
    var anchor = CGPoint(x: 130, y: 84)
    /// Whether a pull may open search now; not while the calendar is open, say.
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    static let threshold: CGFloat = 70
    /// How much further a pull goes on widening the button into the field, the same path a tap
    /// takes, so letting go anywhere past the threshold only finishes it.
    static let widenDistance: CGFloat = 90
    var progress: CGFloat { min(max(distance / Self.threshold, 0), 1) }
    var widening: CGFloat { min(max((distance - Self.threshold) / Self.widenDistance, 0), 1) }
    /// How far along its path the glass is: 0 the button beside the persona button, 1 dropped
    /// into the field's row and stretched, 2 the field. A pull moves it with the finger, and
    /// opening and closing animate it, so a tap and a pull take the same path.
    var phase: CGFloat { isField ? 2 : progress + widening }

    /// The one animation the button grows into the field with, and folds back with.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)
    }
    func open(reduceMotion: Bool) {
        // Run the morph at the display's full rate, like the calendar's.
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(800)) }
        // From wherever a pull left it, or from the button for a tap.
        withAnimation(Self.animation(reduceMotion: reduceMotion)) {
            distance = 0
            isOpen = true
            isField = true
        }
    }
    func close(reduceMotion: Bool) {
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(800)) }
        withAnimation(Self.animation(reduceMotion: reduceMotion)) {
            isOpen = false
            isField = false
        }
    }
}

/// Hands its content the glass's phase and the persona button's edge frame by frame while they
/// animate, so the glass follows its path (down into the field's row, then across it) instead of
/// a straight line between its ends, which would pass over the persona button.
private struct SearchGlassPath<Content: View>: View, Animatable {
    var phase: CGFloat
    var anchorX: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(phase, anchorX) }
        set { phase = newValue.first; anchorX = newValue.second }
    }
    // A spring's overshoot stops at the ends of the path.
    var body: some View { content(min(max(phase, 0), 2), anchorX) }
}

/// Reports a page's pull past its top to the search button, and opens search when a pull past
/// the threshold is let go. A fling that bounces at the top doesn't count: only a held pull.
struct PullsToSearch: ViewModifier {
    @Environment(SearchPull.self) private var pull: SearchPull?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holding = false
    @State private var overscroll: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, value in
                overscroll = value
                if holding, let pull, !pull.isOpen, pull.isEnabled() { pull.distance = value }
            }
            .onScrollPhaseChange { old, phase in
                if phase == .interacting { holding = true; return }
                guard old == .interacting else { return }
                holding = false
                guard let pull, !pull.isOpen else { return }
                if overscroll >= SearchPull.threshold, pull.isEnabled() {
                    pull.open(reduceMotion: reduceMotion)
                } else if pull.distance > 0 {
                    withAnimation(.smooth(duration: 0.25)) { pull.distance = 0 }
                }
            }
    }
}

/// Hides the page under search, below the top controls so they stay in reach. With nothing
/// typed, a tap or a swipe anywhere on it leaves search.
struct SearchBackdrop: View {
    let search: SearchPull
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .opacity(search.isOpen ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { if search.query.isEmpty { search.close(reduceMotion: reduceMotion) } }
            // A swipe in any direction leaves it too.
            .gesture(DragGesture(minimumDistance: 24).onEnded { _ in
                if search.query.isEmpty { search.close(reduceMotion: reduceMotion) }
            })
            .allowsHitTesting(search.isOpen)
            .accessibilityHidden(true)
    }
}

/// Search, over the day view and persona pages alike. The round search button beside the persona
/// button is the same piece of glass as the search field: a pull draws it down and stretches it,
/// and tapping it or letting go of the pull grows it into the field in a row of its own under the
/// top controls, while the page fades out behind it. The persona and filter buttons stay above it:
/// the persona scopes the results and the filters narrow them. Results are the day list's own
/// rows, so they complete, open and lift just as they do there. Closing folds the field back up
/// into the button.
struct SearchLayer: View {
    let pull: SearchPull
    let now: Date
    /// Already scoped to the persona and narrowed by the filter.
    let results: [PersonaDay]
    /// The persona the results are scoped to, if any.
    let persona: Persona?
    /// Whether repeating items go on past the ones listed, and how to list three more months.
    let showsMore: Bool
    let showMore: () -> Void
    let row: (PlanItem, Day) -> AnyView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @FocusState private var focused: Bool
    private var query: String { pull.query }
    /// A pull reaching the threshold, with a tap to say so.
    private var armed: Bool { pull.progress >= 1 }
    /// The top controls' row and the height of the bar they sit in.
    private let rowHeight: CGFloat = 44

    var body: some View {
        let isOpen = pull.isOpen
        GeometryReader { geometry in
            let width = geometry.size.width
            let block = min(width - 32, 680)
            let leading = (width - block) / 2
            let fieldWidth = block - rowHeight - 8
            // The top controls' row, and the field's own row under it.
            let topRow = pull.anchor.y - geometry.frame(in: .global).minY
            let fieldRow = topRow + rowHeight + 8
            ZStack(alignment: .top) {
                // Only once something is typed, so the empty screen is the backdrop's to tap.
                if isOpen && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    resultList
                        // Below the field's row, so results never scroll over the top controls.
                        .padding(.top, fieldRow + rowHeight / 2 + 4)
                        .clipped()
                        // Out quickly, so nothing lingers over the page as it comes back.
                        .transition(.asymmetric(
                            insertion: reduceMotion ? .opacity
                                : .opacity.combined(with: .offset(y: 16)).animation(.easeOut(duration: 0.3).delay(0.08)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                }
                SearchGlassPath(phase: pull.phase, anchorX: pull.anchor.x) { phase, anchorX in
                    // At rest a circle beside the persona button (whose glass reaches 5 points
                    // past what it reports); along its path it drops into the field's row and
                    // stretches, then widens across it, its end passing under the persona button.
                    let drop = min(phase, 1)
                    let widen = max(phase - 1, 0)
                    let buttonWidth = rowHeight + 80 * drop
                    let buttonLeading = anchorX + 5 + 8
                    let glassWidth = buttonWidth + (fieldWidth - buttonWidth) * widen
                    let glassLeading = buttonLeading + (leading - buttonLeading) * widen
                    let glassRow = topRow + (fieldRow - topRow) * drop
                    // The ✕ grows out of its end once it is the field, opened or pulled; closing, it
                    // merges back at once.
                    let showsClose = phase >= 1.99 && (isOpen || pull.distance > 0)
                    GlassEffectContainer(spacing: 8) {
                        ZStack {
                            field(isOpen: isOpen, phase: phase)
                                .frame(width: glassWidth, height: rowHeight, alignment: .leading)
                                .contentShape(.capsule)
                                // Always interactive: switching it rebuilt the glass and stalled the morph's start.
                                .glassEffect(.regular.interactive(), in: .capsule)
                                .glassEffectID("field", in: glass)
                                // Under Reduce Motion the button and the field cross-fade instead of morphing.
                                .id(reduceMotion ? isOpen : false)
                                .gesture(TapGesture().onEnded { pull.open(reduceMotion: reduceMotion) }, isEnabled: !isOpen)
                                .position(x: glassLeading + glassWidth / 2, y: glassRow)
                                // At rest it is the search button; open, its field and clear button are reached inside.
                                .accessibilityElement(children: isOpen ? .contain : .ignore)
                                .accessibilityLabel(isOpen ? "" : "Search")
                                .accessibilityHint(isOpen ? "" : "Finds items on any day. Pulling a page down also opens it")
                                .accessibilityAddTraits(isOpen ? [] : .isButton)
                                .accessibilityAction { if !pull.isOpen { pull.open(reduceMotion: reduceMotion) } }
                            if showsClose {
                                closeButton
                                    .glassEffectID("close", in: glass)
                                    .position(x: leading + block - rowHeight / 2, y: fieldRow)
                            }
                        }
                        .animation(.smooth(duration: 0.3), value: showsClose)
                        .frame(width: width, height: geometry.size.height)
                    }
                }
                // Follows the persona button as its name changes width.
                .animation(.smooth(duration: 0.25), value: pull.anchor.x)
            }
        }
        .ignoresSafeArea(.container)
        .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, armed in armed }
        .onChange(of: isOpen) { _, isOpen in
            if isOpen {
                // Once the field has landed: bringing the keyboard up with the morph stalled its start.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 360))
                    if pull.isOpen { focused = true }
                }
            } else {
                focused = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    // Once folded away, so the field doesn't empty on the way.
                    if !pull.isOpen { pull.query = "" }
                }
            }
        }
        // With nothing typed, the keyboard stays up: there is nothing to look at without it.
        .onChange(of: focused) { _, isFocused in
            // On the next turn: set inside the focus change itself, it was ignored.
            guard !isFocused, pull.isOpen, query.isEmpty else { return }
            Task { @MainActor in if pull.isOpen, query.isEmpty { focused = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOpen ? .isModal : [])
        .accessibilityAction(.escape) { pull.close(reduceMotion: reduceMotion) }
    }
    /// The button's icon and label are the field's own: the label becomes its placeholder.
    /// Along the path it is the button until it reaches the field's row (phase 1), where the
    /// label fades in beside the icon, set by the phase frame by frame so a pull and a tap show
    /// the same thing. The icon keeps to the leading edge, where the field has it; in the round
    /// button that is its middle.
    private func field(isOpen: Bool, phase: CGFloat) -> some View {
        let isField = isOpen && phase >= 1
        let reveal = min(max((phase - 0.85) / 0.3, 0), 1)
        // Closing, the label is gone at once, like typed text; while a pull holds it, it shows.
        let showsLabel = reveal > 0 && (isOpen ? query.isEmpty : pull.distance > 0)
        // 12 points either side of it in the 44-point button.
        let iconWidth: CGFloat = 20
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                // One colour in both: animating to a semantic style flashed it white.
                .foregroundStyle(Color.primary.opacity(0.42))
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            // Left out until there is something in it: even empty, it took the row's spacing
            // and pushed the button's icon off centre.
            if isField || showsLabel {
                ZStack(alignment: .leading) {
                    if showsLabel {
                        Text("Search")
                            .foregroundStyle(isOpen ? Color(.placeholderText) : Color.primary.opacity(0.42))
                            .opacity(reveal)
                            // Out at once, like typed text.
                            .transition(.asymmetric(insertion: .identity,
                                                    removal: .opacity.animation(.easeOut(duration: 0.08))))
                            .accessibilityHidden(true)
                    }
                    if isField {
                        // No prompt of its own: the label above is the placeholder.
                        TextField("", text: Binding(get: { pull.query }, set: { pull.query = $0 }))
                            .focused($focused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            // Gone before the field narrows, rather than squeezed into the button.
                            .transition(.opacity.animation(.easeOut(duration: 0.08)))
                            .labelsHidden()
                            .accessibilityLabel("Search")
                            .accessibilityHint("Finds items on any day by title, notes, people or location")
                    }
                }
                .frame(maxWidth: isField ? .infinity : nil, alignment: .leading)
                .font(.body)
                // Its own quick fade: removed with the close's spring, the text lingered over the page.
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
            if isField && !query.isEmpty {
                Button { pull.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .fixedSize(horizontal: !isField, vertical: false)
    }
    private var closeButton: some View {
        Button { pull.close(reduceMotion: reduceMotion) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .frame(width: rowHeight, height: rowHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close search")
    }
    /// Shown only once something is typed.
    private var resultList: some View {
        ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The furthest days are at the top, so more of them come in above.
                if showsMore {
                    MoreRepeatsButton {
                        let top = results.first?.day
                        showMore()
                        // Stay where the list was; the new months are above.
                        if let top {
                            Task { @MainActor in
                                // Once the new days are laid out: before, it scrolled to where they'd go.
                                try? await Task.sleep(for: .milliseconds(60))
                                proxy.scrollTo(top, anchor: .top)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 12)
                }
                ForEach(results) { entry in
                    Text(PersonaHistoryView.heading(entry.day, now: now))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                        .id(entry.day)
                    ForEach(entry.items) { item in
                        row(item, entry.day).padding(.horizontal, 16)
                    }
                }
            }
            .readableWidth()
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: results.flatMap(\.items).map(\.id))
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectHidden(true, for: .vertical)
        // Opens on today, with what's ahead above it, as the query, persona or filter changes.
        .onChange(of: [query, persona?.rawValue ?? "", "\(results.count)"], initial: true) {
            if let target = PersonaHistoryView.todayAnchor(results, now: now) { proxy.scrollTo(target, anchor: .top) }
        }
        }
        .overlay {
            if results.isEmpty {
                let text = query.trimmingCharacters(in: .whitespaces)
                if let persona {
                    // Not a spelling problem: the persona is what leaves it out.
                    ContentUnavailableView("No Results in \(persona.title)", systemImage: "magnifyingglass",
                                           description: Text("Nothing in \(persona.title) matches “\(text)”. Choose All to search everything."))
                } else {
                    ContentUnavailableView.search(text: text)
                }
            }
        }
    }
}
