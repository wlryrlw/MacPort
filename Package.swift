// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacPort",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MacPort", targets: ["MacPort"])
    ],
    targets: [
        .executableTarget(
            name: "MacPort",
            path: "Sources/MacPort",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
