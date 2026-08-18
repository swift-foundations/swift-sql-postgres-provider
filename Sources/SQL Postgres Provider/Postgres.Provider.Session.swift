internal import RFC_4122
internal import SQL
internal import Time_Primitive

extension Postgres {
    /// The PostgreSQL wire protocol: framing, startup, SCRAM authentication, extended query.
    ///
    /// Byte transport is a ``Postgres/Transport``, so nothing here names a descriptor, a syscall
    /// or a platform. That split is what lets the protocol be exercised against an in-memory
    /// transport rather than only against a live server.
    ///
    /// Generic over its transport rather than holding `any Postgres.Transport`: the transport is
    /// chosen statically at every call site — `Socket.Transport` in production, the in-memory
    /// double in tests — so there is nothing for an existential to buy here.
    actor Session<Wire: Postgres.Transport> {
        private let configuration: Postgres.Configuration
        private let transport: Wire
        private var closed = false
        private var started = false

        /// Runs the wire protocol over a caller-supplied transport.
        ///
        /// The seam that makes startup and the SCRAM handshake testable without a server.
        init(configuration: Postgres.Configuration, transport: Wire) {
            self.configuration = configuration
            self.transport = transport
        }

        func close() {
            guard closed == false else { return }
            closed = true
            transport.close()
        }

        func execute(
            sql: String,
            bindings: [SQL.Value] = []
        ) async throws(Postgres.Error) -> (count: Int, rows: [Postgres.Row]) {
            guard closed == false else { throw .connection("connection is closed") }
            guard Task.isCancelled == false else { throw .cancelled }
            if started == false {
                try startup()
                started = true
            }
            try send(parse(sql))
            try send(bind(bindings))
            try send([68, 0, 80, 0])
            try send(executeMessage())
            try send([83, 0, 0, 0, 4])

            var columns: [String] = []
            var rows: [Postgres.Row] = []
            var count = 0
            while true {
                let message = try await receive()
                switch message.type {
                case 49, 50, 51, 116, 84:
                    if message.type == 84 { columns = try rowDescription(message.body) }

                case 68:
                    rows.append(try dataRow(message.body, columns: columns))

                case 67:
                    count = commandCount(message.body)

                case 90:
                    return (count, rows)

                case 69:
                    throw .server(errorMessage(message.body))

                default:
                    break
                }
            }
        }

        private func startup() throws(Postgres.Error) {
            var body = int32(196_608)
            body.append(contentsOf: cString("user"))
            body.append(contentsOf: cString(configuration.user))
            body.append(contentsOf: cString("database"))
            body.append(contentsOf: cString(configuration.database))
            body.append(contentsOf: cString("application_name"))
            body.append(contentsOf: cString("swift-sql-postgres-native"))
            body.append(0)
            try send(lengthPrefixed(body))

            var first: String?
            while true {
                let message = try receiveSynchronously()
                switch message.type {
                case 82:
                    let code = try int32Value(message.body, at: 0)
                    switch code {
                    case 0: break

                    case 3:
                        guard let password = configuration.password else {
                            throw .authentication("server requested a password")
                        }
                        try send(frame(type: 112, body: cString(password)))

                    case 10:
                        guard configuration.password != nil else {
                            throw .authentication("server requested SCRAM password")
                        }
                        let mechanisms = cStrings(message.body.dropFirst(4))
                        guard mechanisms.contains("SCRAM-SHA-256") else {
                            throw .authentication("SCRAM-SHA-256 is unavailable")
                        }
                        let nonce = Self.nonce()
                        let value = Postgres.SCRAM.first(username: configuration.user, nonce: nonce)
                        first = value
                        var initial = cString("SCRAM-SHA-256")
                        initial.append(contentsOf: int32(Int32(value.utf8.count)))
                        initial.append(contentsOf: value.utf8)
                        try send(frame(type: 112, body: initial))

                    case 11:
                        guard let first, let password = configuration.password else {
                            throw .authentication("invalid SCRAM state")
                        }
                        let serverFirst = String(
                            decoding: message.body.dropFirst(4).dropLast(),
                            as: UTF8.self
                        )
                        guard let nonce = first.split(separator: "r=").last.map(String.init) else {
                            throw .authentication("invalid SCRAM client-first-message")
                        }
                        let result = try Postgres.SCRAM.final(
                            password: password,
                            first: first,
                            serverFirst: serverFirst,
                            nonce: nonce
                        )
                        try send(frame(type: 112, body: cString(result.message)))
                        let final = try receiveSynchronously()
                        guard final.type == 82, try int32Value(final.body, at: 0) == 12 else {
                            throw .authentication("invalid SCRAM server-final exchange")
                        }
                        try Postgres.SCRAM.verify(
                            serverFinal: String(
                                decoding: final.body.dropFirst(4).dropLast(),
                                as: UTF8.self
                            ),
                            expected: result.serverSignature
                        )

                    case 12:
                        throw .authentication("unexpected SCRAM server-final message")

                    case 5, 7, 8, 9:
                        throw .authentication("authentication method \(code) is not implemented")

                    default:
                        throw .authentication("unknown authentication method \(code)")
                    }

                case 75, 83:
                    break

                case 90:
                    return

                case 69:
                    throw .server(errorMessage(message.body))

                case 65:
                    break

                default:
                    break
                }
            }
        }

        private func receive() async throws(Postgres.Error) -> (type: UInt8, body: [UInt8]) {
            guard Task.isCancelled == false else { throw .cancelled }
            return try receiveSynchronously()
        }

        /// Reads one backend message: a one-byte tag, a four-byte length inclusive of itself,
        /// then the body.
        private func receiveSynchronously() throws(Postgres.Error) -> (type: UInt8, body: [UInt8]) {
            let type = try transport.readExact(1)[0]
            let length = Int(try int32Value(transport.readExact(4), at: 0))
            guard length >= 4 else { throw .protocolViolation("message length is less than four") }
            guard length <= 16 * 1024 * 1024 else { throw .frameTooLarge(length) }
            return (type, try transport.readExact(length - 4))
        }

        private func send(_ bytes: [UInt8]) throws(Postgres.Error) {
            try transport.writeAll(bytes)
        }

        private func parse(_ sql: String) -> [UInt8] {
            frame(type: 80, body: [0] + cString(sql) + [0, 0])
        }

        private func bind(_ bindings: [SQL.Value]) -> [UInt8] {
            var body = cString("") + cString("")
            body.append(contentsOf: int16(1))
            body.append(contentsOf: int16(0))
            body.append(contentsOf: int16(Int16(bindings.count)))
            for binding in bindings {
                switch binding {
                case .null: body.append(contentsOf: int32(-1))

                default:
                    let bytes = Array(binding.text.utf8)
                    body.append(contentsOf: int32(Int32(bytes.count)))
                    body.append(contentsOf: bytes)
                }
            }
            body.append(contentsOf: int16(1))
            body.append(contentsOf: int16(0))
            return frame(type: 66, body: body)
        }

        private func executeMessage() -> [UInt8] { frame(type: 69, body: cString("") + int32(0)) }

        private func rowDescription(_ body: [UInt8]) throws(Postgres.Error) -> [String] {
            guard body.count >= 2 else { throw .protocolViolation("short row description") }
            var cursor = 2
            var names: [String] = []
            let count = Int(readUInt16(body, at: 0))
            for _ in 0..<count {
                let (name, next) = try readCString(body, at: cursor)
                cursor = next
                guard cursor + 18 <= body.count else {
                    throw .protocolViolation("short row description field")
                }
                cursor += 18
                names.append(name)
            }
            return names
        }

        private func dataRow(
            _ body: [UInt8],
            columns: [String]
        ) throws(Postgres.Error) -> Postgres.Row {
            guard body.count >= 2 else { throw .protocolViolation("short data row") }
            var cursor = 2
            let count = Int(readUInt16(body, at: 0))
            var values: [[UInt8]?] = []
            for _ in 0..<count {
                guard cursor + 4 <= body.count else {
                    throw .protocolViolation("short data row value")
                }
                let length = Int(readInt32(body, at: cursor))
                cursor += 4
                if length == -1 {
                    values.append(nil)
                } else {
                    guard length >= 0, cursor + length <= body.count else {
                        throw .protocolViolation("invalid data row length")
                    }
                    values.append(Array(body[cursor..<(cursor + length)]))
                    cursor += length
                }
            }
            return Postgres.Row(names: columns, values: values)
        }

        private func errorMessage(_ body: [UInt8]) -> String {
            var cursor = 0
            var fields: [String] = []
            while cursor < body.count, body[cursor] != 0 {
                let code = body[cursor]
                cursor += 1
                do throws(Postgres.Error) {
                    let (value, next) = try readCString(body, at: cursor)
                    fields.append("\(Character(UnicodeScalar(code))): \(value)")
                    cursor = next
                } catch {
                    break
                }
            }
            return fields.joined(separator: "; ")
        }

        private func commandCount(_ body: [UInt8]) -> Int {
            var end = body.count
            while end > 0, body[end - 1] == 0 { end -= 1 }
            let text = String(decoding: body[..<end], as: UTF8.self)
            return Int(text.split(separator: " ").last ?? "0") ?? 0
        }

        private static func nonce() -> String {
            var generator = SystemRandomNumberGenerator()
            return (0..<18).map { _ in
                String(
                    UInt8.random(in: .min ... .max, using: &generator),
                    radix: 16,
                    uppercase: false
                ).leftPadded(to: 2, with: "0")
            }.joined()
        }
    }
}

