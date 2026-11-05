import CloudKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Keeps the plan in the person's private iCloud database with `CKSyncEngine`. The JSON file
/// stays the local copy: every saved change is queued here, and changes fetched from iCloud
/// are written back through the store. Each item and repeating plan is one record in the
/// "Plan" zone holding the value as JSON, so records follow the app's own format and
/// migrations rather than a CloudKit schema of their own.
///
/// A shared item (or a repeating item's whole series) lives in a zone of its own, shared as a
/// whole. The sharer's zone is in their private database, so `engine` syncs it; everyone else
/// reaches it through the shared database and `sharedEngine`. Shared records leave out what's
/// personal; that goes in an overlay record in the person's own "Plan" zone.
///
/// CloudKit can't deliver a share to someone by itself. Once two people share a zone it serves
/// as a private channel: the next share between them goes straight in as an `Invitation` record
/// holding its URL, and the other person's app accepts it (`shareDirectly`).
@Observable @MainActor final class CloudSync: CKSyncEngineDelegate {
    enum Status: Equatable {
        case off, checking, noAccount, restricted, unavailable, syncing, upToDate
        case failed(String)
    }
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: CloudSync.enabledKey)
    private(set) var status: Status = .off
    private(set) var lastSynced: Date?
    /// The zones shared with someone at the moment, either way round.
    private(set) var sharedZones: Set<String> = []
    /// Everyone who has joined a share with this person, to share with again in one tap.
    private(set) var people: [Person] = []
    /// The devices syncing this plan, this one first. iCloud doesn't list them, so each one
    /// keeps a record of itself in the "Plan" zone.
    private(set) var devices: [Device] = []

    @ObservationIgnored private weak var store: PlanStore?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    @ObservationIgnored private var cache = Cache()
    /// Changes saved while the engine is still starting, sent once it is up.
    @ObservationIgnored private var queued: [CKSyncEngine.PendingRecordZoneChange] = []
    @ObservationIgnored private var queuedShared: [CKSyncEngine.PendingRecordZoneChange] = []
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    /// This person's iCloud user, to tell which invitations are theirs.
    @ObservationIgnored private var userRecordName: String?
    @ObservationIgnored private var accepting: Set<String> = []
    @ObservationIgnored private let cacheURL = URL.applicationSupportDirectory
        .appending(path: "Timo", directoryHint: .isDirectory).appending(path: "sync.json")

    /// Whether this build can use iCloud. Signing with iCloud and push needs a paid developer
    /// account, so the `TIMO_ICLOUD` build setting can turn it off for a team without one;
    /// creating a CloudKit container without the entitlement would crash the app.
    static let isAvailable = Bundle.main.object(forInfoDictionaryKey: "TimoICloud") as? String == "YES"
    private static let enabledKey = "iCloudSync"
    private static let containerID = "iCloud.com.timovijn.timo"
    nonisolated private static let zoneID = CKRecordZone.ID(zoneName: "Plan")
    private enum RecordType { static let item = "Item", series = "Series", overlay = "Overlay", invitation = "Invitation", device = "Device" }
    private static let devicePrefix = "device-"
    /// A device that has been away this long is taken for gone from the list.
    private static let deviceExpiry: TimeInterval = 60 * 86400
    /// iCloud is told at most this often that a device is still here.
    private static let checkInInterval: TimeInterval = 3600
    /// Made once: iOS offers apps no lasting identifier that would serve here.
    nonisolated fileprivate static let deviceID: String = {
        if let saved = UserDefaults.standard.string(forKey: "iCloudDeviceID") { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "iCloudDeviceID")
        return id
    }()
    private static let overlayPrefix = "overlay-"
    private static let sharePrefix = "Share-"
    /// Not stored: `isAvailable` guards everything that reaches it.
    private static var container: CKContainer { CKContainer(identifier: containerID) }

    struct Device: Codable, Identifiable, Equatable {
        let id: String
        var model: String
        var system: String
        var lastSeen: Date
        var isThisDevice: Bool { id == CloudSync.deviceID }
    }
    struct Person: Codable, Identifiable, Equatable {
        /// Their iCloud user record.
        let id: String
        var name: String
        /// The shared zones they're in: name to owner.
        var zones: [String: String]
    }
    private struct Invitation: Codable {
        var url: URL
        var zoneName: String
        var ownerName: String
    }

    private struct Cache: Codable {
        var state: CKSyncEngine.State.Serialization?
        var sharedState: CKSyncEngine.State.Serialization?
        /// Per record name: its system fields and the value iCloud last had, the base for merges.
        var records: [String: Known] = [:]
        var lastSynced: Date?
        /// `CloudSync.sharedZones`.
        var shares: Set<String>?
        /// Per item or repeating plan ID: this person's `PersonalDetails` on a shared one.
        var overlays: [String: Data]?
        var people: [Person]?
        var devices: [Device]?
        /// Per record name: invitations to this person not accepted yet.
        var invitations: [String: Invitation]?
    }
    private struct Known: Codable {
        var systemFields: Data
        var payload: Data
        /// The zone it's in, when that isn't the "Plan" zone.
        var zoneName: String?
        var ownerName: String?
        var zone: CKRecordZone.ID {
            zoneName.map { CKRecordZone.ID(zoneName: $0, ownerName: ownerName ?? CKCurrentUserDefaultName) } ?? CloudSync.zoneID
        }
        init(systemFields: Data, payload: Data, zone: CKRecordZone.ID) {
            self.systemFields = systemFields; self.payload = payload
            if zone != CloudSync.zoneID { zoneName = zone.zoneName; ownerName = zone.ownerName }
        }
    }

    func attach(_ store: PlanStore) {
        guard Self.isAvailable else { return }
        self.store = store
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = saved
            lastSynced = saved.lastSynced
            sharedZones = saved.shares ?? []
            people = saved.people ?? []
            showDevices()
        }
        if isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        guard Self.isAvailable else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// Checks the account again when the app returns, so signing in to iCloud in the Settings
    /// app takes effect without toggling sync. With sync already running it fetches instead, so
    /// the plan is current on return even if a push was held back while the app was away.
    func resume() {
        guard Self.isAvailable, isEnabled, status != .checking else { return }
        if engine == nil { start() } else { Task { await syncNow(); await acceptInvitations(); checkIn() } }
    }

    private func start() {
        status = .checking
        Task {
            let container = Self.container
            let account: CKAccountStatus
            do { account = try await container.accountStatus() } catch { status = .unavailable; return }
            guard isEnabled, engine == nil else { return }
            switch account {
            case .available: userRecordName = try? await container.userRecordID().recordName
            case .noAccount: status = .noAccount; return
            case .restricted: status = .restricted; return
            default: status = .unavailable; return
            }
            let firstStart = cache.state == nil
            let engine = CKSyncEngine(CKSyncEngine.Configuration(
                database: container.privateCloudDatabase, stateSerialization: cache.state, delegate: self))
            self.engine = engine
            let sharedEngine = CKSyncEngine(CKSyncEngine.Configuration(
                database: container.sharedCloudDatabase, stateSerialization: cache.sharedState, delegate: self))
            self.sharedEngine = sharedEngine
            UIApplication.shared.registerForRemoteNotifications()
            if firstStart { queueEverything() }
            engine.state.add(pendingRecordZoneChanges: queued)
            sharedEngine.state.add(pendingRecordZoneChanges: queuedShared)
            queued = []
            queuedShared = []
            await syncNow()
            await acceptInvitations()
            checkIn()
        }
    }

    private func stop() {
        // Off the list on every other device. Failing that, it expires from the list.
        if engine != nil {
            let id = Self.deviceRecordID
            Task { _ = try? await Self.container.privateCloudDatabase.modifyRecords(saving: [], deleting: [id]) }
        }
        sendTask?.cancel()
        sendTask = nil
        engine = nil
        sharedEngine = nil
        queued = []
        queuedShared = []
        cache = Cache()
        sharedZones = []
        people = []
        devices = []
        lastSynced = nil
        try? FileManager.default.removeItem(at: cacheURL)
        status = .off
    }

    /// Turns sync off with a reason the iCloud section shows. The plan stays on this device.
    private func disable(because reason: String) {
        setEnabled(false)
        status = .failed(reason)
    }

    func syncNow() async {
        guard let engine, let sharedEngine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await sharedEngine.fetchChanges()
            try await sendPendingChanges(using: engine)
            try await sendPendingChanges(using: sharedEngine)
        } catch { show(error) }
    }

    private func sendPendingChanges(using engine: CKSyncEngine) async throws {
        guard !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty else { return }
        try await engine.sendChanges()
    }

    /// The engine retries network and account problems itself; show anything else.
    private func show(_ error: Error) {
        if error is CancellationError { return }
        if let error = error as? CKError, [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited].contains(error.code) {
            status = .unavailable
        } else {
            status = .failed(error.localizedDescription)
        }
    }

    /// Sends what's queued right away. Left to itself the engine picks its own moment, which
    /// made a change take many seconds to leave the device. The short wait gathers the saves
    /// of one action into one send, and lets the save reach the store, which `record(for:)`
    /// reads. The engine's own schedule stays as the fallback, with its retries.
    private func sendSoon() {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let engine, let sharedEngine else { return }
            // Cleared first, so a later save doesn't cancel this send halfway.
            sendTask = nil
            do {
                try await sendPendingChanges(using: engine)
                try await sendPendingChanges(using: sharedEngine)
            } catch { show(error) }
        }
    }

    // MARK: Local changes

    /// Queues what a save changed: every item and repeating plan that is new or different,
    /// and every one that is gone.
    func queueChanges(items old: [PlanItem], _ new: [PlanItem], series oldSeries: [RepeatingPlan], _ newSeries: [RepeatingPlan]) {
        guard isEnabled else { return }
        var changes = self.changes(old, new, series: \.seriesID, personal: \.personal, sharing: \.forSharing)
        changes += self.changes(oldSeries, newSeries, series: { _ in nil }, personal: \.template.personal, sharing: \.forSharing)
        guard !changes.isEmpty else { return }
        queue(changes)
        sendSoon()
    }

    private static var deviceRecordID: CKRecord.ID {
        CKRecord.ID(recordName: devicePrefix + deviceID, zoneID: zoneID)
    }

    private static var thisDevice: Device {
        Device(id: deviceID, model: UIDevice.current.model, system: UIDevice.current.systemVersion, lastSeen: Date())
    }

    /// Tells the other devices this one is still here.
    private func checkIn() {
        let known = cache.devices?.first { $0.isThisDevice }
        if let known, known == .init(id: known.id, model: Self.thisDevice.model, system: Self.thisDevice.system, lastSeen: known.lastSeen),
           Date().timeIntervalSince(known.lastSeen) < Self.checkInInterval { return }
        remember(Self.thisDevice)
        queue([.saveRecord(Self.deviceRecordID)])
        sendSoon()
    }

    private func remember(_ device: Device) {
        cache.devices = (cache.devices ?? []).filter { $0.id != device.id } + [device]
        showDevices()
    }

    private func showDevices() {
        let cutoff = Date().addingTimeInterval(-Self.deviceExpiry)
        devices = (cache.devices ?? []).filter { $0.isThisDevice || $0.lastSeen > cutoff }
            .sorted { ($0.isThisDevice ? 1 : 0, $0.lastSeen) > ($1.isThisDevice ? 1 : 0, $1.lastSeen) }
    }

    /// Hands each change to the engine of the database its record is in.
    private func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        let mine = changes.filter { Self.isMine($0) }, others = changes.filter { !Self.isMine($0) }
        if let engine { engine.state.add(pendingRecordZoneChanges: mine) } else { queued += mine }
        if let sharedEngine { sharedEngine.state.add(pendingRecordZoneChanges: others) } else { queuedShared += others }
    }

    private static func isMine(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): id.zoneID.ownerName == CKCurrentUserDefaultName
        @unknown default: true
        }
    }

    /// In a shared zone, a change to what's personal goes to the overlay and leaves the
    /// shared record alone.
    private func changes<T: Identifiable & Equatable>(_ old: [T], _ new: [T], series: (T) -> UUID?, personal: (T) -> PersonalDetails,
                                                      sharing: (T) -> T) -> [CKSyncEngine.PendingRecordZoneChange] where T.ID == UUID {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for value in new where before[value.id] != value {
            let id = recordID(value.id, series: series(value)), previous = before[value.id]
            guard Self.isShared(id.zoneID) else { changes.append(.saveRecord(id)); continue }
            if previous.map(sharing) != sharing(value) { changes.append(.saveRecord(id)) }
            if (previous.map(personal) ?? PersonalDetails()) != personal(value) { changes.append(.saveRecord(Self.overlayID(value.id))) }
        }
        for value in old where !after.contains(value.id) {
            let id = recordID(value.id, series: series(value))
            changes.append(.deleteRecord(id))
            if Self.isShared(id.zoneID), cache.overlays?[value.id.uuidString] != nil { changes.append(.deleteRecord(Self.overlayID(value.id))) }
        }
        return changes
    }

    private func queueEverything() {
        guard let engine, let store else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        queue(store.items.map { .saveRecord(recordID($0.id, series: $0.seriesID)) }
              + store.repeatingPlans.map { .saveRecord(recordID($0.id, series: nil)) })
    }

    /// Where an item's record is: where it was last seen, else with its series, so days
    /// generated for a shared series join it.
    private func recordID(_ id: UUID, series: UUID?) -> CKRecord.ID {
        let zone = cache.records[id.uuidString]?.zone ?? series.flatMap { cache.records[$0.uuidString]?.zone } ?? Self.zoneID
        return CKRecord.ID(recordName: id.uuidString, zoneID: zone)
    }

    private static func overlayID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: overlayPrefix + id.uuidString, zoneID: zoneID)
    }

    private static func isShared(_ zone: CKRecordZone.ID) -> Bool { zone != zoneID }

    private func setShared(_ shared: Bool, _ zone: CKRecordZone.ID) {
        if shared { sharedZones.insert(zone.zoneName) } else {
            sharedZones.remove(zone.zoneName)
            remember(in: zone, [])
        }
        cache.shares = sharedZones
    }

    /// Who has joined this zone's share: their names, and the zone as a way to reach them.
    private func remember(in zone: CKRecordZone.ID, _ participants: [CKShare.Participant]) {
        // The sharer sees themselves under the default owner's name rather than their own.
        let me = [userRecordName, CKCurrentUserDefaultName]
        let joined = participants.filter { $0.acceptanceStatus == .accepted && !me.contains($0.userIdentity.userRecordID?.recordName) }
        var known = people.map { person in
            var person = person
            person.zones[zone.zoneName] = nil
            return person
        }
        for participant in joined {
            guard let id = participant.userIdentity.userRecordID?.recordName else { continue }
            if let index = known.firstIndex(where: { $0.id == id }) {
                known[index].zones[zone.zoneName] = zone.ownerName
                known[index].name = Self.name(of: participant) ?? known[index].name
            } else {
                known.append(Person(id: id, name: Self.name(of: participant) ?? "Someone", zones: [zone.zoneName: zone.ownerName]))
            }
        }
        people = known.filter { !$0.zones.isEmpty }.sorted { $0.name < $1.name }
        cache.people = people
    }

    private static func name(of participant: CKShare.Participant) -> String? {
        let identity = participant.userIdentity
        if let components = identity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: components, style: .short)
            if !name.isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber
    }

    private func engine(for zone: CKRecordZone.ID) -> CKSyncEngine? {
        zone.ownerName == CKCurrentUserDefaultName ? engine : sharedEngine
    }

    // MARK: CKSyncEngineDelegate

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await self.record(for: id)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let isPrivate = syncEngine === engine
        guard isPrivate || syncEngine === sharedEngine else { return }
        switch event {
        case .stateUpdate(let update):
            if isPrivate { cache.state = update.stateSerialization } else { cache.sharedState = update.stateSerialization }
            saveCache()
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: if isPrivate { queueEverything() }
            case .signOut: disable(because: "You signed out of iCloud. Your plan stays on this \(UIDevice.current.model).")
            case .switchAccounts: disable(because: "The iCloud account changed. Turn sync on again to use this plan with the new account.")
            @unknown default: break
            }
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions {
                if Self.isShared(deletion.zoneID) {
                    removeZone(deletion.zoneID, reset: isPrivate && deletion.reason == .encryptedDataReset)
                } else if deletion.reason == .encryptedDataReset {
                    cache.records = cache.records.filter { Self.isShared($0.value.zone) }
                    queueEverything()
                } else {
                    // Most likely deleted from the iCloud storage settings: keep the local plan.
                    disable(because: "Your plan was removed from iCloud. Turn sync on again to upload it.")
                }
            }
        case .fetchedRecordZoneChanges(let changes):
            apply(changes, from: syncEngine)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, by: syncEngine)
        case .willFetchChanges, .willSendChanges:
            status = .syncing
        case .didFetchChanges, .didSendChanges:
            if case .failed = status { break }
            lastSynced = Date()
            cache.lastSynced = lastSynced
            saveCache()
            let pending = (engine?.state.pendingRecordZoneChanges ?? []) + (sharedEngine?.state.pendingRecordZoneChanges ?? [])
            status = pending.isEmpty ? .upToDate : .syncing
        default:
            break
        }
    }

    // MARK: Records

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let store else { return nil }
        if id == Self.deviceRecordID {
            guard let payload = try? Self.encoder.encode(Self.thisDevice) else { return nil }
            let record = cache.records[id.recordName].flatMap { Self.record(fromSystemFields: $0.systemFields) }
                ?? CKRecord(recordType: RecordType.device, recordID: id)
            record["payload"] = payload
            record["schema"] = 1
            return record
        }
        let overlay = id.recordName.hasPrefix(Self.overlayPrefix)
        guard let uuid = UUID(uuidString: String(id.recordName.dropFirst(overlay ? Self.overlayPrefix.count : 0))) else { return nil }
        let shared = Self.isShared(id.zoneID)
        let type: String, payload: Data
        do {
            if let item = store.items.first(where: { $0.id == uuid }) {
                type = overlay ? RecordType.overlay : RecordType.item
                payload = overlay ? try Self.encoder.encode(item.personal) : try Self.encoder.encode(shared ? item.forSharing : item)
            } else if let plan = store.repeatingPlans.first(where: { $0.id == uuid }) {
                type = overlay ? RecordType.overlay : RecordType.series
                payload = overlay ? try Self.encoder.encode(plan.template.personal) : try Self.encoder.encode(shared ? plan.forSharing : plan)
            } else {
                engine(for: id.zoneID)?.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
        } catch { return nil }
        let record = cache.records[id.recordName].flatMap { Self.record(fromSystemFields: $0.systemFields) }
            ?? CKRecord(recordType: type, recordID: id)
        record["payload"] = payload
        record["schema"] = 1
        return record
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, from engine: CKSyncEngine) {
        guard let store else { return }
        var items = store.items, series = store.repeatingPlans
        for modification in changes.modifications {
            let record = modification.record
            let zone = record.recordID.zoneID
            if let share = record as? CKShare {
                // A share nobody has joined yet is someone who opened the sheet and left.
                setShared(share.participants.count > 1, zone)
                remember(in: zone, share.participants)
                continue
            }
            if record.recordType == RecordType.invitation {
                if record["recipient"] as? String == userRecordName, let url = (record["url"] as? String).flatMap(URL.init(string:)) {
                    cache.invitations = (cache.invitations ?? [:]).merging(
                        [record.recordID.recordName: Invitation(url: url, zoneName: zone.zoneName, ownerName: zone.ownerName)]) { $1 }
                }
                continue
            }
            guard let payload = record["payload"] as? Data else { continue }
            let name = record.recordID.recordName
            let base = cache.records[name]
            cache.records[name] = Known(systemFields: Self.systemFields(of: record), payload: payload, zone: zone)
            if zone.ownerName != CKCurrentUserDefaultName { setShared(true, zone) }
            // A change of ours still to be sent is merged with theirs and sent after it.
            let pending = engine.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID))
            // Turning sync back on queues everything for the "Plan" zone; this one isn't there.
            if Self.isShared(zone) {
                self.engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: name, zoneID: Self.zoneID))])
            }
            switch record.recordType {
            case RecordType.item:
                guard var theirs = try? Self.decoder.decode(PlanItem.self, from: payload) else { continue }
                if let index = items.firstIndex(where: { $0.id == theirs.id }) {
                    if Self.isShared(zone) { theirs.personal = items[index].personal }
                    items[index] = merge(mine: items[index], theirs: theirs, base: base, pending: pending)
                } else {
                    if Self.isShared(zone), let personal = overlay(for: name) { theirs.personal = personal }
                    items.append(theirs)
                }
            case RecordType.series:
                guard var theirs = try? Self.decoder.decode(RepeatingPlan.self, from: payload) else { continue }
                if let index = series.firstIndex(where: { $0.id == theirs.id }) {
                    if Self.isShared(zone) { theirs.template.personal = series[index].template.personal }
                    if !pending { series[index] = theirs }
                } else {
                    if Self.isShared(zone), let personal = overlay(for: name) { theirs.template.personal = personal }
                    series.append(theirs)
                }
            case RecordType.device:
                guard let device = try? Self.decoder.decode(Device.self, from: payload) else { continue }
                remember(device)
            case RecordType.overlay:
                let id = String(name.dropFirst(Self.overlayPrefix.count))
                cache.overlays = (cache.overlays ?? [:]).merging([id: payload]) { $1 }
                guard let personal = overlay(for: id), !pending else { continue }
                if let index = items.firstIndex(where: { $0.id.uuidString == id }) { items[index].personal = personal }
                if let index = series.firstIndex(where: { $0.id.uuidString == id }) { series[index].template.personal = personal }
            default:
                continue
            }
        }
        for deletion in changes.deletions {
            let name = deletion.recordID.recordName, zone = deletion.recordID.zoneID
            if deletion.recordType == CKRecord.SystemType.share { setShared(false, zone); continue }
            if name.hasPrefix(Self.devicePrefix) {
                cache.devices?.removeAll { $0.id == String(name.dropFirst(Self.devicePrefix.count)) }
                cache.records[name] = nil
                showDevices()
                continue
            }
            if name.hasPrefix(Self.overlayPrefix) {
                cache.overlays?[String(name.dropFirst(Self.overlayPrefix.count))] = nil
                cache.records[name] = nil
                continue
            }
            // Sharing moves an item to its own zone and deletes the old record, and either can
            // arrive first. Only the zone it's in now can delete it.
            guard (cache.records[name]?.zone ?? Self.zoneID) == zone else { continue }
            cache.records[name] = nil
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
            items.removeAll { $0.id.uuidString == name }
            series.removeAll { $0.id.uuidString == name }
        }
        saveCache()
        store.applyFromCloud(items: items, series: series)
        Task { await acceptInvitations() }
    }

    private func overlay(for id: String) -> PersonalDetails? {
        cache.overlays?[id].flatMap { try? Self.decoder.decode(PersonalDetails.self, from: $0) }
    }

    /// A shared zone is gone: the sharer stopped, or this person left. Its items go with it,
    /// except when iCloud lost the sharer's own copy (`reset`), who keeps theirs in the plan.
    private func removeZone(_ zone: CKRecordZone.ID, reset: Bool) {
        guard let store else { return }
        setShared(false, zone)
        let names = Set(cache.records.filter { $0.value.zone == zone }.keys)
        for name in names { cache.records[name] = nil }
        if reset {
            queue(store.items.filter { names.contains($0.id.uuidString) }.map { .saveRecord(recordID($0.id, series: nil)) })
        } else {
            store.applyFromCloud(items: store.items.filter { !names.contains($0.id.uuidString) },
                                 series: store.repeatingPlans.filter { !names.contains($0.id.uuidString) })
        }
        saveCache()
    }

    private func merge(mine: PlanItem, theirs: PlanItem, base: Known?, pending: Bool) -> PlanItem {
        guard pending else { return theirs }
        guard let base = base.flatMap({ try? Self.decoder.decode(PlanItem.self, from: $0.payload) }) else { return mine }
        return PlanItem.merged(base: base, mine: mine, theirs: theirs)
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, by engine: CKSyncEngine) {
        guard let store else { return }
        for record in sent.savedRecords {
            guard let payload = record["payload"] as? Data else { continue }
            cache.records[record.recordID.recordName] = Known(systemFields: Self.systemFields(of: record), payload: payload,
                                                              zone: record.recordID.zoneID)
        }
        // The old record of a newly shared item goes while the new one stays known.
        for id in sent.deletedRecordIDs where cache.records[id.recordName]?.zone == id.zoneID { cache.records[id.recordName] = nil }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var items = store.items
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID, name = id.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Another device saved first: merge with what iCloud has now and send that.
                guard let server = failure.error.serverRecord, let payload = server["payload"] as? Data else { continue }
                let base = cache.records[name]
                cache.records[name] = Known(systemFields: Self.systemFields(of: server), payload: payload, zone: id.zoneID)
                if server.recordType == RecordType.item,
                   var theirs = try? Self.decoder.decode(PlanItem.self, from: payload),
                   let index = items.firstIndex(where: { $0.id == theirs.id }) {
                    if Self.isShared(id.zoneID) { theirs.personal = items[index].personal }
                    items[index] = merge(mine: items[index], theirs: theirs, base: base, pending: true)
                }
                retry.append(.saveRecord(id))
            case .zoneNotFound:
                // Someone else's zone isn't this device's to bring back: the sharing has ended.
                guard id.zoneID.ownerName == CKCurrentUserDefaultName else { continue }
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                retry.append(.saveRecord(id))
            case .unknownItem:
                // iCloud no longer has the record it was based on; send it as a new one.
                cache.records[name] = nil
                retry.append(.saveRecord(id))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited:
                break // The engine retries these itself.
            case .quotaExceeded:
                status = .failed("Your iCloud storage is full, so changes aren't being backed up.")
            default:
                status = .failed(failure.error.localizedDescription)
            }
        }
        saveCache()
        engine.state.add(pendingRecordZoneChanges: retry)
        if items != store.items { store.applyFromCloud(items: items, series: store.repeatingPlans) }
    }

    // MARK: Sharing

    func isShared(_ item: PlanItem) -> Bool {
        sharedZones.contains(recordID(item.id, series: item.seriesID).zoneID.zoneName)
    }

    /// The share to show for `item`, moving it into a zone of its own the first time. A repeating
    /// item takes its whole series along. It stays in that zone if the sharing ends, unshared.
    func share(for item: PlanItem) async throws -> (CKShare, CKContainer) {
        guard let store else { throw CKError(.notAuthenticated) }
        let root = item.seriesID ?? item.id
        let current = recordID(item.id, series: item.seriesID).zoneID
        let zone = Self.isShared(current) ? current : CKRecordZone.ID(zoneName: Self.sharePrefix + root.uuidString)
        let mine = zone.ownerName == CKCurrentUserDefaultName
        let database = mine ? Self.container.privateCloudDatabase : Self.container.sharedCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        if Self.isShared(current) {
            do {
                if let share = try await database.record(for: shareID) as? CKShare { return (share, Self.container) }
            } catch let error as CKError where error.code == .unknownItem { /* Sharing ended; share it anew. */ }
            guard mine else { throw CKError(.unknownItem) }
        }
        let share = CKShare(recordZoneID: zone)
        share[CKShare.SystemFieldKey.title] = item.title
        share.publicPermission = .none
        var records: [CKRecord] = []
        var moved: [CKRecord.ID] = []
        var overlays: [CKSyncEngine.PendingRecordZoneChange] = []
        if !Self.isShared(current) {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
            func add<T: Encodable>(_ id: UUID, _ value: T, type: String, personal: PersonalDetails) throws {
                let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
                record["payload"] = try Self.encoder.encode(value)
                record["schema"] = 1
                records.append(record)
                moved.append(CKRecord.ID(recordName: id.uuidString, zoneID: Self.zoneID))
                if personal != PersonalDetails() { overlays.append(.saveRecord(Self.overlayID(id))) }
            }
            for member in store.items where member.id == root || member.seriesID == root {
                try add(member.id, member.forSharing, type: RecordType.item, personal: member.personal)
            }
            for plan in store.repeatingPlans where plan.id == root {
                try add(plan.id, plan.forSharing, type: RecordType.series, personal: plan.template.personal)
            }
        }
        // CloudKit takes at most 400 records a request; the share goes last, with the items in place.
        var saved: [CKRecord] = []
        let batches = stride(from: 0, to: max(records.count, 1), by: 300).map { Array(records[$0..<min($0 + 300, records.count)]) }
        for (index, batch) in batches.enumerated() {
            let result = try await database.modifyRecords(saving: batch + (index == batches.count - 1 ? [share] : []), deleting: [])
            saved += try result.saveResults.values.map { try $0.get() }
        }
        guard let savedShare = saved.compactMap({ $0 as? CKShare }).first else { throw CKError(.internalError) }
        for record in saved where !(record is CKShare) {
            guard let payload = record["payload"] as? Data else { continue }
            cache.records[record.recordID.recordName] = Known(systemFields: Self.systemFields(of: record), payload: payload, zone: zone)
        }
        engine?.state.remove(pendingRecordZoneChanges: moved.map { .saveRecord($0) })
        queue(moved.map { .deleteRecord($0) } + overlays)
        saveCache()
        sendSoon()
        return (savedShare, Self.container)
    }

    /// The share sheet saved a change to who's in the share.
    func shareSaved(_ share: CKShare) {
        setShared(share.participants.count > 1, share.recordID.zoneID)
        remember(in: share.recordID.zoneID, share.participants)
        saveCache()
    }

    /// Whether this person can invite others to `item`: only its sharer can.
    func canInvite(to item: PlanItem) -> Bool {
        recordID(item.id, series: item.seriesID).zoneID.ownerName == CKCurrentUserDefaultName
    }

    func hasJoined(_ person: Person, _ item: PlanItem) -> Bool {
        person.zones[recordID(item.id, series: item.seriesID).zoneID.zoneName] != nil
    }

    /// Shares `item` with someone already known, with no link to send: adds them to the share and
    /// drops its URL in a zone they're both in, where their app finds it and accepts it.
    func shareDirectly(_ item: PlanItem, with person: Person) async throws {
        let (share, container) = try await share(for: item)
        let participant = try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: person.id))
        participant.permission = .readWrite
        participant.role = .privateUser
        share.addParticipant(participant)
        let zone = share.recordID.zoneID
        let results = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: []).saveResults
        guard let saved = try results.values.compactMap({ try $0.get() as? CKShare }).first, let url = saved.url else {
            throw CKError(.internalError)
        }
        shareSaved(saved)
        var lastError: Error = CKError(.zoneNotFound)
        // Any zone they're in will do. One can have ended without this device having heard yet.
        for (name, owner) in person.zones where name != zone.zoneName {
            let channel = CKRecordZone.ID(zoneName: name, ownerName: owner)
            let invitation = CKRecord(recordType: RecordType.invitation, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: channel))
            invitation["recipient"] = person.id
            invitation["url"] = url.absoluteString
            do {
                let results = try await database(of: channel).modifyRecords(saving: [invitation], deleting: []).saveResults
                _ = try results.values.map { try $0.get() }
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    private func database(of zone: CKRecordZone.ID) -> CKDatabase {
        zone.ownerName == CKCurrentUserDefaultName ? Self.container.privateCloudDatabase : Self.container.sharedCloudDatabase
    }

    /// Accepts what's waiting and tells the person. Kept until it works, since a fetch brings
    /// an invitation only once. It comes from someone they've already shared with.
    private func acceptInvitations() async {
        guard engine != nil else { return }
        for (name, invitation) in cache.invitations ?? [:] where accepting.insert(name).inserted {
            defer { accepting.remove(name) }
            let container = Self.container
            do {
                let metadata = try await container.shareMetadata(for: invitation.url)
                _ = try await container.accept(metadata)
                cache.invitations?[name] = nil
                saveCache()
                let zone = CKRecordZone.ID(zoneName: invitation.zoneName, ownerName: invitation.ownerName)
                _ = try? await database(of: zone).modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: name, zoneID: zone)])
                announce(metadata.share)
                await syncNow()
            } catch { continue }
        }
    }

    private func announce(_ share: CKShare) {
        let content = UNMutableNotificationContent()
        content.title = (share[CKShare.SystemFieldKey.title] as? String) ?? "A shared item"
        content.body = "\(Self.name(of: share.owner) ?? "Someone") shared this with you"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The sharer stopped sharing, or someone else left. Leaving empties that person's copy, which
    /// the next fetch does; the sharer's items stay, in a zone that's no longer shared.
    func shareStopped(_ share: CKShare) {
        setShared(false, share.recordID.zoneID)
        saveCache()
        Task { await syncNow() }
    }

    /// Someone opened a link to a shared item. It takes iCloud to get it, so this turns sync on.
    func accept(_ metadata: CKShare.Metadata) async {
        guard Self.isAvailable else { return }
        do {
            _ = try await Self.container.accept(metadata)
            if isEnabled { await syncNow() } else { setEnabled(true) }
        } catch { status = .failed(error.localizedDescription) }
    }

    private func saveCache() {
        guard isEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            status = .failed("Sync details could not be saved. \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private static let decoder = JSONDecoder()

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
