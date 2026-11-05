import SwiftUI
import UIKit

/// Inline focus reveals these mounted details inside the original ItemCard, like a filter panel.
struct InlineFocusedDetails: View {
    let item: PlanItem
    let day: Day
    let expanded: Bool
    let token: UUID?
    let close: () -> Void
    let collapsed: (UUID) -> Void
    let contentChanged: () -> Void
    let heightChanged: (CGFloat) -> Void
    @EnvironmentObject private var store: PlanStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosingDeletion = false
    @State private var naturalHeight: CGFloat = 0
    @State private var closingItem: PlanItem?

    var body: some View {
        let displayedItem = closingItem ?? item
        return VStack(alignment: .leading, spacing: 10) {
            Text(displayedItem.history)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { actions(displayedItem) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) { actions(displayedItem) }
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Move the action container as one unit, including a relabelled Cancel pill.
            .geometryGroup()
            if choosingDeletion {
                VStack(alignment: .leading, spacing: 6) {
                    RepeatDeletionButtons(item: item) { delete($0) }
                }
                .transition(.opacity)
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
        .padding(.top, expanded ? 3 - 8 : 0)
        .opacity(expanded ? 1 : 0)
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
        .accessibilityAction(.escape, close)
        .modifier(InlineFocusCompletion(progress: expanded ? 1 : 0) {
            if let token { collapsed(token) }
        })
        .onChange(of: expanded) { _, expanded in
            if expanded { heightChanged(naturalHeight) }
        }
        .onChange(of: token) { _, token in
            closingItem = nil
            if token == nil { choosingDeletion = false }
        }
    }

    @ViewBuilder
    private func actions(_ displayedItem: PlanItem) -> some View {
        if CloudSync.isAvailable {
            Button {
                SharingSheet.present(for: item, cloud: store.cloud)
            } label: {
                Label("Share", systemImage: "person.2")
            }
        }
        Button {
            // Keep the pressed label and history at their old size during collapse.
            closingItem = item
            withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
                close()
                store.setCancelled(item, !item.isCancelled, on: day)
            }
        } label: {
            Label(displayedItem.isCancelled ? "Uncancel" : "Cancel",
                  systemImage: displayedItem.isCancelled ? "arrow.uturn.backward.circle" : "xmark.circle")
                .contentTransition(.opacity)
        }
        Button(role: .destructive) {
            if item.seriesID == nil { delete(.all) }
            else {
                withAnimation(FocusedItemMotion.animation(reduceMotion: reduceMotion)) {
                    choosingDeletion.toggle()
                    contentChanged()
                }
            }
        } label: { Label("Delete", systemImage: "trash") }
        .accessibilityValue(choosingDeletion ? "Showing choices" : "")
    }

    private func delete(_ scope: RepeatDeletion) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            store.delete(item, children: false, scope: scope, undoManager: undoManager)
        }
        close()
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

/// A compact capsule with its icon and title centered as one group.
private struct FocusedButtonStyle: ButtonStyle {
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
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: .capsule)
            .contentShape(.capsule)
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
