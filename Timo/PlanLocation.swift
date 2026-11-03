import Foundation

/// Where the plan is saved. With the App Group (the simulator for now, like iCloud) it lives in
/// the group's shared container so the lock screen widget can read it; without one, the widget
/// has nothing to read and the plan stays in the app's own Application Support.
enum PlanLocation {
    static let appGroup = "group.com.timovijn.timo"
    static var shared: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")
    }
    static let local = URL.applicationSupportDirectory.appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")

    /// The plan file for the app. A plan saved before the App Group existed moves in once.
    static func appURL() -> URL {
        guard let shared else { return local }
        let files = FileManager.default
        if !files.fileExists(atPath: shared.path), files.fileExists(atPath: local.path) {
            try? files.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            // If the move fails, keep using the old file rather than starting empty.
            guard (try? files.moveItem(at: local, to: shared)) != nil else { return local }
        }
        return shared
    }
}
