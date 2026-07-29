import SQL
import Testing

@testable import SQL_Postgres_Provider

/// Exercises the PostgreSQL wire protocol against an in-memory transport.
///
/// None of this was reachable before the transport seam was split: every code path here sits
/// behind `Session`, and `Session` used to open a socket in its initialiser.
@Suite struct `Wire Protocol Test` {
    private func configuration() throws -> Postgres.Configuration {
        try Postgres.Configuration(
            host: "127.0.0.1",
            port: 5432,
            database: "d",
            user: "u",
            password: nil,
            maxConnections: 1
        )
    }

    private func session(_ inbound: [[UInt8]]) throws -> (Postgres.Session<Memory.Transport>, Memory.Transport) {
        let transport = Memory.Transport(inbound: inbound.flatMap { $0 })
        return (Postgres.Session(configuration: try configuration(), transport: transport), transport)
    }

    @Test func `startup completes on AuthenticationOk and ReadyForQuery`() async throws {
        let (session, transport) = try session([
            Backend.authenticationOk, Backend.readyForQuery,  // startup
            Backend.commandComplete("SELECT 1"), Backend.readyForQuery,  // the query
        ])
        let result = try await session.execute(sql: "SELECT 1")
        #expect(result.rows.isEmpty)

        // The startup packet is length-prefixed and carries protocol 3.0 as 196608, with no
        // leading type byte — the one unframed message in the protocol.
        let startupLength =
            Int(transport.written[0]) << 24 | Int(transport.written[1]) << 16
            | Int(transport.written[2]) << 8 | Int(transport.written[3])
        #expect(startupLength > 4)
        #expect(Array(transport.written[4..<8]) == Backend.int32(196_608))
        #expect(String(decoding: transport.written, as: UTF8.self).contains("user"))
    }

    @Test func `command complete tag yields the affected row count`() async throws {
        let (session, _) = try session([
            Backend.authenticationOk, Backend.readyForQuery,
            Backend.commandComplete("INSERT 0 42"), Backend.readyForQuery,
        ])
        let result = try await session.execute(sql: "INSERT INTO t DEFAULT VALUES")
        #expect(result.count == 42)
    }

    @Test func `an ErrorResponse is surfaced as a server error`() async throws {
        let (session, _) = try session([
            Backend.authenticationOk, Backend.readyForQuery,
            Backend.error("relation \"missing\" does not exist"),
        ])
        // The `M` field is surfaced verbatim, prefixed by its field code.
        await #expect(throws: Postgres.Error.server("M: relation \"missing\" does not exist")) {
            _ = try await session.execute(sql: "SELECT * FROM missing")
        }
    }

    /// A cleartext request with no configured password must fail before anything is sent, not
    /// send an empty password.
    @Test func `a password request without a configured password fails authentication`() async throws {
        let (session, _) = try session([Backend.authenticationCleartext])
        await #expect(throws: Postgres.Error.authentication("server requested a password")) {
            _ = try await session.execute(sql: "SELECT 1")
        }
    }

    /// The length field is inclusive of itself, so anything below four is malformed and must be
    /// rejected rather than used to compute a negative body length.
    @Test func `a frame shorter than its own length field is rejected`() async throws {
        let malformed: [UInt8] = [82] + Backend.int32(3)
        let (session, _) = try session([malformed])
        await #expect(throws: Postgres.Error.protocolViolation("message length is less than four")) {
            _ = try await session.execute(sql: "SELECT 1")
        }
    }

    /// Guards against a hostile or corrupt length allocating without bound.
    @Test func `a frame larger than the cap is rejected`() async throws {
        let huge: [UInt8] = [82] + Backend.int32(32 * 1024 * 1024)
        let (session, _) = try session([huge])
        await #expect(throws: Postgres.Error.frameTooLarge(32 * 1024 * 1024)) {
            _ = try await session.execute(sql: "SELECT 1")
        }
    }

    @Test func `a truncated stream is reported as the peer closing`() async throws {
        // Startup succeeds, then the backend stops mid-conversation.
        let (session, _) = try session([Backend.authenticationOk, Backend.readyForQuery])
        await #expect(throws: Postgres.Error.connection("peer closed the connection")) {
            _ = try await session.execute(sql: "SELECT 1")
        }
    }

    @Test func `closing the session closes the transport once`() async throws {
        let (session, transport) = try session([Backend.authenticationOk, Backend.readyForQuery])
        #expect(transport.isClosed == false)
        await session.close()
        #expect(transport.isClosed)
        await session.close()
        #expect(transport.isClosed)
    }

    @Test func `executing on a closed session throws rather than writing`() async throws {
        let (session, transport) = try session([Backend.authenticationOk, Backend.readyForQuery])
        await session.close()
        let writtenBefore = transport.written.count
        await #expect(throws: Postgres.Error.connection("connection is closed")) {
            _ = try await session.execute(sql: "SELECT 1")
        }
        #expect(transport.written.count == writtenBefore)
    }
}
