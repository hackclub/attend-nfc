// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AttendNFCBridge",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CPCSCShim",
            path: "Sources/CPCSCShim",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AttendNFCBridge",
            dependencies: [
                "CPCSCShim",
            ],
            path: "Sources/AttendNFCBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
