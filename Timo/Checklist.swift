import SwiftUI

/// The editor's checklist: one line of pills, like places and people. Each pill is an entry: tap
/// its circle to tick it off, type in it to rename it, and its ✘ removes it. The dashed pill at the
/// end turns into a new pill to type in; Return keeps what's typed as an entry and leaves the pill
/// empty for the next one, so a list goes in without the keyboard going down. Return in the empty
/// pill ends the list, and pasting several lines makes an entry of each.
///
/// The fields are `ChecklistPillField`s (UIKit text fields), which handle Return themselves rather
/// than ending editing, so the keyboard stays up from one entry to the next.
struct ChecklistEditor: View {
    @Binding var entries: [ChecklistEntry]
    /// The new pill's text, owned by the editor so Save can include it before Return.
    @Binding var draft: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focus: Field?
    @State private var adding = false
    /// Counts the times a typed draft became an entry. The new pill's field still has the
    /// keyboard then, and a field with the keyboard owns its text, so this tells it to clear.
    @State private var draftsKept = 0
    /// The entry held and being dragged to a new place, where it was grabbed (from its corner)
    /// and where the finger is, in the checklist's own space.
    @State private var dragging: UUID?
    @State private var grab = CGSize.zero
    @State private var finger = CGPoint.zero
    /// Whether the held pill is raised: it grows into the lift and settles back as it lands.
    @State private var lifted = false
    @State private var landing = false
    @State private var dragSession = UUID()
    @Namespace private var pillMotion
    /// Measure intrinsic sizes, never transformed frames: lifting a pill must not change its slot.
    /// This cache is not observed, so geometry measurement cannot trigger layout loops.
    @State private var measurements = PillMeasurements()
    /// Whether a hold is under way; unlike `onEnded`, this also resets when the touch is cancelled.
    @GestureState private var holding = false
    /// Keep the drag's order here so the form's binding updates cannot interrupt its animation.
    /// The real pills stay in the layout, with stable IDs and native matched positions.
    @State private var order: [UUID]?
    private static let space = "checklist"
    private static let spacing: CGFloat = 8
    private enum Field: Hashable { case entry(UUID), new }

    private var displayedIDs: [UUID] {
        guard let order else { return entries.map(\.id) }
        let current = Set(entries.map(\.id))
        return order.filter { current.contains($0) } + entries.map(\.id).filter { !order.contains($0) }
    }

    var body: some View {
        FlowLayout(spacing: Self.spacing) {
            ForEach(displayedIDs, id: \.self) { id in
                if let entry = entries.first(where: { $0.id == id }) {
                    entryPill(binding(for: id, fallback: entry))
                }
            }
            if adding {
                pill {
                    ChecklistCircle(done: false, small: true)
                    field(text: $draft, done: false, as: .new,
                          onReturn: keepDraftOrEnd,
                          onLines: { lines in animate { entries += lines.map { ChecklistEntry(title: $0) } }; return "" })
                    removeButton(label: Text("Remove entry: \(draft)")) {
                        focus = nil
                        animate { adding = false }
                        draft = ""
                    }
                }
            }
            // While typing a new one, the add button stays so tapping it keeps that one too.
            if !adding || !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: startAdding) { AddPillLabel(title: "Entry") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add checklist entry")
                    .background(EditorKeyboardRegion())
                    .transition(.opacity)
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { measurements.width = $0 }
        // Install the animation inside the Form row, where the order actually changes.
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: displayedIDs)
        .onChange(of: holding) { _, holding in
            guard !holding, let id = dragging else { return }
            let session = dragSession
            landing = true
            // Release the real pill into its layout position, retaining its identity throughout.
            guard !reduceMotion, let slot = slots(displayedIDs)[id] else { return drop() }
            withAnimation(.smooth(duration: 0.25)) {
                finger = CGPoint(x: slot.minX + grab.width, y: slot.minY + grab.height)
                lifted = false
            } completion: {
                if dragSession == session, dragging == id, !self.holding { drop() }
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.impact(weight: .medium), trigger: dragging) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: displayedIDs)
        .onChange(of: focus) { old, new in
            // Settle a pill once its field loses focus: keep the new one's text, drop an entry left empty.
            if old == .new, new != .new {
                animate {
                    keepDraft()
                    adding = false
                }
            }
            if case .entry(let id) = old, let index = entries.firstIndex(where: { $0.id == id }) {
                let title = entries[index].title.trimmingCharacters(in: .whitespaces)
                if title.isEmpty { animate { _ = entries.remove(at: index) } } else { entries[index].title = title }
            }
        }
    }

