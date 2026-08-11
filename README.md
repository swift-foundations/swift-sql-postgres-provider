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
receives one validated `TLS.Peer.Identity`; `Postgres.Database` receives a
resolver, TLS engine witness, and peer policy. Resolution order is retained
across IPv4 and IPv6 candidates; the identity's query selects the endpoint and
its hostname authenticates that same peer before PostgreSQL startup or SCRAM
authentication.

`Pool.Lease` owns bounded admission, cancellation while waiting, terminal
resource disposition, and graceful shutdown. `SQL.Cursor` is implemented with
the PostgreSQL portal's one-row fetch limit, so decoding remains pull-driven and
does not collect a result set. A cursor must be consumed or closed inside its
connection lease.

The provider consumes the published neutral `TLS Engine Interface` product
directly. It does not introduce engine or trust-policy behavior.

The production transport is bound to Sockets
`3fad32626d347cbfc0e803496e7ad9c0e66162db`, TLS
`8c37e32d5af95109c66ede18f0d044e1c62da3ee`, DNS
`930ab8b5dadc99d6c44b101d92422545b697db7d`, and Byte Channel
`dfc56d1ed173aae4db784018c746050cbfbe4ee7`. Sockets owns the adaptation to
Byte Channel's ownership-preserving `Writer.Send.Outcome`; the provider keeps
the generic Pump and TLS Witness composition unchanged.

The provider imports only the provider-neutral `Domain Name System` product.
The additive `Domain Name System Cache` product is not linked, although SwiftPM
resolves every dependency declared by the DNS package regardless of product
selection.

`TLS.Session` is uniquely owned. The transport actor borrows it only while the
session is live, moves it out before the first suspension in `close()`, and
consumes it exactly once before closing the Pump and event runner. Repeated
close calls observe terminal state and do nothing. Dropping a live transport
invokes the synchronous TLS and Pump cancellation hooks; orderly asynchronous
runner shutdown requires explicit close.

Production configuration stores one nonoptional `TLS.Peer.Identity`; its DNS
query selects the address and its hostname authenticates the same peer, so the
two projections cannot diverge. TLS plaintext crosses the provider boundary as
owned `Byte.Chunk` values with `Index<Byte>.Count` limits. PostgreSQL framing is
Byte-primary; `[UInt8]` remains only at the provider-neutral `SQL.Row` byte API
and cryptographic interoperability boundaries. TLS pins Certificates
`59b14b94e71daa6cc9cc250c8c553f254489073d`.

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