private func frame(type: UInt8, body: [UInt8]) -> [UInt8] {
    [type] + lengthPrefixed(body)
}

private func lengthPrefixed(_ body: [UInt8]) -> [UInt8] {
    int32(Int32(body.count + 4)) + body
}

private func cString(_ value: String) -> [UInt8] { Array(value.utf8) + [0] }

private func cStrings(_ body: ArraySlice<UInt8>) -> [String] {
    body.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
}

private func int16(_ value: Int16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}
private func int32(_ value: Int32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ]
}
private func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
    UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
}
private func readInt32(_ bytes: [UInt8], at index: Int) -> Int32 {
    Int32(
        bitPattern: UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(
            bytes[index + 2]
        ) << 8 | UInt32(bytes[index + 3])
    )
}

private func int32Value(_ bytes: [UInt8], at index: Int) throws(Postgres.Error) -> Int32 {
    guard index >= 0, index + 4 <= bytes.count else { throw .protocolViolation("short integer") }
    return readInt32(bytes, at: index)
}

private func readCString(_ bytes: [UInt8], at index: Int) throws(Postgres.Error) -> (String, Int) {
    guard bytes.indices.contains(index), let end = bytes[index...].firstIndex(of: 0) else {
        throw .protocolViolation("unterminated string")
    }
    return (String(decoding: bytes[index..<end], as: UTF8.self), end + 1)
}

