// swift-tools-version: 6.0

import PackageDescription
import Foundation

let isReleaseBuild = ProcessInfo.processInfo.environment["KITESHELL_RELEASE_BUILD"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0")
]

var packageTargets: [Target] = [
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

if !isReleaseBuild {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.3")
    )
    packageTargets.append(
        .testTarget(
            name: "RemoteHubTests",
            dependencies: [
                "RemoteHub",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/RemoteHubTests"
        )
    )
}

let package = Package(
    name: "KiteShell",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KiteShell", targets: ["RemoteHub"]),
        .executable(name: "KiteShellUpdater", targets: ["KiteShellUpdater"])
    ],
    dependencies: packageDependencies,
    targets: packageTargets
)
