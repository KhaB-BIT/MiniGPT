// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ChatBMK",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ChatBMK",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