    /// An entry's pill: tick, retitle or remove it, or hold it to move it.
    private func entryPill(_ entry: Binding<ChecklistEntry>) -> some View {
        let id = entry.wrappedValue.id
        let done = entry.wrappedValue.isDone
        let title = entry.wrappedValue.title
        return pill {
            Button { entry.wrappedValue.doneAt = done ? nil : Date() } label: {
                ChecklistCircle(done: done, small: true)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(done ? "Done" : "Not done")
            .accessibilityAddTraits(.isToggle)
            field(text: entry.title, done: done, as: .entry(id),
                  onReturn: { startAdding(); return nil },
                  onLines: { lines in insert(lines.dropFirst(), after: id); return lines.first ?? "" })
            removeButton(label: Text("Remove entry: \(title)")) { remove(id) }
        }
        // The actual pill follows the finger; its place in the flow remains the landing gap.
        .onGeometryChange(for: CGSize.self, of: \.size) { measurements[id] = $0 }
        .matchedGeometryEffect(id: id, in: pillMotion, properties: dragging == id ? [] : .position)
        .scaleEffect(!reduceMotion && dragging == id && lifted ? 1.06 : 1)
        .shadow(color: .black.opacity(dragging == id && lifted ? 0.18 : 0), radius: 8, y: 3)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: lifted)
        .offset(dragOffset(id))
        .zIndex(dragging == id ? 1 : 0)
        .transaction { transaction in
            // Finger tracking is immediate, including when the flow changes the held pill's slot.
            // On release it rejoins the native layout animation.
            if dragging == id && !landing { transaction.animation = nil }
        }
        .gesture(reorder(id))
        .accessibilityActions {
            if entries.first?.id != id {
                Button("Move earlier") { move(id, by: -1) }
            }
            if entries.last?.id != id {
                Button("Move later") { move(id, by: 1) }
            }
        }
    }
    /// An entry by its ID rather than its place, which changes as entries move and go.
    private func binding(for id: UUID, fallback: ChecklistEntry) -> Binding<ChecklistEntry> {
        Binding(get: { entries.first { $0.id == id } ?? fallback },
                set: { new in if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = new } })
    }
    private func dragOffset(_ id: UUID) -> CGSize {
        guard dragging == id, let slot = slots(displayedIDs)[id] else { return .zero }
        return CGSize(width: finger.x - grab.width - slot.minX,
                      height: finger.y - grab.height - slot.minY)
    }
    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .foregroundStyle(.pillText)
            .padding(.leading, 10).padding(.trailing, 8)
            .frame(minHeight: 36)
            .background(.pillFill, in: .capsule)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
    private func field(text: Binding<String>, done: Bool, as field: Field, onReturn: @escaping () -> String?,
                       onLines: @escaping ([String]) -> String) -> some View {
        // The pill fits what is typed: a hidden copy of the text (or the placeholder while empty)
        // sets the width, as a text field on its own takes a fixed default width.
        Text(text.wrappedValue.isEmpty ? "Entry" : text.wrappedValue)
            .strikethrough(done)
            .fixedSize()
            .padding(.trailing, 2)  // room for the cursor
            .frame(minWidth: 16, alignment: .leading)
            .hidden()
            .overlay {
                ChecklistPillField(text: text, done: done, focused: focus == field, anyFocused: focus != nil,
                                   resets: field == .new ? draftsKept : 0,
                                   onFocus: { focused in
                                       if focused { focus = field } else if focus == field { focus = nil }
                                   },
                                   onReturn: onReturn, onLines: onLines)
            }
    }
    private func removeButton(label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical).foregroundStyle(.pillSecondaryText)
                .frame(minHeight: 36)
                // Reach a 44-point target without making the pill taller.
                .contentShape(.rect.inset(by: -6))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    /// The dashed pill, or Return in an entry: a new pill to type in. Focus moves straight to it,
    /// so the keyboard stays up.
    private func startAdding() {
        animate {
            keepDraft()
            adding = true
        }
        // Focus once the field exists.
        Task { @MainActor in focus = .new }
    }
    /// Return in the new pill: what's typed becomes an entry and the pill is ready for the next;
    /// in an empty pill it ends the list. Returns what the field keeps.
    private func keepDraftOrEnd() -> String? {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else {
            focus = nil
            return nil
        }
        animate { keepDraft() }
        return ""
    }
    private func keepDraft() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        if !draft.isEmpty { draftsKept += 1 }
        draft = ""
        if !title.isEmpty { entries.append(ChecklistEntry(title: title)) }
    }
    /// Hold, then drag: the pill follows the finger and takes the place of the pill under it.
    private func reorder(_ id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .updating($holding) { value, holding, _ in
                if case .second(true, _) = value { holding = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                if landing { drop() }
                if dragging != id, let frame = slots(displayedIDs)[id] {
                    dragSession = UUID()
                    landing = false
                    grab = CGSize(width: drag.startLocation.x - frame.minX, height: drag.startLocation.y - frame.minY)
                    finger = drag.location
                    dragging = id
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { lifted = true }
                }
                finger = drag.location
                if order == nil { order = entries.map(\.id) }
                if let ids = placement(of: id, at: drag.location) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { order = ids }
                }
            }
    }
    private var reorderLayout: ChecklistReorderLayout {
        ChecklistReorderLayout(sizes: measurements.sizes, width: measurements.width, spacing: Self.spacing)
    }
    private func placement(of id: UUID, at point: CGPoint) -> [UUID]? {
        reorderLayout.placement(of: id, in: displayedIDs, at: point)
    }
    private func slots(_ ids: [UUID]) -> [UUID: CGRect] {
        reorderLayout.slots(ids)
    }
    /// Commit the local order once the native drop animation has finished.
    private func drop() {
        let ids = displayedIDs
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lifted = false
            landing = false
            dragging = nil
            entries = ids.compactMap { id in entries.first { $0.id == id } } + entries.filter { !ids.contains($0.id) }
            order = nil
        }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        animate { entries.swapAt(index, index + offset) }
    }
    private func insert(_ titles: ArraySlice<String>, after id: UUID) {
        guard !titles.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        animate { entries.insert(contentsOf: titles.map { ChecklistEntry(title: $0) }, at: index + 1) }
    }
    private func remove(_ id: UUID) {
        if focus == .entry(id) { focus = nil }
        animate { entries.removeAll { $0.id == id } }
    }
    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25), change)
    }
}

