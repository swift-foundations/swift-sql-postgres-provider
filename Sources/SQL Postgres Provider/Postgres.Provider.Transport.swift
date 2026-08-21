internal import Byte_Primitives
internal import ISO_9945_Kernel_Poll
internal import ISO_9945_Kernel_Socket
internal import ISO_9945_Kernel_Socket_Address
internal import POSIX_Kernel_Poll
internal import POSIX_Kernel_Socket
internal import SQL

extension Postgres {

    protocol Transport: Sendable {

        func readExact(_ count: Int) throws(Postgres.Error) -> [UInt8]

        func writeAll(_ bytes: [UInt8]) throws(Postgres.Error)

        func close()
    }
}

extension Postgres {

    enum Socket {}
}

extension Postgres.Socket {

    final class Transport: @unchecked Sendable, Postgres.Transport {

        private let descriptor: ISO_9945.Kernel.Socket.Descriptor
        private var closed = false

        init(configuration: Postgres.Configuration) throws(Postgres.Error) {
            self.descriptor = try Self.connect(configuration)
        }

        func close() {
            guard closed == false else { return }
            closed = true
            do throws(ISO_9945.Kernel.Socket.Shutdown.Error) {
                try ISO_9945.Kernel.Socket.Shutdown.shutdown(descriptor, how: .both)
            } catch {

            }
        }

        private static func connect(
            _ configuration: Postgres.Configuration
        ) throws(Postgres.Error) -> ISO_9945.Kernel.Socket.Descriptor {
            let host = configuration.host == "localhost" ? "127.0.0.1" : configuration.host
            guard let address = Self.address(host: host, port: configuration.port) else {
                throw .configuration("native client requires an IPv4 address")
            }
            let descriptor: ISO_9945.Kernel.Socket.Descriptor
            do {
                descriptor = try ISO_9945.Kernel.Socket.Create.create(domain: .inet, kind: .stream)
            } catch {
                throw .connection("socket creation failed: \(error)")
            }
            do {

                try POSIX.Kernel.Socket.Connect.connect(descriptor, address: address)
            } catch {
                throw .connection("connect failed: \(error)")
            }
            return descriptor
        }

        private static func address(
            host: String,
            port: UInt16
        ) -> ISO_9945.Kernel.Socket.Address.IPv4? {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var raw: UInt32 = 0
            for part in parts {
                guard part.isEmpty == false,
                    part.count <= 3,
                    part.allSatisfy({ $0.isASCII && $0.isNumber }),
                    let octet = UInt8(part)
                else { return nil }
                raw = (raw << 8) | UInt32(octet)
            }
            return ISO_9945.Kernel.Socket.Address.IPv4(address: raw.bigEndian, port: port.bigEndian)
        }

        func readExact(_ count: Int) throws(Postgres.Error) -> [UInt8] {
            guard count >= 0 else { throw .protocolViolation("negative read length") }
            var result: [UInt8] = []
            result.reserveCapacity(count)
            while result.count < count {
                try wait(for: .input)
                var chunk = [Byte](repeating: Byte(0), count: count - result.count)
                let received = try Self.receive(descriptor, into: &chunk)
                if received == 0 { throw .connection("peer closed the connection") }
                result.append(contentsOf: chunk.prefix(received).map(\.underlying))
            }
            return result
        }

        private static func receive(
            _ descriptor: borrowing ISO_9945.Kernel.Socket.Descriptor,
            into chunk: inout [Byte]
        ) throws(Postgres.Error) -> Int {
            do {
                return try chunk.withUnsafeMutableBufferPointer { buffer in
                    var span = buffer.mutableSpan
                    return try POSIX.Kernel.Socket.Receive.receive(descriptor, into: &span)
                }
            } catch {
                throw .connection("read failed: \(error)")
            }
        }

        func writeAll(_ bytes: [UInt8]) throws(Postgres.Error) {
            let payload = bytes.map { Byte($0) }
            var offset = 0
            while offset < payload.count {
                try wait(for: .output)
                let sent = try Self.send(descriptor, payload, from: offset)
                guard sent > 0 else { throw .connection("write made no progress") }
                offset += sent
            }
        }

        private static func send(
            _ descriptor: borrowing ISO_9945.Kernel.Socket.Descriptor,
            _ payload: [Byte],
            from offset: Int
        ) throws(Postgres.Error) -> Int {
            do {
                return try payload.withUnsafeBufferPointer { buffer in
                    let remaining = UnsafeBufferPointer(rebasing: buffer[offset...])
                    return try POSIX.Kernel.Socket.Send.send(descriptor, from: remaining.span)
                }
            } catch {
                throw .connection("write failed: \(error)")
            }
        }

        private func wait(for events: ISO_9945.Kernel.Poll.Events) throws(Postgres.Error) {
            while true {
                guard Task.isCancelled == false else { throw .cancelled }
                var entries = [ISO_9945.Kernel.Poll.Entry(descriptor, requested: events)]
                let ready: Int
                do {
                    ready = try POSIX.Kernel.Poll.poll(&entries, timeout: 50)
                } catch {
                    throw .connection("poll failed: \(error)")
                }
                if ready == 0 { continue }
                let returned = entries[0].returned
                if returned.contains(.error) || returned.contains(.hangUp)
                    || returned.contains(.invalid)
                {
                    throw .connection("socket polling failed: \(returned)")
                }
                return
            }
        }
    }
}
