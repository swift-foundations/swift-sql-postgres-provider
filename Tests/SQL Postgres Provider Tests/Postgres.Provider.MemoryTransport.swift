import SQL

@testable import SQL_Postgres_Provider

enum Memory {}

extension Memory {
    final class Transport: Postgres.Transport, @unchecked Sendable {

        private let inbound: [UInt8]
        private var offset = 0

        private(set) var written: [UInt8] = []
        private(set) var isClosed = false

        init(inbound: [UInt8]) {
            self.inbound = inbound
        }

        func readExact(_ count: Int) throws(Postgres.Error) -> [UInt8] {
            guard count >= 0 else { throw .protocolViolation("negative read length") }
            guard offset + count <= inbound.count else {
                throw .connection("peer closed the connection")
            }
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
}

enum Backend {

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

    static var authenticationOk: [UInt8] { message(type: 82, body: int32(0)) }

    static var authenticationCleartext: [UInt8] { message(type: 82, body: int32(3)) }

    static var readyForQuery: [UInt8] { message(type: 90, body: [UInt8(ascii: "I")]) }

    static func commandComplete(_ tag: String) -> [UInt8] {
        message(type: 67, body: cString(tag))
    }

    static func error(_ text: String) -> [UInt8] {
        message(type: 69, body: [UInt8(ascii: "M")] + cString(text) + [0])
    }
}
