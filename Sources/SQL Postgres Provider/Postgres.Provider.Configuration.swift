public import Domain_Name_System

extension Postgres {
    /// PostgreSQL endpoint and authentication material.
    ///
    /// Resolution, certificate policy, and TLS implementation are supplied at the database
    /// boundary.  This value therefore records the database endpoint without owning a resolver,
    /// trust store, or TLS backend.
    public struct Configuration: Sendable, Hashable {
        public let query: DNS.Query?
        public let host: String
        public let port: UInt16
        public let database: String
        public let user: String
        public let password: String?
        public let maxConnections: Int

        /// Creates an endpoint identified by a validated DNS question.
        public init(
            query: DNS.Query,
            host: String,
            port: UInt16 = 5432,
            database: String,
            user: String,
            password: String? = nil,
            maxConnections: Int = 4
        ) throws(Postgres.Error) {
            guard host.isEmpty == false else { throw .configuration("host is empty") }
            guard port > 0 else { throw .configuration("port must be positive") }
            guard database.isEmpty == false else { throw .configuration("database is empty") }
            guard user.isEmpty == false else { throw .configuration("user is empty") }
            guard maxConnections > 0 else { throw .configuration("maxConnections must be positive") }
            self.query = query
            self.host = host
            self.port = port
            self.database = database
            self.user = user
            self.password = password
            self.maxConnections = maxConnections
        }

        /// Retained for wire-protocol test fixtures. A production database requires the DNS
        /// question supplied by the designated initializer above.
        public init(
            host: String = "127.0.0.1",
            port: UInt16 = 5432,
            database: String,
            user: String,
            password: String? = nil,
            maxConnections: Int = 4
        ) throws(Postgres.Error) {
            guard host.isEmpty == false else { throw .configuration("host is empty") }
            guard port > 0 else { throw .configuration("port must be positive") }
            guard database.isEmpty == false else { throw .configuration("database is empty") }
            guard user.isEmpty == false else { throw .configuration("user is empty") }
            guard maxConnections > 0 else { throw .configuration("maxConnections must be positive") }
            self.query = nil
            self.host = host
            self.port = port
            self.database = database
            self.user = user
            self.password = password
            self.maxConnections = maxConnections
        }
    }
}
