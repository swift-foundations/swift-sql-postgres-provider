// swift-tools-version: 6.3.3

import PackageDescription

let package = Package(
    name: "swift-sql-postgres-provider",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQL Postgres Provider", targets: ["SQL Postgres Provider"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-sql.git", revision: "bda3ff3884ba21476fc243560a50ab3fd8d728f5"),
        .package(url: "https://github.com/swift-ietf/swift-rfc-4122.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-time-primitives.git", branch: "main"),
        // The sanctioned third party. `Crypto` is the cross-platform CryptoKit: on Apple
        // platforms it re-exports CryptoKit itself, and elsewhere it supplies the same API.
        // SCRAM-SHA-256 needs HMAC, SHA256 and SymmetricKey, and CryptoKit does not exist off
        // Apple platforms.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Production transport composition is owned by the Institute network stack.  The
        // provider consumes its public DNS, socket, TLS, and bounded-lease seams; it carries no
        // platform transport, resolver, trust, or pool implementation of its own.
        .package(url: "https://github.com/swift-foundations/swift-domain-name-system.git", revision: "4bd74b5"),
        .package(url: "https://github.com/swift-foundations/swift-kernel.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-io.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-sockets.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-tls.git", revision: "7e0d59317395e6f79beca7733081ae0d4dce5f2e"),
        .package(url: "https://github.com/swift-foundations/swift-pools.git", revision: "4ace8626b6a00d8ed1763dfe32722063340d6abd"),
        .package(url: "https://github.com/swift-primitives/swift-byte-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-either-primitives.git", branch: "main"),
        // Test-target only: the integration tests read their connection settings from the
        // process environment, and this is the Institute reader for it.
        .package(url: "https://github.com/swift-foundations/swift-environment.git", branch: "main")
    ],
    targets: [
        .target(
            name: "SQL Postgres Provider",
            dependencies: [
                .product(name: "SQL", package: "swift-sql"),
                .product(name: "RFC 4122", package: "swift-rfc-4122"),
                .product(name: "Time Primitive", package: "swift-time-primitives"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Domain Name System", package: "swift-domain-name-system"),
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "IO", package: "swift-io"),
                .product(name: "Sockets", package: "swift-sockets"),
                .product(name: "TLS", package: "swift-tls"),
                .product(name: "TLS Engine Interface", package: "swift-tls"),
                .product(name: "Pools", package: "swift-pools"),
                .product(name: "Byte Primitives", package: "swift-byte-primitives"),
                .product(name: "Either Primitives", package: "swift-either-primitives")
            ],
            path: "Sources/SQL Postgres Provider"
        ),
        .testTarget(
            name: "SQL Postgres Provider Tests",
            dependencies: [
                "SQL Postgres Provider",
                .product(name: "Environment", package: "swift-environment")
            ],
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
