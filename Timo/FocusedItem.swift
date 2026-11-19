import SwiftUI
import UIKit

/// Inline focus reveals these mounted details inside the original ItemCard, like a filter panel.
struct InlineFocusedDetails: View {
    // The header already contributes eight points below its text.
    static let topInset: CGFloat = 4
    let item: PlanItem
    let day: Day
    let expanded: Bool
    let token: UUID?
    let close: () -> Void
    /// Opens a copy of the item in the editor, as "Duplicate item".
    let duplicate: (PlanItem) -> Void
    let collapsed: (UUID) -> Void
    let contentChanged: () -> Void
    let heightChanged: (CGFloat) -> Void
    @EnvironmentObject private var store: PlanStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Both choice groups stay mounted so rapid taps can reverse the same native animation.
    @State private var choices: Choices?
    private enum Choices: Int { case push = 1, delete = 2 }
    @State private var naturalHeight: CGFloat = 0
    @State private var presentedItem: PlanItem?
    @State private var fullyClosed = true

    var body: some View {
        // Freeze only the closing phase. Once hidden, measure the current actions so the next
        // opening reveals the new layout instead of rearranging the old one as it expands.
        let displayedItem = expanded || fullyClosed ? item : (presentedItem ?? item)
        return VStack(alignment: .leading, spacing: 10) {
            // Attachments sit one pill gap above the actions, like a wrapped row of them.
            VStack(alignment: .leading, spacing: 6) {
                if !displayedItem.checklist.isEmpty {
                    ChecklistCard(item: displayedItem)
                }
                if !displayedItem.attachments.isEmpty {
                    AttachmentPills(attachments: .constant(displayedItem.attachments))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                FocusedActionsLayout(spacing: 6) {
                    actions(displayedItem)
                    if !displayedItem.isSettled {
                        choiceGroup(.push) {
                            ForEach(PushInterval.allCases) { interval in
                                Button(interval.title) { push(interval) }
                                    .accessibilityHint(Text("Moves this item to \(interval.day(after: day).date().formatted(.dateTime.weekday(.wide).day().month(.wide)))"))
                            }
                        }
                    }
                    if displayedItem.seriesID != nil {
                        choiceGroup(.delete) {
                            ForEach(RepeatDeletionButtons.choices(startsSeries: store.startsSeries(item)), id: \.scope) { choice in
                                Button(choice.title, role: .destructive) { delete(choice.scope) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Move the action container as one unit, including a relabelled Cancel pill.
                .geometryGroup()
            }
        }
        .padding(.leading, 52).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(FocusedButtonStyle())
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            naturalHeight = height
            if expanded { heightChanged(height) }
        }
        .frame(height: expanded ? nil : 0, alignment: .top)
        .clipped()
        .padding(.top, expanded ? Self.topInset : 0)
        .opacity(expanded ? 1 : 0)
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
        .accessibilityAction(.escape, close)
        .modifier(InlineFocusCompletion(progress: expanded ? 1 : 0) {
            guard !expanded else { return }
            refreshClosedContent()
            if let token { collapsed(token) }
        })
        .onChange(of: expanded, initial: true) { _, expanded in
            if expanded {
                fullyClosed = false
                presentedItem = item
                heightChanged(naturalHeight)
            } else if reduceMotion {
                refreshClosedContent()
            }
        }
        .onChange(of: item) { _, item in
            if expanded { presentedItem = item }
        }
    }

    private func refreshClosedContent() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fullyClosed = true
            presentedItem = item
            choices = nil
        }
    }

    @ViewBuilder
    private func actions(_ displayedItem: PlanItem) -> some View {
        if !displayedItem.isSettled, displayedItem.minute != nil || displayedItem.endDay != nil {
            Button {
                guard let current = store.item(item.id) else { return }
                if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
                close()
                withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
                    store.startNow(current)
                    contentChanged()
                }
            } label: {
                Label("Start now", systemImage: "play.circle")
            }
            .accessibilityHint("Moves this item to start today at the current time, keeping its duration")
        }
        if !displayedItem.isSettled {
            Button { toggle(.push) } label: {
                Label("Push", systemImage: choices == .push ? "arrow.forward.circle.fill" : "arrow.forward.circle")
            }
            .buttonStyle(FocusedButtonStyle(selected: choices == .push))
            .layoutValue(key: FocusedActionsLayout.Owner.self, value: Choices.push.rawValue)
            .accessibilityAddTraits(choices == .push ? .isSelected : [])
            .accessibilityValue(choices == .push ? "Showing choices" : "")
            .accessibilityHint("Moves this item to the next day, week or month")
        }
        Button {
            guard let current = store.item(item.id) else { return }
            close()
            duplicate(current.on(day).duplicate())
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .accessibilityHint("Opens a copy of this item to change and save")
        if CloudSync.isAvailable {
            Button {
                close()
                SharingSheet.present(for: item, cloud: store.cloud)
            } label: {
                Label("Share", systemImage: "person.2")
            }
        }
        Button {
            guard let current = store.item(item.id) else { return }
            if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
            // Done with the item, like Start now: the menu closes as the change shows.
            close()
            withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
                store.setCancelled(current, !current.on(day).isCancelled, on: day)
                contentChanged()
            }
        } label: {
            Label(displayedItem.isCancelled ? "Uncancel" : "Cancel",
                  systemImage: displayedItem.isCancelled ? "arrow.uturn.backward.circle" : "xmark.circle")
                .contentTransition(.opacity)
        }
        Button(role: .destructive) {
            if item.seriesID == nil { delete(.all) } else { toggle(.delete) }
        } label: { Label("Delete", systemImage: choices == .delete ? "trash.fill" : "trash") }
        // Held down while its choices show, so it reads as the pill they belong to.
        .buttonStyle(FocusedButtonStyle(selected: choices == .delete))
        .layoutValue(key: FocusedActionsLayout.Owner.self, value: Choices.delete.rawValue)
        .accessibilityAddTraits(choices == .delete ? .isSelected : [])
        .accessibilityValue(choices == .delete ? "Showing choices" : "")
    }

    private func choiceGroup<Content: View>(_ pill: Choices, @ViewBuilder content: () -> Content) -> some View {
        FlowLayout(spacing: 6) { content() }
        // Match the filter/details reveal: measure the full endpoint before animating its frame.
        // An animatable nested Layout exposed an intermediate height to the row's size cache.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
        .frame(height: choices == pill ? nil : 0, alignment: .top)
        .clipped()
        .opacity(choices == pill ? 1 : 0)
        .allowsHitTesting(choices == pill)
        .accessibilityHidden(choices != pill)
        .layoutValue(key: FocusedActionsLayout.ChoiceOwner.self, value: pill.rawValue)
    }

    /// One reversible animation for the reveal, the other action rows and the selected fill.
    private func toggle(_ pill: Choices) {
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(500)) }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            choices = choices == pill ? nil : pill
            contentChanged()
        }
    }
    private func push(_ interval: PushInterval) {
        guard let current = store.item(item.id) else { return }
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
        // Done with the item, like Start now: the menu closes as it moves away.
        close()
        withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
            store.push(current, from: day, by: interval, undoManager: undoManager)
            contentChanged()
        }
    }

    private func delete(_ scope: RepeatDeletion) {
        if !reduceMotion { FrameRateBoost.shared.request(for: .milliseconds(700)) }
        // Remove the expanded card as one piece. A separate close would also collapse its
        // details during removal, starting a second layout animation on the same rows.
        withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
            store.delete(item, children: false, scope: scope, undoManager: undoManager)
        }
    }
}

