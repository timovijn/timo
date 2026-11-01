import CloudKit
import Foundation
import Observation
import UIKit

/// Keeps the plan in the person's private iCloud database with `CKSyncEngine`. The JSON file
/// stays the local copy: every saved change is queued here, and changes fetched from iCloud
/// are written back through the store. Each item and repeating plan is one record in the
/// "Plan" zone holding the value as JSON, so records follow the app's own format and
/// migrations rather than a CloudKit schema of their own.
@Observable @MainActor final class CloudSync: CKSyncEngineDelegate {
    enum Status: Equatable {
        case off, checking, noAccount, restricted, unavailable, syncing, upToDate
        case failed(String)
    }
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: CloudSync.enabledKey)
    private(set) var status: Status = .off
    private(set) var lastSynced: Date?

    @ObservationIgnored private weak var store: PlanStore?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var cache = Cache()
    /// Changes saved while the engine is still starting, sent once it is up.
    @ObservationIgnored private var queued: [CKSyncEngine.PendingRecordZoneChange] = []
    @ObservationIgnored private let cacheURL = URL.applicationSupportDirectory
        .appending(path: "Timo", directoryHint: .isDirectory).appending(path: "sync.json")

    /// Whether this build can use iCloud. Signing with iCloud and push needs a paid developer
    /// account, so the `TIMO_ICLOUD` build setting turns it on (the Simulator always has it);
    /// creating a CloudKit container without the entitlement would crash the app.
    static let isAvailable = Bundle.main.object(forInfoDictionaryKey: "TimoICloud") as? String == "YES"
    private static let enabledKey = "iCloudSync"
    private static let containerID = "iCloud.com.timovijn.timo"
    private static let zoneID = CKRecordZone.ID(zoneName: "Plan")
    private enum RecordType { static let item = "Item", series = "Series" }

    private struct Cache: Codable {
        var state: CKSyncEngine.State.Serialization?
        /// Per record name: its system fields and the value iCloud last had, the base for merges.
        var records: [String: Known] = [:]
        var lastSynced: Date?
    }
    private struct Known: Codable {
        var systemFields: Data
        var payload: Data
    }

    func attach(_ store: PlanStore) {
        guard Self.isAvailable else { return }
        self.store = store
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = saved
            lastSynced = saved.lastSynced
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
    /// app takes effect without toggling sync.
    func resume() {
        guard Self.isAvailable, isEnabled, engine == nil, status != .checking else { return }
        start()
    }

    private func start() {
        status = .checking
        Task {
            let container = CKContainer(identifier: Self.containerID)
            let account: CKAccountStatus
            do { account = try await container.accountStatus() } catch { status = .unavailable; return }
            guard isEnabled, engine == nil else { return }
            switch account {
            case .available: break
            case .noAccount: status = .noAccount; return
            case .restricted: status = .restricted; return
            default: status = .unavailable; return
            }
            let firstStart = cache.state == nil
            let engine = CKSyncEngine(CKSyncEngine.Configuration(
                database: container.privateCloudDatabase, stateSerialization: cache.state, delegate: self))
            self.engine = engine
            UIApplication.shared.registerForRemoteNotifications()
            if firstStart { queueEverything() }
            engine.state.add(pendingRecordZoneChanges: queued)
            queued = []
            await syncNow()
        }
    }

    private func stop() {
        engine = nil
        queued = []
        cache = Cache()
        lastSynced = nil
        try? FileManager.default.removeItem(at: cacheURL)
        status = .off
    }

    /// Turns sync off with a reason the iCloud section shows. The plan stays on this iPhone.
    private func disable(because reason: String) {
        setEnabled(false)
        status = .failed(reason)
    }

    func syncNow() async {
        guard let engine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            // The engine retries network and account problems itself; show anything else.
            if let error = error as? CKError, [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited].contains(error.code) {
                status = .unavailable
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Local changes

    /// Queues what a save changed: every item and repeating plan that is new or different,
    /// and every one that is gone.
    func queueChanges(items old: [PlanItem], _ new: [PlanItem], series oldSeries: [RepeatingPlan], _ newSeries: [RepeatingPlan]) {
        guard isEnabled else { return }
        var changes = Self.changes(old, new)
        changes += Self.changes(oldSeries, newSeries)
        guard !changes.isEmpty else { return }
        if let engine { engine.state.add(pendingRecordZoneChanges: changes) } else { queued += changes }
    }

    private static func changes<T: Identifiable & Equatable>(_ old: [T], _ new: [T]) -> [CKSyncEngine.PendingRecordZoneChange] where T.ID == UUID {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        return new.filter { before[$0.id] != $0 }.map { .saveRecord(recordID($0.id)) }
            + old.filter { !after.contains($0.id) }.map { .deleteRecord(recordID($0.id)) }
    }

    private func queueEverything() {
        guard let engine, let store else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        engine.state.add(pendingRecordZoneChanges: (store.items.map(\.id) + store.repeatingPlans.map(\.id))
            .map { .saveRecord(Self.recordID($0)) })
    }

    private static func recordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    // MARK: CKSyncEngineDelegate

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await self.record(for: id)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            cache.state = update.stateSerialization
            saveCache()
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: queueEverything()
            case .signOut: disable(because: "You signed out of iCloud. Your plan stays on this iPhone.")
            case .switchAccounts: disable(because: "The iCloud account changed. Turn sync on again to use this plan with the new account.")
            @unknown default: break
            }
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                if deletion.reason == .encryptedDataReset {
                    cache.records = [:]
                    queueEverything()
                } else {
                    // Most likely deleted from the iCloud storage settings: keep the local plan.
                    disable(because: "Your plan was removed from iCloud. Turn sync on again to upload it.")
                }
            }
        case .fetchedRecordZoneChanges(let changes):
            apply(changes)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent)
        case .willFetchChanges, .willSendChanges:
            status = .syncing
        case .didFetchChanges, .didSendChanges:
            if case .failed = status { break }
            lastSynced = Date()
            cache.lastSynced = lastSynced
            saveCache()
            status = syncEngine.state.pendingRecordZoneChanges.isEmpty ? .upToDate : .syncing
        default:
            break
        }
    }

    // MARK: Records

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let store, let uuid = UUID(uuidString: id.recordName) else { return nil }
        let type: String, payload: Data
        do {
            if let item = store.items.first(where: { $0.id == uuid }) {
                type = RecordType.item; payload = try Self.encoder.encode(item)
            } else if let plan = store.repeatingPlans.first(where: { $0.id == uuid }) {
                type = RecordType.series; payload = try Self.encoder.encode(plan)
            } else {
                engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
        } catch { return nil }
        let record = cache.records[id.recordName].flatMap { Self.record(fromSystemFields: $0.systemFields) }
            ?? CKRecord(recordType: type, recordID: id)
        record["payload"] = payload
        record["schema"] = 1
        return record
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let store, let engine else { return }
        var items = store.items, series = store.repeatingPlans
        for modification in changes.modifications {
            let record = modification.record
            guard let payload = record["payload"] as? Data else { continue }
            let name = record.recordID.recordName
            let base = cache.records[name]
            cache.records[name] = Known(systemFields: Self.systemFields(of: record), payload: payload)
            // A change of ours still to be sent is merged with theirs and sent after it.
            let pending = engine.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID))
            switch record.recordType {
            case RecordType.item:
                guard let theirs = try? Self.decoder.decode(PlanItem.self, from: payload) else { continue }
                if let index = items.firstIndex(where: { $0.id == theirs.id }) {
                    items[index] = merge(mine: items[index], theirs: theirs, base: base, pending: pending)
                } else {
                    items.append(theirs)
                }
            case RecordType.series:
                guard let theirs = try? Self.decoder.decode(RepeatingPlan.self, from: payload) else { continue }
                if let index = series.firstIndex(where: { $0.id == theirs.id }) {
                    if !pending { series[index] = theirs }
                } else {
                    series.append(theirs)
                }
            default:
                continue
            }
        }
        for deletion in changes.deletions {
            let name = deletion.recordID.recordName
            cache.records[name] = nil
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
            items.removeAll { $0.id.uuidString == name }
            series.removeAll { $0.id.uuidString == name }
        }
        saveCache()
        store.applyFromCloud(items: items, series: series)
    }

    private func merge(mine: PlanItem, theirs: PlanItem, base: Known?, pending: Bool) -> PlanItem {
        guard pending else { return theirs }
        guard let base = base.flatMap({ try? Self.decoder.decode(PlanItem.self, from: $0.payload) }) else { return mine }
        return PlanItem.merged(base: base, mine: mine, theirs: theirs)
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        guard let engine, let store else { return }
        for record in sent.savedRecords {
            guard let payload = record["payload"] as? Data else { continue }
            cache.records[record.recordID.recordName] = Known(systemFields: Self.systemFields(of: record), payload: payload)
        }
        for id in sent.deletedRecordIDs { cache.records[id.recordName] = nil }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var items = store.items
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID, name = id.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Another device saved first: merge with what iCloud has now and send that.
                guard let server = failure.error.serverRecord, let payload = server["payload"] as? Data else { continue }
                let base = cache.records[name]
                cache.records[name] = Known(systemFields: Self.systemFields(of: server), payload: payload)
                if server.recordType == RecordType.item,
                   let theirs = try? Self.decoder.decode(PlanItem.self, from: payload),
                   let index = items.firstIndex(where: { $0.id == theirs.id }) {
                    items[index] = merge(mine: items[index], theirs: theirs, base: base, pending: true)
                }
                retry.append(.saveRecord(id))
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
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
