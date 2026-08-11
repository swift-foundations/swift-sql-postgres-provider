# Production scenarios

These source scenarios specify the externally supplied fixtures required for a real PostgreSQL
run. They are not executed in this repository under the TX-SQL2 source-only evidence boundary.

1. A fixture supplies a validated `DNS.Query`, a `DNS.Resolving` implementation whose ordered
   response contains both IPv6 and IPv4 candidates, and a `TLS.Configuration` for that query and
   hostname. The provider attempts addresses in exactly that resolver order.
2. The provider creates an event-backed socket `IO` bundle and a connected
   `Byte.Channel<TLS.Failure>` pair for each candidate. `Sockets.TCP.Connection.Pump` owns the
   connection and one endpoint; the injected `TLS.Engine.Witness` receives the other through
   `wrap(encrypted:configuration:)`. Socket failures map totally into `TLS.Failure`, while TLS
   handshake and hostname authentication complete before PostgreSQL startup and SCRAM traffic.
   This composition is frozen at Sockets `3fad32626d347cbfc0e803496e7ad9c0e66162db`, TLS
   `93468b04579b86164fc60f71d65ed4dea30444dd`, DNS
   `930ab8b5dadc99d6c44b101d92422545b697db7d`, and Byte Channel
   `dfc56d1ed173aae4db784018c746050cbfbe4ee7`. The Sockets Pump owns adaptation to
   `Byte.Channel.Writer.Send.Outcome`; the provider does not duplicate that terminal handling.
   The provider consumes only the provider-neutral `Domain Name System` product, not the
   additive cache product; SwiftPM nevertheless resolves dependencies package-wide.
3. A fixture drives `Postgres.Database.read` and `write`, then calls `shutdown`. `Pool.Lease`
   bounds concurrent sessions, wakes a cancelled waiter with the pool cancellation outcome, and
   drains every returned session through its close operation.
4. A fixture opens `SQL.Connection.fetchCursor`, consumes several rows, and closes it early.
   The PostgreSQL portal is closed, the connection lease is released, and no result array is
   accumulated by the cursor path.

The fixture owns credentials and trust policy. The provider only consumes their typed DNS and TLS
contracts and maps connection, protocol, and server outcomes onto `SQL.Error`. Closing a session
always orders the TLS close before pump cancellation/join and event-runner shutdown; a failed
handshake closes the pump before the next DNS candidate is attempted.
