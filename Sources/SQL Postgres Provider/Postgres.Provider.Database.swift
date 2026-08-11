public import SQL
internal import Domain_Name_System
internal import Either_Primitives
internal import Pools
internal import TLS_Apple_Engine

extension Postgres {
    /// A bounded, cancellation-aware lease of authenticated PostgreSQL sessions.
    public actor Database: SQL.Database {
        private let lease: Pool.Lease<Session<Postgres.Socket.Transport>>

        /// Creates a database from externally owned DNS and TLS capabilities.
        ///
        /// The resolver preserves its address order; the TLS witness authenticates the supplied
        /// endpoint identity before this provider begins PostgreSQL or SCRAM traffic.
        public init<Resolver: DNS.Resolving>(
            configuration: Postgres.Configuration,
            resolver: Resolver,
            tls: TLS.Engine.Witness,
            tlsConfiguration: TLS.Configuration
        ) {
            lease = Pool.Lease(
                capacity: Pool.Capacity(integerLiteral: configuration.maxConnections),
                create: {
                    do throws(Postgres.Error) {
                        return try await Session(
                            configuration: configuration,
                            resolver: resolver,
                            tls: tls,
                            tlsConfiguration: tlsConfiguration
                        )
                    } catch {
                        throw .creationFailed
                    }
                },
                destroy: { session in await session.close() }
            )
        }

        /// Rejects new leases, drains outstanding work, and closes each idle session exactly once.
        public func shutdown() async { await lease.shutdown() }

        public func read<Value: Sendable>(
            // `any SQL.Connection` is the parameter type in swift-sql's `SQL.Database` requirement.
            // swiftlint:disable:next no_any_protocol_existential
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withLease(body)
        }

        public func write<Value: Sendable>(
            // `any SQL.Connection` is the parameter type in swift-sql's `SQL.Database` requirement.
            // swiftlint:disable:next no_any_protocol_existential
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withLease { session throws(SQL.Error) in
                try await self.command(session, "BEGIN")
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
            // `any SQL.Connection` is the parameter type in swift-sql's `SQL.Database` requirement.
            // swiftlint:disable:next no_any_protocol_existential
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withLease { session throws(SQL.Error) in
                try await self.command(session, "BEGIN")
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

        private func command(_ session: Session<Postgres.Socket.Transport>, _ sql: String) async throws(SQL.Error) {
            do throws(Postgres.Error) { _ = try await session.execute(sql: sql) }
            catch { throw error.sql }
        }

        private func rollback(_ session: Session<Postgres.Socket.Transport>) async {
            do throws(SQL.Error) { try await command(session, "ROLLBACK") } catch {}
        }

        private func withLease<Value: Sendable>(
            _ body: @Sendable (Session<Postgres.Socket.Transport>) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            do throws(Either<Pool.Lifecycle.Error, SQL.Error>) {
                return try await lease.acquire { session throws(SQL.Error) in
                    .reusable(try await body(session))
                }
            } catch {
                switch error {
                case .left(.cancelled): throw .cancelled
                case .left(.shutdown): throw .connection("database is shut down")
                case .left(.creationFailed): throw .connection("connection creation failed")
                case .right(let failure): throw failure
                }
            }
        }
    }
}

extension Postgres {
    /// Scopes a production database's lease lifecycle to one asynchronous operation.
    public static func withDatabase<Resolver: DNS.Resolving, Value: Sendable, Failure: Swift.Error>(
        configuration: Postgres.Configuration,
        resolver: Resolver,
        tls: TLS.Engine.Witness,
        tlsConfiguration: TLS.Configuration,
        _ body: @Sendable (Postgres.Database) async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let database = Postgres.Database(
            configuration: configuration,
            resolver: resolver,
            tls: tls,
            tlsConfiguration: tlsConfiguration
        )
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
