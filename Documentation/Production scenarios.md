# Production scenarios

These source scenarios specify the externally supplied fixtures required for a real PostgreSQL
run. They are not executed in this repository under the TX-SQL2 source-only evidence boundary.

1. A fixture supplies a validated `DNS.Query`, a `DNS.Resolving` implementation whose ordered
   response contains both IPv6 and IPv4 candidates, and a `TLS.Configuration` for that query and
   hostname. The provider attempts addresses in exactly that resolver order.
2. A fixture supplies an authenticated `TLS.Engine.Witness`. The witness wraps the selected
   `Sockets.TCP.Connection`; hostname authentication completes before PostgreSQL startup and
   SCRAM traffic.
3. A fixture drives `Postgres.Database.read` and `write`, then calls `shutdown`. `Pool.Lease`
   bounds concurrent sessions, wakes a cancelled waiter with the pool cancellation outcome, and
   drains every returned session through its close operation.
4. A fixture opens `SQL.Connection.fetchCursor`, consumes several rows, and closes it early.
   The PostgreSQL portal is closed, the connection lease is released, and no result array is
   accumulated by the cursor path.

The fixture owns credentials and trust policy. The provider only consumes their typed DNS and TLS
contracts and maps connection, protocol, and server outcomes onto `SQL.Error`.