/// Normal-sized choice groups sit below their action's row; the remaining rows move as a unit.
private struct FocusedActionsLayout: Layout {
    var spacing: CGFloat
    struct Owner: LayoutValueKey { static let defaultValue = 0 }
    struct ChoiceOwner: LayoutValueKey { static let defaultValue = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = arrange(proposal.width ?? .infinity, subviews).size
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : size.width } ?? size.width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { view in
            var size = view.sizeThatFits(view[ChoiceOwner.self] == 0
                ? .unspecified : ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, width)
            return size
        }
        var lines: [[Int]] = [], x: CGFloat = 0
        for index in subviews.indices where subviews[index][ChoiceOwner.self] == 0 {
            if let last = lines.last, !last.isEmpty, x + sizes[index].width <= width + 0.5 {
                lines[lines.count - 1].append(index)
            } else {
                lines.append([index]); x = 0
            }
            x += sizes[index].width + spacing
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0, maxX: CGFloat = 0
        for line in lines {
            x = 0
            var height: CGFloat = 0
            for index in line {
                frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: sizes[index])
                x += sizes[index].width + spacing
                height = max(height, sizes[index].height)
            }
            maxX = max(maxX, x - spacing)
            y += height + spacing
            for owner in line.map({ subviews[$0][Owner.self] }) where owner != 0 {
                for index in subviews.indices where subviews[index][ChoiceOwner.self] == owner {
                    frames[index] = CGRect(origin: CGPoint(x: 0, y: y), size: sizes[index])
                    y += sizes[index].height
                }
            }
        }
        return (frames, CGSize(width: maxX, height: max(0, y - spacing)))
    }
}

