import SQL
import Byte_Channel
import Byte_Primitives
import Cardinal_Primitives_Standard_Library_Integration
import Domain_Name_System
import TLS

@testable import SQL_Postgres_Provider

extension Postgres.Configuration {
    /// Test-only IP-literal route for the in-memory wire fixture.
    init(
        fixtureHost: String = "127.0.0.1",
        port: UInt16 = 5432,
        database: String,
        user: String,
        password: String? = nil,
        maxConnections: Int = 4
    ) throws(Postgres.Error) {
        try self.init(
            identity: .init(
                query: .init(name: try RFC_1035.Domain(fixtureHost)),
                hostname: fixtureHost
            ),
            port: port,
            database: database,
            user: user,
            password: password,
            maxConnections: maxConnections
        )
    }
}

/// A ``Postgres/Transport`` over a scripted byte buffer.
///
/// The point of the transport seam: it lets the PostgreSQL wire protocol — framing, startup,
/// authentication, the extended query flow — be exercised with no socket, no server, and no
/// environment variables. Before the split, the only tests that reached that code were the
/// three `Integration` ones, every one of which returns early unless four
/// `POSTGRES_NATIVE_TEST_*` variables are set, and which have therefore never run.
enum Memory {}

extension Memory {
    /// The test retains this reference after sending it into `Postgres.Session` so assertions can
    /// observe wire output. That deliberate concurrent sharing is the sole unchecked justification.
    final class Transport: Postgres.Transport, @unchecked Sendable {
        /// Bytes the backend "sends", consumed in order by `readExact`.
        private let inbound: [Byte]
        private var offset = 0
        /// Everything the session wrote, in order.
        private(set) var written: [Byte] = []
        private(set) var isClosed = false

        init(inbound: [Byte]) {
            self.inbound = inbound
        }

        /// Reading past the end models the peer hanging up, which is what a real socket reports.
        func readExact(_ count: Index<Byte>.Count) async throws(Postgres.Error) -> sending Byte.Chunk {
            let count = Int(clamping: count)
            guard offset + count <= inbound.count else { throw .connection("peer closed the connection") }
            defer { offset += count }
            return Byte.Chunk(capacity: .init(UInt(count))) { output in
                for byte in inbound[offset..<(offset + count)] { output.append(byte) }
            }
        }

        func writeAll(_ bytes: borrowing Byte.Chunk) async throws(Postgres.Error) {
            let span = bytes.span
            for index in span.indices { written.append(span[index]) }
        }

        func close() async {
            isClosed = true
        }
    }
}

// MARK: - Backend message construction

enum Backend {
    /// A tagged backend message: one type byte, then a four-byte big-endian length that
    /// *includes itself*, then the body.
    static func message(type: Byte, body: [Byte]) -> [Byte] {
        let length = UInt32(body.count + 4)
        return [type] + [
            Byte(UInt8(truncatingIfNeeded: length >> 24)),
            Byte(UInt8(truncatingIfNeeded: length >> 16)),
            Byte(UInt8(truncatingIfNeeded: length >> 8)),
            Byte(UInt8(truncatingIfNeeded: length)),
        ] + body
    }

    static func int32(_ value: Int32) -> [Byte] {
        [
            Byte(UInt8(truncatingIfNeeded: value >> 24)),
            Byte(UInt8(truncatingIfNeeded: value >> 16)),
            Byte(UInt8(truncatingIfNeeded: value >> 8)),
            Byte(UInt8(truncatingIfNeeded: value)),
        ]
    }

    static func cString(_ text: String) -> [Byte] { text.utf8.map(Byte.init) + [0] }

    /// `R` with an `AuthenticationOk` payload.
    static var authenticationOk: [Byte] { message(type: 82, body: int32(0)) }

    /// `R` requesting cleartext password authentication.
    static var authenticationCleartext: [Byte] { message(type: 82, body: int32(3)) }

    /// `Z` ReadyForQuery, transaction status `I` (idle).
    static var readyForQuery: [Byte] { message(type: 90, body: [Byte(UInt8(ascii: "I"))]) }

    /// `C` CommandComplete — the trailing integer of the tag is the affected-row count.
    static func commandComplete(_ tag: String) -> [Byte] {
        message(type: 67, body: cString(tag))
    }

    /// `E` ErrorResponse carrying a single `M`essage field.
    static func error(_ text: String) -> [Byte] {
        message(type: 69, body: [Byte(UInt8(ascii: "M"))] + cString(text) + [0])
    }
}
