// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SHX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SHX", targets: ["RemoteHub"]),
        .executable(name: "SHXUpdater", targets: ["KiteShellUpdater"])
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
