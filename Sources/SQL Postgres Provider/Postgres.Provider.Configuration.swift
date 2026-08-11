public import TLS

extension Postgres {
    /// PostgreSQL endpoint and authentication material.
    ///
    /// Resolution, certificate policy, and TLS implementation are supplied at the database
    /// boundary.  This value therefore records the database endpoint without owning a resolver,
    /// trust store, or TLS backend.
    public struct Configuration: Sendable {
        public let identity: TLS.Peer.Identity
        public let port: UInt16
        public let database: String
        public let user: String
        public let password: String?
        public let maxConnections: Int

        /// Creates an endpoint identified by a validated DNS question.
        public init(
            identity: TLS.Peer.Identity,
            port: UInt16 = 5432,
            database: String,
            user: String,
            password: String? = nil,
            maxConnections: Int = 4
        ) throws(Postgres.Error) {
            guard identity.hostname.isEmpty == false else { throw .configuration("host is empty") }
            guard port > 0 else { throw .configuration("port must be positive") }
            guard database.isEmpty == false else { throw .configuration("database is empty") }
            guard user.isEmpty == false else { throw .configuration("user is empty") }
            guard maxConnections > 0 else { throw .configuration("maxConnections must be positive") }
            self.identity = identity
            self.port = port
            self.database = database
            self.user = user
            self.password = password
            self.maxConnections = maxConnections
        }
    }
}
