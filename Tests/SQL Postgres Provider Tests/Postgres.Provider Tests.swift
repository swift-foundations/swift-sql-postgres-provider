import Darwin
import SQL
import Testing
import Time_Primitive

@testable import SQL_Postgres_Provider

@Suite struct `Postgres Provider Test` {
    @Suite struct `Configuration Test` {
        @Test func `configuration rejects invalid bounds`() {
            #expect(throws: Postgres.Error.self) {
                _ = try Postgres.Configuration(port: 0, database: "db", user: "user")
            }
            #expect(throws: Postgres.Error.self) {
                _ = try Postgres.Configuration(database: "", user: "user")
            }
            #expect(throws: Postgres.Error.self) {
                _ = try Postgres.Configuration(database: "db", user: "user", maxConnections: 0)
            }
        }

        @Test func `configuration retains bounded pool policy`() throws {
            let configuration = try Postgres.Configuration(database: "db", user: "user", maxConnections: 3)
            #expect(configuration.maxConnections == 3)
            #expect(configuration.port == 5432)
        }
    }

    @Suite struct `Row Test` {
        @Test func `row decodes text null bytea and timestamp without Foundation`() throws {
            let row = Postgres.Row(
                names: ["text", "missing", "bytes", "when"],
                values: [
                    Array("hello".utf8),
                    nil,
                    Array("\\x00ff".utf8),
                    Array("2026-07-16 12:34:56.123456789+02".utf8),
                ]
            )
            #expect(try row.string("text") == "hello")
            #expect(try row.stringIfPresent("missing") == nil)
            #expect(try row.bytes("bytes") == [0, 255])
            let instant = try row.timestamp("when")
            #expect(instant.nanosecondFraction == 123_456_789)
        }

        @Test func `row rejects malformed values and missing columns`() {
            let row = Postgres.Row(names: ["value"], values: [Array("\\x0g".utf8)])
            #expect(throws: SQL.Error.self) { _ = try row.int("value") }
            #expect(throws: SQL.Error.self) { _ = try row.string("missing") }
            #expect(throws: SQL.Error.self) { _ = try row.bytes("value") }
        }
    }

    @Suite struct `Integration Test` {
        /// This test is intentionally inert unless a deliberately managed test database supplies
        /// all four explicit variables. It never starts, stops, or mutates an unmanaged server.
        @Test func `managed database executes a read and rollback scope`() async throws {
            guard let host = environment("POSTGRES_NATIVE_TEST_HOST"),
                let databaseName = environment("POSTGRES_NATIVE_TEST_DATABASE"),
                let user = environment("POSTGRES_NATIVE_TEST_USER"),
                let portText = environment("POSTGRES_NATIVE_TEST_PORT"),
                let port = UInt16(portText)
            else { return }
            let password = environment("POSTGRES_NATIVE_TEST_PASSWORD")
            let configuration = try Postgres.Configuration(
                host: host,
                port: port,
                database: databaseName,
                user: user,
                password: password,
                maxConnections: 1
            )
            try await Postgres.withDatabase(configuration: configuration) { database in
                let value = try await database.read { (connection: any SQL.Connection) throws(SQL.Error) -> Int? in
                    try await connection.fetchOne(SQL.Query(sql: "SELECT 1 AS value")) { (row: any SQL.Row) throws(SQL.Error) -> Int in
                        try row.int("value")
                    }
                }
                #expect(value == 1)
                _ = try await database.withRollback { (connection: any SQL.Connection) throws(SQL.Error) -> Int in
                    _ = try await connection.execute(SQL.Query(sql: "CREATE TEMP TABLE rollback_probe (value INTEGER)"))
                    return 1
                }
                let probe = try await database.read { (connection: any SQL.Connection) throws(SQL.Error) -> String? in
                    try await connection.fetchOne(SQL.Query(sql: "SELECT to_regclass('pg_temp.rollback_probe') AS name")) { (row: any SQL.Row) throws(SQL.Error) -> String in
                        try row.stringIfPresent("name") ?? ""
                    }
                }
                #expect(probe?.isEmpty == true)
            }
        }

        @Test func `managed database cancellation releases a bounded lease`() async throws {
            guard let host = environment("POSTGRES_NATIVE_TEST_HOST"),
                let databaseName = environment("POSTGRES_NATIVE_TEST_DATABASE"),
                let user = environment("POSTGRES_NATIVE_TEST_USER"),
                let portText = environment("POSTGRES_NATIVE_TEST_PORT"),
                let port = UInt16(portText)
            else { return }
            let configuration = try Postgres.Configuration(
                host: host,
                port: port,
                database: databaseName,
                user: user,
                password: environment("POSTGRES_NATIVE_TEST_PASSWORD"),
                maxConnections: 1
            )
            try await Postgres.withDatabase(configuration: configuration) { database in
                let holder = Task {
                    try await database.read { (connection: any SQL.Connection) throws(SQL.Error) -> Int in
                        _ = try await connection.execute(SQL.Query(sql: "SELECT pg_sleep(1)"))
                        return 1
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
                let waiter = Task {
                    try await database.read { (connection: any SQL.Connection) throws(SQL.Error) -> Int in
                        try await connection.execute(SQL.Query(sql: "SELECT 1"))
                    }
                }
                waiter.cancel()
                await #expect(throws: SQL.Error.self) {
                    _ = try await waiter.value
                }
                _ = try await holder.value
            }
        }
    }
}

