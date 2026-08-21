public import SQL

extension Postgres {

    public struct Connection: SQL.Connection {
        private let session: Session<Postgres.Socket.Transport>

        init(session: Session<Postgres.Socket.Transport>) { self.session = session }

        public func execute(_ statement: some SQL.Statement) async throws(SQL.Error) -> Int {
            do throws(Postgres.Error) {
                return try await session.execute(sql: statement.sql, bindings: statement.bindings)
                    .count
            } catch {
                throw error.sql
            }
        }

        public func fetchAll<Value: Sendable>(
            _ statement: some SQL.Statement,

            decode: (any SQL.Row) throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> [Value] {
            let rows: [Postgres.Row]
            do throws(Postgres.Error) {
                rows = try await session.execute(sql: statement.sql, bindings: statement.bindings)
                    .rows
            } catch {
                throw error.sql
            }
            return try rows.map(decode)
        }

        public func fetchOne<Value: Sendable>(
            _ statement: some SQL.Statement,

            decode: (any SQL.Row) throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value? {
            try await fetchAll(statement, decode: decode).first
        }
    }
}
