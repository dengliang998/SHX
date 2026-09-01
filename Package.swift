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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.3")
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
        ),
        .testTarget(
            name: "RemoteHubTests",
            dependencies: [
                "RemoteHub",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/RemoteHubTests"
        )
    ]
)
