import CloudKit
import OSLog
import SwiftUI
import UIKit

/// Receives share links. An app without a scene delegate of its own never hears of one.
final class TimoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if options.cloudKitShareMetadata != nil { Logger.sharing.info("Connecting a scene for a share link") }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = TimoSceneDelegate.self
        return configuration
    }
    /// Only reached if a scene doesn't take the link; kept so one can't be lost.
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Logger.sharing.info("Share link reached the app delegate")
        Task { @MainActor in await PlanStore.shared.cloud.accept(metadata) }
    }
}

final class TimoSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// A link that launches the app arrives here rather than below. The engines aren't up yet
    /// then; `CloudSync.accept` holds the link until they are.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata {
            Logger.sharing.info("Share link arrived with the launch")
            accept(metadata)
        }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Logger.sharing.info("Share link arrived while running")
        accept(metadata)
    }
    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in await PlanStore.shared.cloud.accept(metadata) }
    }
}

/// The system's sheet for inviting people to a share and seeing who's in it. Presented from
/// UIKit: inside a SwiftUI sheet it's a sheet within a sheet and comes up blank.
@MainActor final class SharingSheet: NSObject, UICloudSharingControllerDelegate {
    /// The controller's delegate is weak, and nothing else holds this while it's up.
    private static var current: SharingSheet?
    private let title: String
    private let cloud: CloudSync
    private let thumbnail: Data?

    private init(title: String, cloud: CloudSync) {
        self.title = title
        self.cloud = cloud
        self.thumbnail = Self.sharingThumbnail()
    }

    private static func sharingThumbnail() -> Data? {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 28).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: 52, weight: .medium)
            guard let symbol = UIImage(systemName: "person.2.fill", withConfiguration: configuration)?
                .withTintColor(UIColor(red: 0.12, green: 0.40, blue: 0.88, alpha: 1), renderingMode: .alwaysOriginal) else { return }
            let scale = min(72 / symbol.size.width, 56 / symbol.size.height)
            let fitted = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
        }.pngData()
    }

    static func present(for item: PlanItem, cloud: CloudSync) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIHostingController(rootView: ItemSharingView(item: item, cloud: cloud))
        controller.modalPresentationStyle = .formSheet
        top.present(controller, animated: true)
    }

    static func present(_ share: CKShare, container: CKContainer, title: String, cloud: CloudSync) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = SharingSheet(title: title, cloud: cloud)
        current = sheet
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = sheet
        controller.modalPresentationStyle = .formSheet
        top.present(controller, animated: true)
    }

    nonisolated func itemTitle(for csc: UICloudSharingController) -> String? {
        MainActor.assumeIsolated { title }
    }
    nonisolated func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        MainActor.assumeIsolated { thumbnail }
    }

    nonisolated func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        MainActor.assumeIsolated { PlanStore.shared.errorMessage = "This item could not be shared. \(error.localizedDescription)" }
    }
    nonisolated func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        MainActor.assumeIsolated { if let share = csc.share { cloud.shareSaved(share) } }
    }
    nonisolated func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        MainActor.assumeIsolated { if let share = csc.share { cloud.shareStopped(share) } }
    }
}

/// Opens immediately; only an explicit sharing action needs CloudKit.
private struct ItemSharingView: View {
    let item: PlanItem
    let cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    @State private var preparing = false
    @State private var addingPerson: String?
    @State private var invited: Set<String> = []
    @State private var issue: String?
    @State private var visible = false

    private var busy: Bool { preparing || addingPerson != nil }
    private var joined: [CloudSync.Person] { cloud.people.filter { cloud.hasJoined($0, item) } }
    private var available: [CloudSync.Person] { cloud.people.filter { !cloud.hasJoined($0, item) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline)
                        Text("Plan together. Everyone sees the same item and one completion completes it for all.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Your reminders and personas stay your own.")
                }
                if !joined.isEmpty {
                    Section("Shared with") {
                        ForEach(joined) { person in
                            HStack {
                                Label(person.name, systemImage: "person.crop.circle")
                                Spacer()
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue("Shared")
                        }
                    }
                }
                if cloud.canInvite(to: item) && !available.isEmpty {
                    Section {
                        ForEach(available) { person in
                            Button {
                                addingPerson = person.id
                                Task { @MainActor in
                                    defer { addingPerson = nil }
                                    do {
                                        try await cloud.shareDirectly(item, with: person)
                                        invited.insert(person.id)
                                    }
                                    catch { issue = "Could not share with \(person.name). \(error.localizedDescription)" }
                                }
                            } label: {
                                HStack {
                                    Label(person.name, systemImage: "person.crop.circle")
                                    Spacer()
                                    if addingPerson == person.id { ProgressView().accessibilityLabel("Sharing") }
                                    else { Text(invited.contains(person.id) ? "Invited" : "Share").font(.subheadline) }
                                }
                            }
                            .disabled(busy || !cloud.isEnabled || invited.contains(person.id))
                        }
                    } header: { Text("Share with") }
                    footer: { Text("Share directly with someone you’re already connected to. No new link needed.") }
                }
                Section {
                    Button { openSystemSharing() } label: {
                        HStack {
                            Label(cloud.canInvite(to: item) ? "Invite someone new" : "View sharing", systemImage: "person.badge.plus")
                            if preparing { Spacer(); ProgressView().accessibilityLabel("Preparing sharing") }
                        }
                    }
                    .disabled(busy || !cloud.isEnabled)
                    if cloud.isShared(item) && cloud.canInvite(to: item) {
                        Button("Manage sharing", systemImage: "person.2") { openSystemSharing() }
                            .disabled(busy || !cloud.isEnabled)
                    }
                } footer: {
                    Text(cloud.isEnabled ? "Connecting to someone new starts with an invitation link." : "Turn on iCloud in Settings to share.")
                }
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .alert("Sharing", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }

    private func openSystemSharing() {
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            do {
                let (share, container) = try await cloud.share(for: item)
                guard visible else { return }
                SharingSheet.present(share, container: container, title: item.title, cloud: cloud)
            } catch { issue = "This item could not be shared. \(error.localizedDescription)" }
        }
    }
}
