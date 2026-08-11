# SQL Postgres Provider

`SQL Postgres Provider` owns PostgreSQL wire protocol composition for the
engine-free `SQL` membrane. `Postgres.Database` preserves the `SQL.Database`
transaction and rollback contract; the provider also owns PostgreSQL row
decoding, protocol 3.0 framing, SCRAM-SHA-256 authentication, and text-format
extended queries.

## Production composition status

Issue #6 requires a source-complete production provider composed from the
Institute `Sockets`, `DNS`, authenticated TLS-engine, and `Pool.Lease`
contracts. Its required observable behaviour is:

- DNS and both IPv4 and IPv6 address families, preserving resolver order;
- authenticated TLS with hostname verification before PostgreSQL startup;
- streaming rows, server-error translation, cancellation, transactions and
  rollback;
- bounded, cancellation-aware leases and graceful shutdown.

The provider now composes those owners directly. `Postgres.Configuration`
receives a validated `DNS.Query`; `Postgres.Database` receives a resolver, a
TLS engine witness, and a caller-selected TLS configuration. Resolution order
is retained across IPv4 and IPv6 candidates; the TLS witness authenticates the
configured hostname before PostgreSQL startup or SCRAM authentication.

`Pool.Lease` owns bounded admission, cancellation while waiting, terminal
resource disposition, and graceful shutdown. `SQL.Cursor` is implemented with
the PostgreSQL portal's one-row fetch limit, so decoding remains pull-driven and
does not collect a result set. A cursor must be consumed or closed inside its
connection lease.

The provider consumes the published neutral `TLS Engine Interface` product
directly. It does not introduce engine or trust-policy behavior.

The production transport is bound to Sockets
`5702645cd7abef90d5102a03f112b5e5cace1ae1`, TLS
`cf7fcc09a35aff465efa9aabcdbe7fd8de792f54`, and Byte Channel
`0a7c65b4f12790337ff323e956e5adb691b92549`. Sockets owns the adaptation to
Byte Channel's ownership-preserving `Writer.Send.Outcome`; the provider keeps
the generic Pump and TLS Witness composition unchanged.

## Installation

Add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/swift-foundations/swift-sql-postgres-provider.git", branch: "main")
```

Then add the product to your target's dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SQL Postgres Provider", package: "swift-sql-postgres-provider")
    ]
)
```

## License

Apache 2.0. See [LICENSE](LICENSE.md).
