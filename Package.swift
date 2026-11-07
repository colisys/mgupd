// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "mgupd",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MGUpd", targets: ["MGUpd"])],
    targets: [
        .target(name: "UpdateCore"),
        .executableTarget(name: "MGUpd", dependencies: ["UpdateCore"]),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"]),
    ]
)
