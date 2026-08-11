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
   This composition is frozen at Sockets `5702645cd7abef90d5102a03f112b5e5cace1ae1`, TLS
   `cf7fcc09a35aff465efa9aabcdbe7fd8de792f54`, and Byte Channel
   `0a7c65b4f12790337ff323e956e5adb691b92549`. The Sockets Pump owns adaptation to
   `Byte.Channel.Writer.Send.Outcome`; the provider does not duplicate that terminal handling.
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
