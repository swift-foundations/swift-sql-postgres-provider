// swift-tools-version: 6.3.3

import PackageDescription

let package = Package(
    name: "swift-sql-postgres-provider",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQL Postgres Provider", targets: ["SQL Postgres Provider"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-sql.git", branch: "main"),
        .package(url: "https://github.com/swift-ietf/swift-rfc-4122.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-time-primitives.git", branch: "main"),
        // The sanctioned third party. `Crypto` is the cross-platform CryptoKit: on Apple
        // platforms it re-exports CryptoKit itself, and elsewhere it supplies the same API.
        // SCRAM-SHA-256 needs HMAC, SHA256 and SymmetricKey, and CryptoKit does not exist off
        // Apple platforms.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")
    ],
    targets: [
        .target(
            name: "SQL Postgres Provider",
            dependencies: [
                .product(name: "SQL", package: "swift-sql"),
                .product(name: "RFC 4122", package: "swift-rfc-4122"),
                .product(name: "Time Primitive", package: "swift-time-primitives"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/SQL Postgres Provider"
        ),
        .testTarget(
            name: "SQL Postgres Provider Tests",
            dependencies: ["SQL Postgres Provider"],
            path: "Tests/SQL Postgres Provider Tests"
        )
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    target.swiftSettings = [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility")
    ]
}