/// Observe the row's own animation; no timer or source/overlay handover is needed.
private struct InlineFocusCompletion: AnimatableModifier {
    var progress: CGFloat
    var completion: () -> Void
    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            if newValue == 0 {
                let completion = completion
                DispatchQueue.main.async { completion() }
            }
        }
    }
    func body(content: Content) -> some View { content }
}

/// Focus presentation and its existing timeline graphics share one motion policy.
/// The filter animation remains independent.
enum FocusedItemMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.5)
    }
}

private struct FocusedActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// A compact capsule with its icon and title centered as one group. `selected` keeps it looking
/// pressed, in a tint of its colour, like Delete while a repeating item's choices are open.
private struct FocusedButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(FocusedActionLabelStyle())
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
            // Size each pill from its label, independent of the row’s available width.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(minHeight: 36, alignment: .center)
            .background(fill(configuration), in: .capsule)
            .contentShape(.capsule)
    }
    private func fill(_ configuration: Configuration) -> Color {
        guard selected else { return Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07) }
        let tint = configuration.role == .destructive ? Color.red : .primary
        return tint.opacity(configuration.isPressed ? 0.24 : 0.16)
    }
}

private struct ItemFocus: ViewModifier {
    let id: UUID
    let day: Day
    let isEnabled: () -> Bool
    let focus: () -> Void
    private func start() {
        guard isEnabled(), FocusedCardAnchor.focus(id, on: day) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    func body(content: Content) -> some View {
        content
            .gesture(ItemHold(isEnabled: isEnabled, began: start))
            .background(FocusedCardAnchor(id: id, day: day, focus: focus, canFocus: isEnabled))
            .accessibilityAction(named: "Show details and actions", start)
            .padding(.vertical, 3)
    }
}

/// A long press can fail to a scroll without a zero-distance drag taking over the row.
private struct ItemHold: UIGestureRecognizerRepresentable {
    let isEnabled: () -> Bool
    let began: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 10
        // Recognition cancels the Button tap from this same touch, not the scroll view's pan.
        hold.cancelsTouchesInView = true
        hold.delegate = context.coordinator
        return hold
    }
    func updateUIGestureRecognizer(_ hold: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.isEnabled = isEnabled
    }
    func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
        switch hold.state {
        case .began:
            guard isEnabled() else { return }
            FocusedCardAnchor.isHolding = true
            began()
        case .ended, .cancelled, .failed:
            DispatchQueue.main.async { FocusedCardAnchor.isHolding = false }
        default: break
        }
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isEnabled: isEnabled)
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: () -> Bool
        init(isEnabled: @escaping () -> Bool) { self.isEnabled = isEnabled }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { isEnabled() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

extension View {
    func itemFocus(_ id: UUID, day: Day, isEnabled: @escaping () -> Bool = { true },
                   focus: @escaping () -> Void) -> some View {
        modifier(ItemFocus(id: id, day: day, isEnabled: isEnabled, focus: focus))
    }
}

/// An invisible marker in each row, saying where its card is on screen. Asking only when an item
/// takes focus means scrolling never has to report every row's place.
struct FocusedCardAnchor: UIViewRepresentable {
    let id: UUID
    var day: Day? = nil
    let focus: () -> Void
    var canFocus: () -> Bool = { true }

    final class Marker: UIView {
        var id = UUID()
        var day: Day?
        var focus: () -> Void = {}
        var canFocus: () -> Bool = { true }
        /// Timeline rows have a List and a Time view copy, and neighbouring days are laid out
        /// beside the page, so this is the copy on show.
        var isShowing: Bool {
            guard let window else { return false }
            let frame = convert(bounds, to: nil)
            guard frame.maxX > 0, frame.minX < window.bounds.maxX else { return false }
            var view: UIView? = self
            while let current = view {
                if current.isHidden || current.alpha < 0.01 || current.layer.opacity < 0.01 { return false }
                view = current.superview
            }
            return true
        }
        /// Which markers this one is kept among.
        var table = FocusedCardAnchor.markers
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { table.add(self) }
            else { table.remove(self) }
        }
    }
    @MainActor fileprivate static let markers = NSHashTable<Marker>.weakObjects()
    /// Retain the exact row copy that opened focus for hit testing and bottom fitting.
    @MainActor private static weak var focussedSource: Marker?

    fileprivate static func source(for id: UUID) -> Marker? {
        guard let source = focussedSource, source.id == id else { return nil }
        return source
    }

    /// Used by a simultaneous tap observer; it never participates in hit testing.
    static func contains(_ point: CGPoint, id: UUID, day: Day) -> Bool {
        guard let source = source(for: id), source.day == day, source.window != nil else { return false }
        return source.convert(source.bounds, to: nil).contains(point)
    }

    @MainActor static var isHolding = false
    @MainActor private static var inlineOriginalHeight: CGFloat = 0
    @MainActor private static var inlineExtraHeight: CGFloat = 0
    @MainActor private static var inlineRevealGeneration = 0

    /// One native scroll animation per details size, with a fixed destination.
    static func revealInline(_ id: UUID, extraHeight: CGFloat, animated: Bool) {
        guard extraHeight > 0, extraHeight != inlineExtraHeight, let source = source(for: id) else { return }
        inlineExtraHeight = extraHeight
        let generation = inlineRevealGeneration
        DispatchQueue.main.async { [weak source] in
            guard generation == inlineRevealGeneration, let source, source === Self.source(for: id), source.window != nil else { return }
            var ancestor = source.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.layoutIfNeeded()
                    let frame = source.convert(source.bounds, to: scroll)
                    let insets = scroll.adjustedContentInset
                    let bottom = frame.minY + inlineOriginalHeight + extraHeight
                    let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - insets.bottom - 16
                    if bottom > visibleBottom {
                        let maximum = max(-insets.top, scroll.contentSize.height + insets.bottom - scroll.bounds.height)
                        let y = min(maximum, scroll.contentOffset.y + bottom - visibleBottom)
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: animated)
                    }
                    break
                }
                ancestor = view.superview
            }
        }
    }

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Marker, context: Context) {
        view.id = id
        view.day = day
        view.focus = focus
        view.canFocus = canFocus
    }

    private static func marker(of id: UUID, on day: Day? = nil) -> Marker? {
        markers.allObjects.first { $0.id == id && (day == nil || $0.day == day) && $0.isShowing && $0.canFocus() }
    }
    /// Focusses the row's card. False when it isn't on show.
    static func focus(_ id: UUID, on day: Day? = nil) -> Bool {
        guard let marker = marker(of: id, on: day) else { return false }
        focus(marker)
        return true
    }
    private static func focus(_ marker: Marker) {
        focussedSource = marker
        inlineRevealGeneration += 1
        inlineOriginalHeight = marker.bounds.height
        inlineExtraHeight = 0
        marker.focus()
    }

    /// A closing or removed focus must not apply a queued bottom-fitting scroll.
    static func cancelPendingReveal() { inlineRevealGeneration += 1 }

    /// Scrolls the card to the middle of the page and focusses it through its row, as a hold
    /// does, so it looks the same however it came. False while the row isn't laid out yet. For a
    /// Live Activity, whose item can be anywhere on the page.
    static func focusCentred(_ id: UUID) -> Bool {
        guard let marker = marker(of: id) else { return false }
        var ancestor = marker.superview
        while let view = ancestor {
            if let scroller = view as? UIScrollView, scroller.contentSize.height > scroller.bounds.height {
                let frame = marker.convert(marker.bounds, to: scroller)
                let inset = scroller.adjustedContentInset
                let lowest = scroller.contentSize.height + inset.bottom - scroller.bounds.height
                let y = max(-inset.top, min(frame.midY - scroller.bounds.height / 2, lowest))
                scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: y), animated: false)
                scroller.layoutIfNeeded()
                break
            }
            ancestor = view.superview
        }
        focus(marker)
        return true
    }
}
