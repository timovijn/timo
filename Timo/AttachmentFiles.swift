import Foundation
import UniformTypeIdentifiers

/// Where attachment files are kept (compiled into the app and the share extension): an `Attachments` folder beside the plan (so in the App Group,
/// and on the simulators in the one folder on the Mac they all share), with a folder per
/// attachment holding the file under its own name.
enum AttachmentFiles {
    static let folder = PlanLocation.appURL().deletingLastPathComponent()
        .appending(path: "Attachments", directoryHint: .isDirectory)

    static func url(for attachment: Attachment) -> URL? {
        guard attachment.kind == .file, let name = attachment.fileName else { return nil }
        return folder.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: name)
    }
    /// Whether the file is on this device. Until files sync, one added on another device isn't.
    static func isAvailable(_ attachment: Attachment) -> Bool {
        url(for: attachment).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    /// Copies a file picked in Files, or handed over by another app's share sheet, into the
    /// attachments folder. `title` and `type` replace what the file's name says, when known.
    static func importFile(at source: URL, title: String? = nil, type: UTType? = nil) throws -> Attachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try? source.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let contentType = values?.contentType ?? UTType(filenameExtension: source.pathExtension) ?? type
        var name = source.lastPathComponent
        if let title, !title.isEmpty {
            let ext = source.pathExtension.isEmpty ? contentType?.preferredFilenameExtension : source.pathExtension
            name = ext.map { title + "." + $0 } ?? title
        }
        var attachment = Attachment(kind: .file, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? source.deletingPathExtension().lastPathComponent,
                                    fileName: safeName(name), contentType: contentType?.identifier,
                                    byteCount: values?.fileSize)
        let destination = try prepare(attachment)
        // Coordinated, so a file still downloading from iCloud Drive is read once it's there.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        if attachment.byteCount == nil { attachment.byteCount = size(of: destination) }
        return attachment
    }
    /// Writes a photo (or other data) as a new attachment file.
    static func save(_ data: Data, title: String, type: UTType?) throws -> Attachment {
        let ext = type?.preferredFilenameExtension.map { ".\($0)" } ?? ""
        let attachment = Attachment(kind: .file, title: title, fileName: safeName(title + ext),
                                    contentType: type?.identifier, byteCount: data.count)
        try data.write(to: try prepare(attachment), options: .atomic)
        return attachment
    }
    private static func prepare(_ attachment: Attachment) throws -> URL {
        guard let url = url(for: attachment) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
    private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "File" + cleaned : cleaned
    }
    private static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
    /// Deletes the folders no item or repeating item refers to any more: files added in an editor
    /// that was then discarded, and those of items deleted earlier. Run once at launch, so an
    /// item's deletion can still be undone with its files during the session. A folder made in the
    /// last hour is left alone: the share extension may have just copied it in, ahead of its entry.
    static func removeUnused(keeping used: Set<UUID>) {
        let files = FileManager.default
        guard let folders = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let recent = Date().addingTimeInterval(-3600)
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !used.contains(id) else { continue }
            if let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate, created > recent { continue }
            try? files.removeItem(at: folder)
        }
    }
    /// Deletes the files of attachments that were never kept, such as those of a cancelled share.
    static func remove(_ attachments: [Attachment]) {
        for attachment in attachments where attachment.kind == .file {
            try? FileManager.default.removeItem(at: folder.appending(path: attachment.id.uuidString, directoryHint: .isDirectory))
        }
    }
}

extension Attachment {
    var symbol: String {
        switch kind {
        case .link: return "link"
        case .text: return "text.alignleft"
        case .file:
            guard let type = contentType.flatMap(UTType.init) else { return "doc" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .movie) { return "film" }
            if type.conforms(to: .audio) { return "waveform" }
            if type.conforms(to: .emailMessage) { return "envelope" }
            return "doc"
        }
    }
    /// What VoiceOver says the attachment is, before its title.
    var kindName: String {
        switch kind {
        case .link: return "Link"
        case .text: return "Text"
        case .file:
            guard let type = contentType.flatMap(UTType.init) else { return "File" }
            if type.conforms(to: .image) { return "Photo" }
            if type.conforms(to: .pdf) { return "PDF" }
            return type.localizedDescription ?? "File"
        }
    }
}

/// What the share extension hands to the app: attachments for an existing item, or a new item
/// with them. The extension never writes the plan itself; it leaves one small file per share in
/// an `Inbox` folder beside the plan, and the app saves each through its usual path (so iCloud,
/// reminders and the widget follow) the next time it becomes active, then removes the file.
struct ShareInboxEntry: Codable, Identifiable {
    var id = UUID()
    /// The item to add the attachments to.
    var itemID: UUID?
    /// A new item to save, already carrying the attachments.
    var newItem: PlanItem?
    var attachments: [Attachment] = []
    var createdAt = Date()
}

enum ShareInbox {
    static let folder = PlanLocation.appURL().deletingLastPathComponent().appending(path: "Inbox", directoryHint: .isDirectory)

    static func add(_ entry: ShareInboxEntry) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url(for: entry.id), options: .atomic)
    }
    /// The entries waiting, oldest first.
    static func pending() -> [ShareInboxEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ShareInboxEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    static func remove(_ entry: ShareInboxEntry) {
        try? FileManager.default.removeItem(at: url(for: entry.id))
    }
    private static func url(for id: UUID) -> URL { folder.appending(path: id.uuidString + ".json") }
}

/// The saved plan, read but never written: what the share extension lists to choose from.
struct PlanSnapshot: Decodable {
    var items: [PlanItem] = []
    var series: [RepeatingPlan] = []
    private enum CodingKeys: String, CodingKey { case items, series }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([PlanItem].self, forKey: .items)
        series = try values.decodeIfPresent([RepeatingPlan].self, forKey: .series) ?? []
    }
    static func read() -> PlanSnapshot? {
        guard let data = try? Data(contentsOf: PlanLocation.appURL()) else { return nil }
        return try? JSONDecoder().decode(PlanSnapshot.self, from: data)
    }
}
