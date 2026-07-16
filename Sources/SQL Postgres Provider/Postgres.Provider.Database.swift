public import SQL

extension Postgres {
    /// A lazily connected, bounded pool of native PostgreSQL sessions.
    public actor Database: SQL.Database {
        private let configuration: Postgres.Configuration
        private var available: [Session] = []
        private var created = 0
        private var closed = false

        public init(configuration: Postgres.Configuration) {
            self.configuration = configuration
        }

        /// Closes idle sessions and prevents new leases. The enclosing lifetime
        /// should call this after all database work has completed.
        public func shutdown() async {
            closed = true
            let sessions = available
            available.removeAll(keepingCapacity: false)
            for session in sessions { await session.close() }
            created = 0
        }

        public func read<Value: Sendable>(
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withLease { (session: Session) throws(SQL.Error) -> Value in
                try await body(Postgres.Connection(session: session))
            }
        }

        public func write<Value: Sendable>(
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withLease { (session: Session) throws(SQL.Error) -> Value in
                try await self.begin(session)
                do throws(SQL.Error) {
                    let value = try await body(Postgres.Connection(session: session))
                    try await self.command(session, "COMMIT")
                    return value
                } catch {
                    await self.rollback(session)
                    throw error
                }
            }
        }

        public func withRollback<Value: Sendable>(
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withLease { (session: Session) throws(SQL.Error) -> Value in
                try await self.begin(session)
                do throws(SQL.Error) {
                    let value = try await body(Postgres.Connection(session: session))
                    try await self.command(session, "ROLLBACK")
                    return value
                } catch {
                    await self.rollback(session)
                    throw error
                }
            }
        }

        private func command(_ session: Session, _ sql: String) async throws(SQL.Error) {
            do throws(Postgres.Error) {
                _ = try await session.execute(sql: sql)
            } catch {
                throw error.sql
            }
        }

        private func begin(_ session: Session) async throws(SQL.Error) {
            try await command(session, "BEGIN")
        }

        private func rollback(_ session: Session) async {
            do throws(SQL.Error) { try await command(session, "ROLLBACK") } catch { }
        }

        private func acquire() async throws(SQL.Error) -> Session {
            while true {
                guard closed == false else { throw .connection("database is shut down") }
                if let session = available.popLast() { return session }
                if created < configuration.maxConnections {
                    created += 1
                    do throws(Postgres.Error) {
                        return try Session(configuration: configuration)
                    } catch {
                        created -= 1
                        throw error.sql
                    }
                }
                guard Task.isCancelled == false else { throw .connection("cancelled") }
                await Task.yield()
            }
        }

        private func withLease<Value: Sendable>(
            _ body: @Sendable (Session) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            let session = try await acquire()
            do throws(SQL.Error) {
                let value = try await body(session)
                if closed {
                    await session.close()
                    created -= 1
                } else {
                    available.append(session)
                }
                return value
            } catch {
                await session.close()
                created -= 1
                throw error
            }
        }
    }
}

extension Postgres {
    /// Scope helper that closes the pool after the body, including on failure.
    public static func withDatabase<Value: Sendable, Failure: Swift.Error>(
        configuration: Postgres.Configuration,
        _ body: @Sendable (Postgres.Database) async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let database = Postgres.Database(configuration: configuration)
        do throws(Failure) {
            let value = try await body(database)
            await database.shutdown()
            return value
        } catch {
            await database.shutdown()
            throw error
        }
    }
}
