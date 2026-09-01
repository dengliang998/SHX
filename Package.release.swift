// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KiteShell",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KiteShell", targets: ["RemoteHub"]),
        .executable(name: "KiteShellUpdater", targets: ["KiteShellUpdater"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "RemoteHub",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/RemoteHub"
        ),
        .executableTarget(
            name: "KiteShellUpdater",
            path: "Sources/KiteShellUpdater"
        )
    ]
)
