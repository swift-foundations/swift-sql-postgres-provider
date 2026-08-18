public import RFC_4122
public import SQL
public import Time_Primitive

extension Postgres {
    /// A text-format PostgreSQL result row behind the engine-free row membrane.
    public struct Row: SQL.Row {
        let names: [String]
        let values: [[UInt8]?]
    }
}

extension Postgres.Row {
    private func value(_ name: String) throws(SQL.Error) -> [UInt8]? {
        guard let index = names.firstIndex(of: name) else {
            throw .decoding("no such column \"\(name)\"")
        }
        return values[index]
    }

    private func value(at index: Int) throws(SQL.Error) -> [UInt8]? {
        guard values.indices.contains(index) else {
            throw .decoding("column index \(index) out of range")
        }
        return values[index]
    }

    private static func text(_ bytes: [UInt8], _ label: String) throws(SQL.Error) -> String {
        let value = String(decoding: bytes, as: UTF8.self)
        guard Array(value.utf8) == bytes else {
            throw .decoding("column \(label) is not UTF-8")
        }
        return value
    }

    private static func required(_ value: [UInt8]?, _ label: String) throws(SQL.Error) -> [UInt8] {
        guard let value else { throw .decoding("column \(label) is NULL") }
        return value
    }

    private static func integer<T: FixedWidthInteger>(
        _ bytes: [UInt8],
        _ label: String
    ) throws(SQL.Error) -> T {
        guard let value = T(try Self.text(bytes, label)) else {
            throw .decoding("column \(label) is not an integer")
        }
        return value
    }

    private static func floating(_ bytes: [UInt8], _ label: String) throws(SQL.Error) -> Double {
        guard let value = Double(try Self.text(bytes, label)) else {
            throw .decoding("column \(label) is not a floating-point value")
        }
        return value
    }

    private static func timestamp(_ bytes: [UInt8], _ label: String) throws(SQL.Error) -> Instant {
        let value = try Self.text(bytes, label)
        let pieces =
            value.split(separator: " ", maxSplits: 1).count == 2
            ? value.split(separator: " ", maxSplits: 1)
            : value.split(separator: "T", maxSplits: 1)
        guard pieces.count == 2 else { throw .decoding("column \(label) is not a timestamp") }

        let date = pieces[0].split(separator: "-")
        guard date.count == 3,
            let year = Int(date[0]),
            let month = Int(date[1]),
            let day = Int(date[2])
        else {
            throw .decoding("column \(label) has an invalid date")
        }

        var clock = pieces[1]
        var offset = 0
        if clock.last == "Z" {
            clock.removeLast()
        } else if let marker = clock.dropFirst(1).firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = clock[marker...]
            let sign = zone.first == "+" ? 1 : -1
            let fields = zone.dropFirst().split(separator: ":")
            guard fields.count <= 2, let hours = Int(fields[0]) else {
                throw .decoding("column \(label) has an invalid timezone")
            }
            let minutes = fields.count == 2 ? Int(fields[1]) : 0
            guard let minutes, hours <= 23, minutes <= 59 else {
                throw .decoding("column \(label) has an invalid timezone")
            }
            offset = sign * (hours * 3_600 + minutes * 60)
            clock = clock[..<marker]
        }

        let time = clock.split(separator: ":", maxSplits: 2)
        guard time.count == 3,
            let hour = Int(time[0]),
            let minute = Int(time[1])
        else {
            throw .decoding("column \(label) has an invalid time")
        }
        let seconds = time[2].split(separator: ".", maxSplits: 1)
        guard let second = Int(seconds[0]) else {
            throw .decoding("column \(label) has an invalid time")
        }
        let fraction: Int
        if seconds.count == 1 {
            fraction = 0
        } else {
            let digits = seconds[1]
            guard digits.isEmpty == false, digits.count <= 9, let value = Int(digits) else {
                throw .decoding("column \(label) has invalid timestamp precision")
            }
            fraction = value * Self.powerOfTen(9 - digits.count)
        }

        do throws(Time.Error) {
            let time = try Time(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second,
                millisecond: fraction / 1_000_000,
                microsecond: fraction / 1_000 % 1_000,
                nanosecond: fraction % 1_000
            )
            let instant = Instant(time)
            return Instant(
                _unchecked: (),
                secondsSinceUnixEpoch: instant.secondsSinceUnixEpoch - Int64(offset),
                nanosecondFraction: instant.nanosecondFraction
            )
        } catch {
            throw .decoding("column \(label) is not a valid UTC timestamp")
        }
    }

    private static func powerOfTen(_ exponent: Int) -> Int {
        exponent == 0 ? 1 : (0..<exponent).reduce(1) { value, _ in value * 10 }
    }

    private static func bytes(_ value: [UInt8], _ label: String) throws(SQL.Error) -> [UInt8] {
        guard value.starts(with: [92, 120]) else { return value }
        let hex = value.dropFirst(2)
        guard hex.count.isMultiple(of: 2) else {
            throw .decoding("column \(label) has invalid bytea hex")
        }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next(),
            let highValue = UInt8(String(UnicodeScalar(high)), radix: 16),
            let lowValue = UInt8(String(UnicodeScalar(low)), radix: 16)
        {
            result.append(highValue * 16 + lowValue)
        }
        guard result.count == hex.count / 2 else {
            throw .decoding("column \(label) has invalid bytea hex")
        }
        return result
    }

    private static func uuid(_ bytes: [UInt8], _ label: String) throws(SQL.Error) -> RFC_4122.UUID {
        let text = try Self.text(bytes, label)
        do throws(RFC_4122.UUID.Error) {
            return try RFC_4122.UUID(text)
        } catch {
            throw .decoding("column \(label) is not a UUID")
        }
    }

    private static func bool(_ bytes: [UInt8], _ label: String) throws(SQL.Error) -> Bool {
        switch try Self.text(bytes, label) {
        case "t", "true": return true
        case "f", "false": return false
        default: throw .decoding("column \(label) is not a boolean")
        }
    }
}

