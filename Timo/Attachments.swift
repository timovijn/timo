import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

/// An item's attachments as a line of pills; tapping one opens it (a link in the browser, a file
/// in Quick Look, text on a page of its own). In the editor each has a remove button and a
/// dashed Attachment pill adds more; in the focussed card they take the card's own pill style.
struct AttachmentPills: View {
    @EnvironmentObject private var store: PlanStore
    @Binding var attachments: [Attachment]
    var editable = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview: URL?
    @State private var reading: Attachment?
    @State private var unavailable = false
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingFiles = false
    @State private var typing = false
    @State private var typed = ""
    @State private var issue: String?

    var body: some View {
        // Redraws when a file arrives from iCloud, so its pill stops showing it as missing.
        let _ = store.cloud.filesArrived
        return pills
        .quickLookPreview($preview, in: previewable)
        .sheet(item: $reading) { AttachmentTextPage(attachment: $0) }
        .alert("Not on this device yet", isPresented: $unavailable) {} message: {
            Text(store.cloud.isEnabled
                 ? "This file was added on another device and hasn’t arrived from iCloud yet. Files larger than 100 MB stay on the device they were added on."
                 : "This file was added on another device. Turn on iCloud sync to get it here.")
        }
        .alert("Couldn’t add the attachment", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {} message: {
            Text(issue ?? "")
        }
        .alert("Add link or text", isPresented: $typing) {
            TextField("Link or text", text: $typed)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Add") {
                if let attachment = Attachment.reading(typed) { add([attachment]) }
                typed = ""
            }
        } message: {
            Text("A web address becomes a link; anything else is kept as text.")
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task { await addPhotos(picked) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { add(try result.get().map { try AttachmentFiles.importFile(at: $0) }) }
            catch { issue = error.localizedDescription }
        }
    }

    // Kept apart from `body`'s modifiers, so the compiler checks each part on its own.
    private var pills: some View {
        FlowLayout(spacing: editable ? 8 : 6) {
            ForEach(attachments) { attachment in
                if editable { editablePill(attachment) } else { openButton(attachment) }
            }
            if editable { addMenu }
        }
        .padding(.vertical, editable ? 2 : 0)
        .sensoryFeedback(.selection, trigger: attachments.count)
    }
    /// The files Quick Look can page through.
    private var previewable: [URL] {
        attachments.filter(AttachmentFiles.isAvailable).compactMap(AttachmentFiles.url(for:))
    }
    private func label(_ attachment: Attachment) -> some View {
        Label {
            Text(verbatim: attachment.title).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: attachment.kind == .file && !AttachmentFiles.isAvailable(attachment) ? "icloud.and.arrow.down" : attachment.symbol)
        }
    }
    private func openButton(_ attachment: Attachment) -> some View {
        Button { open(attachment) } label: { label(attachment).frame(maxWidth: 220) }
            .accessibilityLabel("\(attachment.kindName): \(attachment.title)")
            .accessibilityHint(attachment.kind == .link ? "Opens the link" : "Opens the attachment")
    }
    private func editablePill(_ attachment: Attachment) -> some View {
        HStack(spacing: 6) {
            Button { open(attachment) } label: {
                HStack(spacing: 6) {
                    Image(systemName: attachment.kind == .file && !AttachmentFiles.isAvailable(attachment) ? "icloud.and.arrow.down" : attachment.symbol)
                        .foregroundStyle(.pillSecondaryText)
                    Text(verbatim: attachment.title).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: 200, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.pillText)
            .accessibilityLabel("\(attachment.kindName): \(attachment.title)")
            .accessibilityHint(attachment.kind == .link ? "Opens the link" : "Opens the attachment")
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { attachments.removeAll { $0.id == attachment.id } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.pillSecondaryText)
                    .frame(minHeight: 36)
                    // Reach a 44-point target without making the pill taller.
                    .contentShape(.rect.inset(by: -6))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove attachment: \(attachment.title)")
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(minHeight: 36)
        .background(.pillFill, in: .capsule)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
    private var addMenu: some View {
        Menu {
            Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            Button { choosingFiles = true } label: { Label("Files", systemImage: "folder") }
            Button { typing = true } label: { Label("Link or Text", systemImage: "link") }
        } label: {
            AddPillLabel(title: "Attachment")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Add attachment")
    }

    private func open(_ attachment: Attachment) {
        switch attachment.kind {
        case .link: if let url = attachment.url { openURL(url) }
        case .text: reading = attachment
        case .file:
            if AttachmentFiles.isAvailable(attachment) { preview = AttachmentFiles.url(for: attachment) }
            else { unavailable = true }
        }
    }
    private func add(_ added: [Attachment]) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { attachments += added }
    }
    private func addPhotos(_ picked: [PhotosPickerItem]) async {
        var added: [Attachment] = []
        for item in picked {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                added.append(try AttachmentFiles.save(data, title: "Photo", type: item.supportedContentTypes.first))
            } catch { issue = error.localizedDescription }
        }
        add(added)
    }
}

/// A text attachment on a page of its own, to read, select and share.
private struct AttachmentTextPage: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: attachment.text ?? "")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(Text(verbatim: attachment.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: attachment.text ?? "")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
