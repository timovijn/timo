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
    private enum Field: Hashable { case entry(UUID), new }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach($entries) { $entry in
                pill {
                    Button { entry.doneAt = entry.isDone ? nil : Date() } label: {
                        ChecklistCircle(done: entry.isDone, small: true)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(verbatim: entry.title))
                    .accessibilityValue(entry.isDone ? "Done" : "Not done")
                    .accessibilityAddTraits(.isToggle)
                    field(text: $entry.title, done: entry.isDone, as: .entry(entry.id),
                          onReturn: { startAdding(); return nil },
                          onLines: { lines in insert(lines.dropFirst(), after: entry.id); return lines.first ?? "" })
                    removeButton(label: Text("Remove entry: \(entry.title)")) { remove(entry.id) }
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
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: entries.count)
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
        draft = ""
        if !title.isEmpty { entries.append(ChecklistEntry(title: title)) }
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
        if !field.isFirstResponder, field.text != text { field.text = text }
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
        init(_ parent: ChecklistPillField) { self.parent = parent }

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
