import SQL
import Testing

@testable import SQL_Postgres_Provider

/// Static positive controls for the production composition surface. Runtime server execution is
/// deliberately fixture-owned; these checks keep the provider's public SQL membrane visible.
extension Postgres {
    @Suite struct `Production Contract Test` {}
}

extension Postgres.`Production Contract Test` {
    @Test func `database remains an SQL database and cursors remain SQL cursors`() {
        let _: any SQL.Database.Type = Postgres.Database.self
        let _: SQL.Cursor<Postgres.Row>.Type = SQL.Cursor<Postgres.Row>.self
    }

    @Test func `production transport remains the socket TLS composition owner`() {
        let _: Postgres.Socket.Transport.Type = Postgres.Socket.Transport.self
    }
}
