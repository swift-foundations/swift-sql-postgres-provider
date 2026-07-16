# SQL Postgres Provider

`SQL Postgres Provider` is the bounded Institute-native PostgreSQL provider for
the engine-free `SQL` membrane. It contains the wire client, PostgreSQL row
decoding, transaction scopes, cancellation-aware blocking I/O, and a bounded
lazy connection pool.

The first slice deliberately supports IPv4 TCP, PostgreSQL protocol 3.0,
cleartext and SCRAM-SHA-256 authentication, and text-format extended queries.
TLS, DNS/IPv6 address resolution, prepared-statement caching, reconnect policy,
and multi-writer coordination are not part of this package. The provider
preserves the `SQL.Database` transaction and rollback contract; the control
plane remains the single kernel owner and writer.
