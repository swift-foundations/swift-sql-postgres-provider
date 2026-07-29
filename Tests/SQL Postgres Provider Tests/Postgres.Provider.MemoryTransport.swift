@testable import SQL_Postgres_Provider
import SQL

/// A ``Postgres/Transport`` over a scripted byte buffer.
///
/// The point of the transport seam: it lets the PostgreSQL wire protocol — framing, startup,
/// authentication, the extended query flow — be exercised with no socket, no server, and no
/// environment variables. Before the split, the only tests that reached that code were the
/// three `Integration` ones, every one of which returns early unless four
/// `POSTGRES_NATIVE_TEST_*` variables are set, and which have therefore never run.
final class MemoryTransport: Postgres.Transport, @unchecked Sendable {
    /// Bytes the backend "sends", consumed in order by `readExact`.
    private let inbound: [UInt8]
    private var offset = 0
    /// Everything the session wrote, in order.
    private(set) var written: [UInt8] = []
    private(set) var isClosed = false

    init(inbound: [UInt8]) {
        self.inbound = inbound
    }

    /// Reading past the end models the peer hanging up, which is what a real socket reports.
    func readExact(_ count: Int) throws(Postgres.Error) -> [UInt8] {
        guard count >= 0 else { throw .protocolViolation("negative read length") }
        guard offset + count <= inbound.count else { throw .connection("peer closed the connection") }
        defer { offset += count }
        return Array(inbound[offset..<(offset + count)])
    }

    func writeAll(_ bytes: [UInt8]) throws(Postgres.Error) {
        written.append(contentsOf: bytes)
    }

    func close() {
        isClosed = true
    }
}

// MARK: - Backend message construction

enum Backend {
    /// A tagged backend message: one type byte, then a four-byte big-endian length that
    /// *includes itself*, then the body.
    static func message(type: UInt8, body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count + 4)
        return [type] + [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ] + body
    }

    static func int32(_ value: Int32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    static func cString(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }

    /// `R` with an `AuthenticationOk` payload.
    static var authenticationOk: [UInt8] { message(type: 82, body: int32(0)) }

    /// `R` requesting cleartext password authentication.
    static var authenticationCleartext: [UInt8] { message(type: 82, body: int32(3)) }

    /// `Z` ReadyForQuery, transaction status `I` (idle).
    static var readyForQuery: [UInt8] { message(type: 90, body: [UInt8(ascii: "I")]) }

    /// `C` CommandComplete — the trailing integer of the tag is the affected-row count.
    static func commandComplete(_ tag: String) -> [UInt8] {
        message(type: 67, body: cString(tag))
    }

    /// `E` ErrorResponse carrying a single `M`essage field.
    static func error(_ text: String) -> [UInt8] {
        message(type: 69, body: [UInt8(ascii: "M")] + cString(text) + [0])
    }
}