/// Intrinsic pill sizes and the width available to the flow layout.
final class PillMeasurements {
    private(set) var sizes: [UUID: CGSize] = [:]
    var width: CGFloat = .infinity
    subscript(id: UUID) -> CGSize? {
        get { sizes[id] }
        set { sizes[id] = newValue }
    }
}

/// A checklist pill's title: a UIKit text field, so Return can move on without ending editing
/// (which would take the keyboard down and up again between entries). Return goes to `onReturn`
/// and pasted lines to `onLines`; each returns what the field keeps (nil: leave it). Focus is the editor's `focused`; a field only gives up the
/// keyboard when no other pill wants it. While it has the keyboard the field owns its text: an
/// update can arrive with text older than what has just been typed, which would undo it.
struct ChecklistPillField: UIViewRepresentable {
    @Binding var text: String
    let done: Bool
    let focused: Bool
    let anyFocused: Bool
    /// Changes when the editor empties the field's text while it has the keyboard.
    var resets = 0
    var onFocus: (Bool) -> Void
    var onReturn: () -> String?
    var onLines: ([String]) -> String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PillTextField {
        let field = PillTextField()
        field.delegate = context.coordinator
        field.placeholder = String(localized: "Entry")
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .sentences
        field.returnKeyType = .next
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: PillTextField, context: Context) {
        context.coordinator.parent = self
        let style = Style(done: done, size: dynamicTypeSize)
        if context.coordinator.style != style {
            context.coordinator.style = style
            field.defaultTextAttributes = [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: done ? UIColor.secondaryLabel : UIColor.label,
                .strikethroughStyle: done ? NSUnderlineStyle.single.rawValue : 0,
            ]
        }
        if context.coordinator.resets != resets {
            context.coordinator.resets = resets
            field.text = text
        } else if !field.isFirstResponder, field.text != text {
            field.text = text
        }
        field.wantsFocus = focused
        if focused {
            field.takeFocus()
        } else if field.isFirstResponder && !anyFocused {
            field.resignFirstResponder()
        }
    }

