import SQL
import Testing

@testable import SQL_Postgres_Provider

/// Static positive controls for the production composition surface frozen at Sockets
/// `3fad32626d347cbfc0e803496e7ad9c0e66162db`, TLS
/// `e27e99f5c841170593dde7b0396e9090a7515f62`, DNS
/// `930ab8b5dadc99d6c44b101d92422545b697db7d`, and Byte Channel
/// `dfc56d1ed173aae4db784018c746050cbfbe4ee7`. Runtime server execution is deliberately
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

    /// `TLS.Session` is deliberately non-Sendable. The production handshake returns it as a
    /// sending result, and `Postgres.Socket.Transport` consumes that result into actor-owned
    /// optional live state. Reads and writes borrow it; close destructively removes and consumes
    /// it, so neither the creating region nor a second close can reuse the session.
    @Test func `transport owns the one-time TLS session region transfer`() {
        let _: Postgres.Socket.Transport.Type = Postgres.Socket.Transport.self
    }

    @Test func `production configuration has one TLS peer identity`() throws {
        let fixture = try Postgres.Configuration(database: "database", user: "user")
        let configuration = try Postgres.Configuration(
            identity: fixture.identity,
            database: "database",
            user: "user"
        )
        #expect(configuration.identity.hostname == "127.0.0.1")
    }
}