private func environment(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

@Suite struct `Array Literal Test` {
    /// Runs one binding through the real Bind message and returns the bytes actually put on the
    /// wire for it. This goes through `execute` rather than calling the encoder directly, so the
    /// encoders stay `private` and the assertion is about wire output rather than an internal
    /// helper.
    private func boundPayload(_ value: SQL.Value) async throws -> String {
        let inbound = [
            Backend.authenticationOk, Backend.readyForQuery,
            Backend.commandComplete("SELECT 0"), Backend.readyForQuery,
        ].flatMap { $0 }
        let transport = MemoryTransport(inbound: inbound)
        let configuration = try Postgres.Configuration(
            host: "127.0.0.1",
            port: 5432,
            database: "d",
            user: "u",
            password: nil,
            maxConnections: 1
        )
        let session = Postgres.Session(configuration: configuration, transport: transport)
        _ = try await session.execute(sql: "SELECT $1", bindings: [value])

        let written = transport.written
        // Bind is tag 66. Its body is two empty C strings, then int16 format-count, int16
        // format, int16 parameter-count, then int32 length + bytes for the single parameter.
        guard let start = written.firstIndex(of: 66) else {
            throw Postgres.Error.protocolViolation("no Bind message was written")
        }
        let body = start + 5
        let lengthOffset = body + 8
        let length =
            Int(written[lengthOffset]) << 24 | Int(written[lengthOffset + 1]) << 16
            | Int(written[lengthOffset + 2]) << 8 | Int(written[lengthOffset + 3])
        guard length >= 0 else { throw Postgres.Error.protocolViolation("null bound") }
        let payload = written[(lengthOffset + 4)..<(lengthOffset + 4 + length)]
        return String(decoding: payload, as: UTF8.self)
    }

    @Test func `binds a flat array as a braced comma-separated literal`() async throws {
        #expect(try await boundPayload(.array([.int(1), .int(2), .int(3)])) == "{\"1\",\"2\",\"3\"}")
    }

    @Test func `binds an empty array`() async throws {
        #expect(try await boundPayload(.array([])) == "{}")
    }

    /// A bare `NULL` is the only way to express a null element; a quoted `"NULL"` is the
    /// four-character string, which is why the two must not render alike.
    @Test func `distinguishes a null element from the literal text NULL`() async throws {
        #expect(try await boundPayload(.array([.null, .text("NULL")])) == "{NULL,\"NULL\"}")
    }

    /// Unquoted, each of these would change the array's shape rather than its contents.
    @Test func `quotes elements containing delimiters`() async throws {
        #expect(try await boundPayload(.array([.text("a,b")])) == "{\"a,b\"}")
        #expect(try await boundPayload(.array([.text("{x}")])) == "{\"{x}\"}")
        #expect(try await boundPayload(.array([.text(" padded ")])) == "{\" padded \"}")
        #expect(try await boundPayload(.array([.text("")])) == "{\"\"}")
    }

    @Test func `escapes backslash and double quote inside an element`() async throws {
        #expect(try await boundPayload(.array([.text("he said \"hi\"")])) == "{\"he said \\\"hi\\\"\"}")
        #expect(try await boundPayload(.array([.text("back\\slash")])) == "{\"back\\\\slash\"}")
    }

    /// `bytea` renders as `\xdeadbeef`, whose backslash must survive quoting.
    @Test func `escapes the bytea prefix backslash`() async throws {
        #expect(try await boundPayload(.array([.blob([0xde, 0xad])])) == "{\"\\\\xdead\"}")
    }

    @Test func `nests arrays without quoting the inner braces`() async throws {
        let nested: SQL.Value = .array([.array([.int(1), .int(2)]), .array([.int(3)])])
        #expect(try await boundPayload(nested) == "{{\"1\",\"2\"},{\"3\"}}")
    }

    @Test func `carries a decimal wider than any fixed-width decimal type`() async throws {
        let digits = "123456789012345678901234567890123456789.000000000000000000001"
        #expect(try await boundPayload(.decimal(digits)) == digits)
    }
}
