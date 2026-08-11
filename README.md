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

The repository deliberately does **not** claim that outcome yet. The checked-in
transport is the earlier blocking IPv4/POSIX implementation and the database
uses its earlier task-yield pool. Both are forbidden from the Issue #6 end
state. They remain only until the authenticated TLS-engine producer publishes
its public connection/wrapping witness; no provider-local TLS, DNS, socket,
pool, cursor, or trust-policy substitute will be added.

The exact integration seam is `Postgres.Transport`: the TLS producer must
accept a `Sockets` TCP byte connection, authenticate the configured DNS name,
and expose async read/write/close operations suitable for the PostgreSQL wire
session. Once that public witness exists, the provider will compose it with
`DNS.Resolving` and `Pool.Lease` and delete the legacy transport and spin pool.
See [Production scenarios](Documentation/Production%20scenarios.md) for the
unexecuted real-server source contract.

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
