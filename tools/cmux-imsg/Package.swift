// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "cmux-imsg",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "cmux-imsg",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