    struct Style: Equatable { let done: Bool; let size: DynamicTypeSize }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChecklistPillField
        var style: Style?
        var resets: Int
        init(_ parent: ChecklistPillField) { self.parent = parent; resets = parent.resets }

        @objc func changed(_ field: UITextField) {
            if parent.text != field.text ?? "" { parent.text = field.text ?? "" }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if let kept = parent.onReturn() {
                textField.text = kept
                changed(textField)
            }
            return false
        }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard string.contains(where: \.isNewline) else { return true }
            let text = ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string)
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let kept = parent.onLines(lines)
            textField.text = kept
            changed(textField)
            return false
        }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.onFocus(true) }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.onFocus(false) }
    }
}

/// Takes the keyboard once it's in a window: a new pill's field is asked to before it's shown.
final class PillTextField: UITextField {
    var wantsFocus = false
    private var focusScheduled = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFocus { takeFocus() }
    }
    func takeFocus() {
        guard window != nil, !isFirstResponder, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard self.wantsFocus, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }
}

/// The focussed card's checklist: compact, wrapping pills that can be ticked in place.
/// A long list shows its first eight entries until "Show all" is tapped.
struct ChecklistCard: View {
    let item: PlanItem
    @EnvironmentObject private var store: PlanStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAll = false
    private static let shortList = 8

    var body: some View {
        let entries = item.checklist
        let shown = showsAll || entries.count <= Self.shortList + 1 ? entries : Array(entries.prefix(Self.shortList))
        FlowLayout(spacing: 6) {
            ForEach(shown) { entry in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { store.toggleEntry(entry.id, of: item) }
                } label: {
                    HStack(spacing: 6) {
                        ChecklistCircle(done: entry.isDone, small: true)
                        Text(verbatim: entry.title)
                            .foregroundStyle(entry.isDone ? .secondary : .primary)
                            .strikethrough(entry.isDone)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.footnote.weight(.medium))
                }
                .accessibilityLabel(Text(verbatim: entry.title))
                .accessibilityValue(entry.isDone ? "Done" : "Not done")
                .accessibilityAddTraits(.isToggle)
                .sensoryFeedback(.selection, trigger: entry.isDone)
            }
            if shown.count < entries.count {
                Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { showsAll = true } } label: {
                    Text("Show all \(entries.count)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(ChecklistPillStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The focused actions' padding, height and fill, with a flexible label for narrow screens.
private struct ChecklistPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: .capsule)
            .contentShape(.capsule)
    }
}

/// An entry's circle: empty while open, a grey check once ticked off, like a completed item.
/// `small` is the pill's size, matching the other pills' symbols.
struct ChecklistCircle: View {
    let done: Bool
    var small = false
    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .imageScale(small ? .medium : .large)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
