internal import SQL

extension Postgres {
    /// Failure domain of the native client. `SQL.Connection` maps this domain
    /// to the engine-free `SQL.Error` membrane.
    public enum Error: Swift.Error, Sendable, Hashable {
        case configuration(String)
        case connection(String)
        case authentication(String)
        case protocolViolation(String)
        case server(String)
        case execution(String)
        case transaction(String)
        case cancelled
        case frameTooLarge(Int)
    }
}

extension Postgres.Error {
    var sql: SQL.Error {
        switch self {
        case .configuration(let message): .connection(message)
        case .connection(let message): .connection(message)
        case .authentication(let message): .connection("authentication failed: \(message)")
        case .protocolViolation(let message): .execution("protocol violation: \(message)")
        case .server(let message): .execution(message)
        case .execution(let message): .execution(message)
        case .transaction(let message): .transaction(message)
        case .cancelled: .connection("cancelled")
        case .frameTooLarge(let size): .execution("frame too large: \(size) bytes")
        }
    }
}
