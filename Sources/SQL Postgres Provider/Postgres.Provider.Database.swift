public import SQL
internal import Domain_Name_System
internal import Pool_Primitives
internal import TLS_Engine_Interface

extension Postgres {
    /// A bounded, cancellation-aware pool of authenticated PostgreSQL sessions.
    public actor Database: SQL.Database {
        private let pool: Pool.Bounded<Session<Postgres.Socket.Transport>>

        /// Creates a database from externally owned DNS and TLS capabilities.
        ///
        /// The resolver preserves its address order; the TLS witness authenticates the supplied
        /// endpoint identity before this provider begins PostgreSQL or SCRAM traffic.
        public init<Resolver: DNS.Resolving>(
            configuration: Postgres.Configuration,
            resolver: Resolver,
            tls: TLS.Engine.Witness,
            peer: TLS.PeerPolicy
        ) {
            pool = Pool.Bounded(
                capacity: Pool.Capacity(integerLiteral: configuration.maxConnections),
                create: {
                    do throws(Postgres.Error) {
                        return try await Session(
                            configuration: configuration,
                            resolver: resolver,
                            tls: tls,
                            peer: peer
                        )
                    } catch {
                        throw .creationFailed
                    }
                },
                destroy: { session in await session.close() }
            )
        }

        /// Rejects new checkouts, drains outstanding work, and closes each idle session exactly once.
        public func shutdown() async { await pool.shutdown() }

        public func read<Value: Sendable>(
            // `any SQL.Connection` is the parameter type in swift-sql's `SQL.Database` requirement.
            // swiftlint:disable:next no_any_protocol_existential
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withCheckout(body)
        }

        public func write<Value: Sendable>(
            // `any SQL.Connection` is the parameter type in swift-sql's `SQL.Database` requirement.
            // swiftlint:disable:next no_any_protocol_existential
            _ body: @Sendable (any SQL.Connection) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            try await withCheckout { session throws(SQL.Error) in
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
            try await withCheckout { session throws(SQL.Error) in
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

        /// Runs one scoped operation under the unique checked-out handle.
        ///
        /// The handle stays in this actor region. Success returns the session reusable only when
        /// the task is still active; every failure and cancellation consumes it as invalid. Pinned
        /// `SQL.Cursor` cannot retain this move-only handle, so an escaping cursor remains the
        /// explicit lower-owner blocker rather than acquiring a provider-local lifecycle box.
        private func withCheckout<Value: Sendable>(
            _ body: (Session<Postgres.Socket.Transport>) async throws(SQL.Error) -> Value
        ) async throws(SQL.Error) -> Value {
            let handle: Pool.Bounded<Session<Postgres.Socket.Transport>>.Handle
            do throws(Pool.Lifecycle.Error) {
                handle = try await pool.checkout()
            } catch {
                switch error {
                case .cancelled: throw .cancelled
                case .shutdown: throw .connection("database is shut down")
                case .creationFailed: throw .connection("connection creation failed")
                }
            }

            let outcome: Result<Value, SQL.Error>
            do throws(SQL.Error) {
                outcome = .success(try await body(handle.resource))
            } catch {
                outcome = .failure(error)
            }

            switch outcome {
            case .success where Task.isCancelled:
                let failure = await handle.resolve(.invalid(SQL.Error.cancelled))
                throw failure
            case .success(let value):
                return await handle.resolve(.reusable(value))
            case .failure(let failure):
                let failure = await handle.resolve(.invalid(failure))
                throw failure
            }
        }
    }
}

extension Postgres {
    /// Scopes a production database's pool lifecycle to one asynchronous operation.
    public static func withDatabase<Resolver: DNS.Resolving, Value: Sendable, Failure: Swift.Error>(
        configuration: Postgres.Configuration,
        resolver: Resolver,
        tls: TLS.Engine.Witness,
        peer: TLS.PeerPolicy,
        _ body: (Postgres.Database) async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let database = Postgres.Database(
            configuration: configuration,
            resolver: resolver,
            tls: tls,
            peer: peer
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
