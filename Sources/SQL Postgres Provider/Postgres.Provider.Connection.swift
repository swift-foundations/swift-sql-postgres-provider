public import SQL

extension Postgres {
    /// The engine-free connection handle backed by one native PostgreSQL session.
    public struct Connection: SQL.Connection {
        private let session: Session<Postgres.SocketTransport>

        init(session: Session<Postgres.SocketTransport>) { self.session = session }

        public func execute(_ statement: some SQL.Statement) async throws(SQL.Error) -> Int {
            do throws(Postgres.Error) {
                return try await session.execute(sql: statement.sql, bindings: statement.bindings).count
            } catch {
                throw error.sql
            }
        }

        public func fetchAll<Value: Sendable>(
            _ statement: some SQL.Statement,
            // `any SQL.Row` is the parameter type in swift-sql's own `SQL.Connection` requirement; a conformance cannot narrow it.
            // swiftlint:disable:next no_any_protocol_existential
            decode: (any SQL.Row) throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> [Value] {
            let rows: [Postgres.Row]
            do throws(Postgres.Error) {
                rows = try await session.execute(sql: statement.sql, bindings: statement.bindings).rows
            } catch {
                throw error.sql
            }
            return try rows.map(decode)
        }

        public func fetchOne<Value: Sendable>(
            _ statement: some SQL.Statement,
            // `any SQL.Row` is the parameter type in swift-sql's own `SQL.Connection` requirement; a conformance cannot narrow it.
            // swiftlint:disable:next no_any_protocol_existential
            decode: (any SQL.Row) throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value? {
            try await fetchAll(statement, decode: decode).first
        }
    }
}