extension String {
    fileprivate func leftPadded(to width: Int, with character: Character) -> String {
        count >= width ? self : String(repeating: String(character), count: width - count) + self
    }
}

private func sqlValueText(_ value: SQL.Value) -> String {
    switch value {
    case .text(let value): value
    case .int(let value): String(value)
    case .int64(let value): String(value)
    case .double(let value): String(value)
    case .bool(let value): value ? "true" : "false"
    case .uuid(let value): value.description
    case .timestamp(let value): timestampText(value)
    case .blob(let bytes): "\\x" + bytes.map(hex).joined()
    case .jsonb(let bytes): String(decoding: bytes, as: UTF8.self)

    // The digit string is already exact — emitting it verbatim is what keeps a `numeric`
    // wider than any fixed-width decimal type intact across the seam.
    case .decimal(let digits): digits
    case .array(let elements): arrayLiteral(elements)
    case .null: ""
    }
}

/// Renders an array as a PostgreSQL array literal: `{a,b,c}`, nesting as `{{a,b},{c}}`.
///
/// A `null` element is the bare word `NULL`; every other element is double-quoted. Quoting
/// unconditionally is valid for every element type — the server parses the quoted content with
/// the element type's own input function — and it removes an entire class of delimiter bug,
/// since an unquoted element containing `,`, `{`, `}`, whitespace, or the literal text `NULL`
/// would otherwise change the array's shape or smuggle in a null.
private func arrayLiteral(_ elements: [SQL.Value]) -> String {
    let rendered = elements.map { element -> String in
        switch element {
        case .null: return "NULL"
        case .array(let nested): return arrayLiteral(nested)
        default: return "\"" + quotedElement(sqlValueText(element)) + "\""
        }
    }
    return "{" + rendered.joined(separator: ",") + "}"
}

/// Escapes the two characters that are special inside a quoted array element.
private func quotedElement(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "\\": result.append("\\\\")
        case "\"": result.append("\\\"")
        default: result.append(character)
        }
    }
    return result
}

private func timestampText(_ value: Instant) -> String {
    do throws(Time.Error) {
        let time = try Time(
            secondsSinceEpoch: Int(value.secondsSinceUnixEpoch),
            nanoseconds: Int(value.nanosecondFraction)
        )
        return
            "\(time.year.rawValue)-\(decimal(time.month.rawValue, width: 2))-\(decimal(time.day.rawValue, width: 2)) \(decimal(time.hour.value, width: 2)):\(decimal(time.minute.value, width: 2)):\(decimal(time.second.value, width: 2)).\(decimal(time.millisecond.value, width: 3))\(decimal(time.microsecond.value, width: 3))\(decimal(time.nanosecond.value, width: 3))+00"
    } catch {
        return String(value.secondsSinceUnixEpoch)
    }
}

private func decimal(_ value: Int, width: Int) -> String {
    let text = String(value)
    return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
}

private func hex(_ value: UInt8) -> String {
    let alphabet = Array("0123456789abcdef")
    return String(alphabet[Int(value >> 4)]) + String(alphabet[Int(value & 15)])
}

extension SQL.Value {
    fileprivate var text: String { sqlValueText(self) }
}

extension Postgres.Session where Wire == Postgres.Socket.Transport {
    /// Opens a socket to the configured server and runs the wire protocol over it.
    init(configuration: Postgres.Configuration) throws(Postgres.Error) {
        self.init(
            configuration: configuration,
            transport: try Postgres.Socket.Transport(configuration: configuration)
        )
    }
}
