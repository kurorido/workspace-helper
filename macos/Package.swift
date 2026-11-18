// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WorkspaceHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WorkspaceHelper", targets: ["WorkspaceHelper"])
    ],
    targets: [
        .target(
            name: "WorkspaceCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WorkspaceHelper",
            dependencies: ["WorkspaceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WorkspaceCoreTests",
            dependencies: ["WorkspaceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