extension Postgres.Row {
    private static func optional<Value>(
        _ value: [UInt8]?,
        convert: ([UInt8]) throws(SQL.Error) -> Value
    ) throws(SQL.Error) -> Value? {
        guard let value else { return nil }
        return try convert(value)
    }

    public func string(_ column: String) throws(SQL.Error) -> String {
        try Self.text(Self.required(value(column), column), column)
    }
    public func int(_ column: String) throws(SQL.Error) -> Int {
        try Self.integer(Self.required(value(column), column), column)
    }
    public func int64(_ column: String) throws(SQL.Error) -> Int64 {
        try Self.integer(Self.required(value(column), column), column)
    }
    public func double(_ column: String) throws(SQL.Error) -> Double {
        try Self.floating(Self.required(value(column), column), column)
    }
    public func bool(_ column: String) throws(SQL.Error) -> Bool {
        try Self.bool(Self.required(value(column), column), column)
    }
    public func uuid(_ column: String) throws(SQL.Error) -> RFC_4122.UUID {
        try Self.uuid(Self.required(value(column), column), column)
    }
    public func timestamp(_ column: String) throws(SQL.Error) -> Instant {
        try Self.timestamp(Self.required(value(column), column), column)
    }
    public func bytes(_ column: String) throws(SQL.Error) -> [UInt8] {
        try Self.bytes(Self.required(value(column), column), column)
    }

    public func stringIfPresent(_ column: String) throws(SQL.Error) -> String? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> String in
            try Self.text(bytes, column)
        }
    }
    public func intIfPresent(_ column: String) throws(SQL.Error) -> Int? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> Int in
            try Self.integer(bytes, column)
        }
    }
    public func int64IfPresent(_ column: String) throws(SQL.Error) -> Int64? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> Int64 in
            try Self.integer(bytes, column)
        }
    }
    public func doubleIfPresent(_ column: String) throws(SQL.Error) -> Double? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> Double in
            try Self.floating(bytes, column)
        }
    }
    public func boolIfPresent(_ column: String) throws(SQL.Error) -> Bool? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> Bool in
            try Self.bool(bytes, column)
        }
    }
    public func uuidIfPresent(_ column: String) throws(SQL.Error) -> RFC_4122.UUID? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> RFC_4122.UUID in
            try Self.uuid(bytes, column)
        }
    }
    public func timestampIfPresent(_ column: String) throws(SQL.Error) -> Instant? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> Instant in
            try Self.timestamp(bytes, column)
        }
    }
    public func bytesIfPresent(_ column: String) throws(SQL.Error) -> [UInt8]? {
        try Self.optional(value(column)) { (bytes: [UInt8]) throws(SQL.Error) -> [UInt8] in
            try Self.bytes(bytes, column)
        }
    }

    public func string(at index: Int) throws(SQL.Error) -> String {
        try Self.text(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func int(at index: Int) throws(SQL.Error) -> Int {
        try Self.integer(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func int64(at index: Int) throws(SQL.Error) -> Int64 {
        try Self.integer(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func double(at index: Int) throws(SQL.Error) -> Double {
        try Self.floating(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func bool(at index: Int) throws(SQL.Error) -> Bool {
        try Self.bool(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func uuid(at index: Int) throws(SQL.Error) -> RFC_4122.UUID {
        try Self.uuid(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func timestamp(at index: Int) throws(SQL.Error) -> Instant {
        try Self.timestamp(Self.required(value(at: index), "\(index)"), "\(index)")
    }
    public func bytes(at index: Int) throws(SQL.Error) -> [UInt8] {
        try Self.bytes(Self.required(value(at: index), "\(index)"), "\(index)")
    }

    public func stringIfPresent(at index: Int) throws(SQL.Error) -> String? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> String in
            try Self.text(bytes, "\(index)")
        }
    }
    public func intIfPresent(at index: Int) throws(SQL.Error) -> Int? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> Int in
            try Self.integer(bytes, "\(index)")
        }
    }
    public func int64IfPresent(at index: Int) throws(SQL.Error) -> Int64? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> Int64 in
            try Self.integer(bytes, "\(index)")
        }
    }
    public func doubleIfPresent(at index: Int) throws(SQL.Error) -> Double? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> Double in
            try Self.floating(bytes, "\(index)")
        }
    }
    public func boolIfPresent(at index: Int) throws(SQL.Error) -> Bool? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> Bool in
            try Self.bool(bytes, "\(index)")
        }
    }
    public func uuidIfPresent(at index: Int) throws(SQL.Error) -> RFC_4122.UUID? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> RFC_4122.UUID in
            try Self.uuid(bytes, "\(index)")
        }
    }
    public func timestampIfPresent(at index: Int) throws(SQL.Error) -> Instant? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> Instant in
            try Self.timestamp(bytes, "\(index)")
        }
    }
    public func bytesIfPresent(at index: Int) throws(SQL.Error) -> [UInt8]? {
        try Self.optional(value(at: index)) { (bytes: [UInt8]) throws(SQL.Error) -> [UInt8] in
            try Self.bytes(bytes, "\(index)")
        }
    }
}
