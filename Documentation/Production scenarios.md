# Production scenarios

These source scenarios specify the externally supplied fixtures required for a real PostgreSQL
run. They are not executed in this repository under the TX-SQL2 source-only evidence boundary.

1. A fixture supplies one validated `TLS.Peer.Identity`, a `DNS.Resolving` implementation whose
   ordered response contains both IPv6 and IPv4 candidates, and a `TLS.PeerPolicy`. The provider
   resolves the identity's query, attempts addresses in exactly that resolver order, and
   authenticates the same identity's hostname.
2. The provider creates an event-backed socket `IO` bundle and a connected
   `Byte.Channel<TLS.Failure>` pair for each candidate. `Sockets.TCP.Connection.Pump` owns the
   connection and one endpoint; the injected `TLS.Engine.Witness` receives the other through
   `wrap(encrypted:configuration:)`. Socket failures map totally into `TLS.Failure`, while TLS
   handshake and hostname authentication complete before PostgreSQL startup and SCRAM traffic.
   This composition is frozen at Sockets `3fad32626d347cbfc0e803496e7ad9c0e66162db`, TLS
   `e27e99f5c841170593dde7b0396e9090a7515f62`, DNS
   `930ab8b5dadc99d6c44b101d92422545b697db7d`, and Byte Channel
   `dfc56d1ed173aae4db784018c746050cbfbe4ee7`. The Sockets Pump owns adaptation to
   `Byte.Channel.Writer.Send.Outcome`; the provider does not duplicate that terminal handling.
   The provider consumes only the provider-neutral `Domain Name System` product, not the
   additive cache product; SwiftPM nevertheless resolves dependencies package-wide.
3. A fixture drives a non-cursor `Postgres.Database.read` or `write`, then calls `shutdown`.
   Public Pool Primitives `b7c710c945b7c8467b4521c3a2d5b00539275593` supplies the
   `Pool.Bounded` that bounds concurrent sessions and sends one move-only checked-out handle
   into the database actor. The provider borrows its session for the scoped operation, consumes
   the handle as reusable only after active success, consumes it as invalid after failure or
   cancellation, wakes a cancelled waiter with the pool cancellation outcome, and drains every
   returned session through its close operation.
4. The escaping cursor scenario is not yet a lawful fixture. Current `swift-sql` represents
   `SQL.Cursor` as a copyable, `Sendable` value holding reusable `@Sendable` `next` and `close`
   closures. That representation cannot uniquely retain and consume the move-only, non-`Sendable`
   pool handle. Returning it would prematurely resolve the handle while its closures still use the
   session. The smallest owner completion is a move-only cursor/context/outcome surface in
   `swift-sql`: every next retains ownership, exhaustion or explicit close consumes it reusable,
   and failure or cancellation consumes it invalid. Until then the provider must not invent a
   local box, lifecycle gate, task cleanup, SPI, trait, or compatibility lease facade.

The fixture owns credentials and trust policy. The provider only consumes their typed DNS and TLS
contracts and maps connection, protocol, and server outcomes onto `SQL.Error`. The handshake sends
the unique, deliberately non-`Sendable` session into the transport actor, which consumes it into
optional live state without retaining an alias in the creating region. Reads and writes borrow only
that actor-owned state. Closing atomically moves it to terminal state before suspending, then always
orders its consuming close before pump cancellation/join and event-runner shutdown. Repeated close
calls are no-ops. Dropping a live transport synchronously invokes the TLS and Pump cancellation
hooks; orderly asynchronous runner shutdown requires explicit close. A failed handshake closes the
pump before the next DNS candidate is attempted. No unchecked conformance, box, or compatibility
facade makes the session shareable.

Production configuration carries one `TLS.Peer.Identity`. Resolution uses its query and TLS uses
its hostname, eliminating the former runtime agreement check. TLS plaintext is exchanged as owned
`Byte.Chunk` values with typed byte counts; synchronous spans are copied only inside exact framing
operations and never cross an `await`. `[UInt8]` survives only where the provider-neutral SQL row
contract or cryptographic interoperability requires it. TLS pins Certificates
`59b14b94e71daa6cc9cc250c8c553f254489073d`.
