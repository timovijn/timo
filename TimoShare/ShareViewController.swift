import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share extension's entry point: hosts `ShareView` and reads what was shared into
/// attachments, copying files into the attachments folder as it goes.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }
}

@MainActor final class ShareModel: ObservableObject {
    @Published var attachments: [Attachment] = []
    @Published var loading = true
    @Published var issue: String?
    /// A title for a new item: the page's or file's name.
    @Published var suggestedTitle = ""
    let plan = PlanSnapshot.read()
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    func load(_ items: [NSExtensionItem]) async {
        for item in items {
            for provider in item.attachments ?? [] {
                do {
                    if let attachment = try await Self.attachment(from: provider) { attachments.append(attachment) }
                } catch {
                    issue = error.localizedDescription
                }
            }
            // Safari gives the page's title alongside its address.
            if suggestedTitle.isEmpty, let title = (item.attributedTitle ?? item.attributedContentText)?.string,
               !title.isEmpty, title.count < 120, URL(string: title)?.scheme == nil {
                suggestedTitle = title
            }
        }
        if suggestedTitle.isEmpty, let first = attachments.first, first.kind != .text { suggestedTitle = first.title }
        loading = false
    }

    /// Adds the attachments to an item, or saves a new one with them, through the app's inbox.
    func add(to itemID: UUID?, newItem: PlanItem? = nil) -> Bool {
        do {
            try ShareInbox.add(ShareInboxEntry(itemID: itemID, newItem: newItem, attachments: attachments))
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }
    func cancelled() {
        AttachmentFiles.remove(attachments)
        cancel()
    }

    /// One shared thing as an attachment: a web address as a link, a photo, PDF or other file as a
    /// copied file, and text as text (or a link when it's only an address).
    nonisolated static func attachment(from provider: NSItemProvider) async throws -> Attachment? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
            return .link(url)
        }
        let title = provider.suggestedName.map { ($0 as NSString).deletingPathExtension }
        // The first kind of content that isn't plain text or an address: the file itself.
        if let type = provider.registeredContentTypes.first(where: {
            !$0.conforms(to: .plainText) && !$0.conforms(to: .url) && ($0.conforms(to: .data) || $0.conforms(to: .package))
        }) {
            let fallback = type.conforms(to: .image) ? "Photo" : type.conforms(to: .movie) ? "Video" : "File"
            do {
                return try await copyFile(from: provider, type: type, title: title ?? fallback)
            } catch {
                // Some apps offer an image only as an object, not as a file.
                if type.conforms(to: .image), let image = try await provider.loadItem(forTypeIdentifier: type.identifier) as? UIImage,
                   let data = image.jpegData(compressionQuality: 0.9) {
                    return try AttachmentFiles.save(data, title: title ?? fallback, type: .jpeg)
                }
                throw error
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
            return try AttachmentFiles.importFile(at: url, title: title)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            return text.flatMap { Attachment.reading($0) }
        }
        return nil
    }
    /// The provider's file only exists while its handler runs, so it's copied there.
    nonisolated private static func copyFile(from provider: NSItemProvider, type: UTType, title: String) async throws -> Attachment {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                continuation.resume(with: Result { try AttachmentFiles.importFile(at: url, title: title, type: type) })
            }
        }
    }
}
