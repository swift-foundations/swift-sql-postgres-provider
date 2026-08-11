// swift-tools-version: 6.3.3

import PackageDescription

let package = Package(
    name: "swift-sql-postgres-provider",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SQL Postgres Provider", targets: ["SQL Postgres Provider"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-sql.git", revision: "e9d44cba50fccac90c8c751b0fa95b100aa7e9c8"),
        .package(url: "https://github.com/swift-ietf/swift-rfc-4122.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-time-primitives.git", branch: "main"),
        // The sanctioned third party. `Crypto` is the cross-platform CryptoKit: on Apple
        // platforms it re-exports CryptoKit itself, and elsewhere it supplies the same API.
        // SCRAM-SHA-256 needs HMAC, SHA256 and SymmetricKey, and CryptoKit does not exist off
        // Apple platforms.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Production transport composition is owned by the Institute network stack.  The
        // provider consumes its public DNS, socket, TLS, and bounded-pool seams; it carries no
        // platform transport, resolver, trust, or pool implementation of its own.
        .package(url: "https://github.com/swift-foundations/swift-domain-name-system.git", revision: "930ab8b5dadc99d6c44b101d92422545b697db7d"),
        .package(url: "https://github.com/swift-foundations/swift-kernel.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-io.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-sockets.git", revision: "3fad32626d347cbfc0e803496e7ad9c0e66162db"),
        .package(url: "https://github.com/swift-foundations/swift-tls.git", revision: "e27e99f5c841170593dde7b0396e9090a7515f62"),
        .package(url: "https://github.com/swift-primitives/swift-pool-primitives.git", revision: "b7c710c945b7c8467b4521c3a2d5b00539275593"),
        .package(url: "https://github.com/swift-foundations/swift-byte-channel.git", revision: "dfc56d1ed173aae4db784018c746050cbfbe4ee7"),
        .package(url: "https://github.com/swift-primitives/swift-byte-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-cardinal-primitives.git", branch: "main"),
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
                .product(name: "Sockets Byte Channel", package: "swift-sockets"),
                .product(name: "TLS", package: "swift-tls"),
                .product(name: "TLS Engine Interface", package: "swift-tls"),
                .product(name: "Pool Primitives", package: "swift-pool-primitives"),
                .product(name: "Byte Channel", package: "swift-byte-channel"),
                .product(name: "Byte Primitives", package: "swift-byte-primitives"),
                .product(name: "Cardinal Primitives Standard Library Integration", package: "swift-cardinal-primitives")
            ],
            path: "Sources/SQL Postgres Provider"
        ),
        .testTarget(
            name: "SQL Postgres Provider Tests",
            dependencies: [
                "SQL Postgres Provider",
                .product(name: "Environment", package: "swift-environment"),
                .product(name: "Byte Channel", package: "swift-byte-channel"),
                .product(name: "Byte Primitives", package: "swift-byte-primitives"),
                .product(name: "Cardinal Primitives Standard Library Integration", package: "swift-cardinal-primitives"),
                .product(name: "Domain Name System", package: "swift-domain-name-system"),
                .product(name: "TLS", package: "swift-tls")
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
