import Foundation

/// Where the plan is saved. With the App Group (the simulator for now, like iCloud) it lives in
/// the group's shared container so the lock screen widget can read it; without one, the widget
/// has nothing to read and the plan stays in the app's own Application Support.
///
/// On the simulator every device shares one plan file on the Mac instead, so an iPad simulator
/// shows what was planned on the iPhone one until iCloud sync carries plans between devices.
enum PlanLocation {
    static let appGroup = "group.com.timovijn.timo"
    static var shared: URL? {
        #if targetEnvironment(simulator)
        if let simulators { return simulators }
        #endif
        return group
    }
    private static var group: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")
    }
    #if targetEnvironment(simulator)
    /// ~/Library/Application Support/Timo Simulators/plan.json on the Mac.
    static var simulators: URL? {
        let environment = ProcessInfo.processInfo.environment
        // Xcode and simctl don't always supply the same host-home variable. The device's
        // data directory also contains the Mac home on the standard simulator device set.
        let hostHome = environment["SIMULATOR_HOST_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"].flatMap(resolveHostHome(from:))
            ?? resolveHostHome(from: NSHomeDirectory())
        return hostHome.map {
            URL(filePath: $0, directoryHint: .isDirectory)
                .appending(path: "Library/Application Support/Timo Simulators", directoryHint: .isDirectory)
                .appending(path: "plan.json")
        }
    }

    private static func resolveHostHome(from simulatorPath: String) -> String? {
        guard let range = simulatorPath.range(of: "/Library/Developer/CoreSimulator/Devices/") else { return nil }
        let home = String(simulatorPath[..<range.lowerBound])
        return home.isEmpty ? nil : home
    }
    #endif
    static let local = URL.applicationSupportDirectory.appending(path: "Timo", directoryHint: .isDirectory).appending(path: "plan.json")

    /// The plan file for the app. A plan saved before the App Group existed moves in once; on
    /// the simulator, the first device to open finds the shared file empty and copies its own in.
    static func appURL() -> URL {
        guard let shared else { return local }
        let files = FileManager.default
        guard !files.fileExists(atPath: shared.path) else { return shared }
        let earlier = [group, local].compactMap { $0 }.first { $0 != shared && files.fileExists(atPath: $0.path) }
        if let earlier {
            try? files.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if targetEnvironment(simulator)
            // Copied rather than moved, so the device's own plan is still there to go back to.
            guard (try? files.copyItem(at: earlier, to: shared)) != nil else { return earlier }
            #else
            // If the move fails, keep using the old file rather than starting empty.
            guard (try? files.moveItem(at: earlier, to: shared)) != nil else { return earlier }
            #endif
        }
        return shared
    }
}
