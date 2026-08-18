extension Postgres {
    /// Explicit connection and pool configuration for the native client.
    public struct Configuration: Sendable, Hashable {
        public let host: String
        public let port: UInt16
        public let database: String
        public let user: String
        public let password: String?
        public let maxConnections: Int

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
            guard maxConnections > 0 else {
                throw .configuration("maxConnections must be positive")
            }
            self.host = host
            self.port = port
            self.database = database
            self.user = user
            self.password = password
            self.maxConnections = maxConnections
        }
    }
}
