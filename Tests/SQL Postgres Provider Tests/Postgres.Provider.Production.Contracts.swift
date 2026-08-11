import SQL
import Testing

@testable import SQL_Postgres_Provider

/// Static positive controls for the production composition surface frozen at Sockets
/// `5702645cd7abef90d5102a03f112b5e5cace1ae1`, TLS
/// `cf7fcc09a35aff465efa9aabcdbe7fd8de792f54`, and Byte Channel
/// `0a7c65b4f12790337ff323e956e5adb691b92549`. Runtime server execution is deliberately
/// fixture-owned; these checks keep the provider's public SQL membrane visible.
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
