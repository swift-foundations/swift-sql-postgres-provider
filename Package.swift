// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-sql-postgres-provider",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SQL Postgres Provider", targets: ["SQL Postgres Provider"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-sql.git", branch: "main"),
        .package(url: "https://github.com/swift-ietf/swift-rfc-4122.git", branch: "main"),
        .package(
            url: "https://github.com/swift-primitives/swift-time-primitives.git",
            branch: "main"
        ),
        // The sanctioned third party. `Crypto` is the cross-platform CryptoKit: on Apple
        // platforms it re-exports CryptoKit itself, and elsewhere it supplies the same API.
        // SCRAM-SHA-256 needs HMAC, SHA256 and SymmetricKey, and CryptoKit does not exist off
        // Apple platforms.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // The Institute POSIX stack. swift-iso-9945 binds the syscalls and owns the
        // `#if canImport(Darwin)/Glibc` portability seam; swift-posix layers the EINTR policy on
        // top — including `connect`, whose EINTR completes through poll rather than by retrying.
        .package(url: "https://github.com/swift-foundations/swift-posix.git", branch: "main"),
        .package(url: "https://github.com/swift-iso/swift-iso-9945.git", branch: "main"),
        .package(
            url: "https://github.com/swift-primitives/swift-byte-primitives.git",
            branch: "main"
        ),
        // Test-target only: the integration tests read their connection settings from the
        // process environment, and this is the Institute reader for it.
        .package(url: "https://github.com/swift-foundations/swift-environment.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "SQL Postgres Provider",
            dependencies: [
                .product(name: "SQL", package: "swift-sql"),
                .product(name: "RFC 4122", package: "swift-rfc-4122"),
                .product(name: "Time Primitive", package: "swift-time-primitives"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "POSIX Kernel Socket", package: "swift-posix"),
                .product(name: "POSIX Kernel Poll", package: "swift-posix"),
                .product(name: "ISO 9945 Kernel Socket", package: "swift-iso-9945"),
                .product(name: "ISO 9945 Kernel Socket Address", package: "swift-iso-9945"),
                .product(name: "ISO 9945 Kernel Poll", package: "swift-iso-9945"),
                .product(name: "Byte Primitives", package: "swift-byte-primitives"),
            ],
            path: "Sources/SQL Postgres Provider"
        ),
        .testTarget(
            name: "SQL Postgres Provider Tests",
            dependencies: [
                "SQL Postgres Provider",
                .product(name: "Environment", package: "swift-environment"),
            ],
            path: "Tests/SQL Postgres Provider Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    target.swiftSettings = [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
    ]
}
