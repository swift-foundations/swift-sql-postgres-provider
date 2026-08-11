# Production scenarios

These scenarios are the source contract for Issue #6. They intentionally do
not execute until the producer graph is public and the provider can compose it
without a local substitute.

| Scenario | Required observation |
| --- | --- |
| Startup and SCRAM | A server requiring SCRAM-SHA-256 accepts startup and authenticates the configured user. |
| Authenticated TLS and hostname | A TLS server with a valid certificate for the configured DNS name starts PostgreSQL only after hostname-authenticated TLS completes; a mismatched name fails before startup. |
| IPv4, IPv6, and DNS | Literal IPv4 and IPv6 endpoints work, and a DNS result sequence is attempted in resolver order. |
| Streaming rows | A multi-row query delivers rows incrementally through `SQL.Connection` without materializing the complete result first. |
| Transactions and rollback | `write` commits on success, rolls back on body failure, and `withRollback` always rolls back. |
| Server errors | PostgreSQL error responses become `SQL.Error` without invalidating a reusable session unless protocol state requires it. |
| Cancellation | Cancelling a waiting or active operation ends that operation and never leaves a checked-out session reusable. |
| Pool bounds | Concurrent work never exceeds `Configuration.maxConnections`; queued acquisition suspends instead of yielding or spinning. |
| Shutdown | Shutdown rejects new work, drains leased sessions, and closes idle sessions exactly once. |

Static negative controls for the completed composition are also part of the
contract: the provider source contains no POSIX socket or poll imports, no
hand-parsed IPv4 endpoint, no fixed polling interval, no `Task.yield` pool
loop, and no Foundation, NIO, or PostgresNIO imports.

Until the authenticated TLS transport witness is published, these are
requirements rather than execution claims. Any run against the present source
would exercise the superseded transport and is therefore not evidence for
Issue #6.
