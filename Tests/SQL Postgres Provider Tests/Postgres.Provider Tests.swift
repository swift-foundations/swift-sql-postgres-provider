@testable import SQL_Postgres_Provider
import Darwin
import SQL
import Testing
import Time_Primitive

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
                    Array("2026-07-16 12:34:56.123456789+02".utf8)
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
                  let port = UInt16(portText) else { return }
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
                #expect(probe == "")
            }
        }

        @Test func `managed database cancellation releases a bounded lease`() async throws {
            guard let host = environment("POSTGRES_NATIVE_TEST_HOST"),
                  let databaseName = environment("POSTGRES_NATIVE_TEST_DATABASE"),
                  let user = environment("POSTGRES_NATIVE_TEST_USER"),
                  let portText = environment("POSTGRES_NATIVE_TEST_PORT"),
                  let port = UInt16(portText) else { return }
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
