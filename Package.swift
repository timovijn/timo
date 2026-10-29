// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TimoCore", products: [.library(name: "TimoCore", targets: ["TimoCore"])],
    targets: [.target(name: "TimoCore"), .testTarget(name: "TimoCoreTests", dependencies: ["TimoCore"])])
