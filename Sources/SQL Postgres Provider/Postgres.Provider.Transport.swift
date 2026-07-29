internal import Byte_Primitives
internal import ISO_9945_Kernel_Poll
internal import ISO_9945_Kernel_Socket
internal import ISO_9945_Kernel_Socket_Address
internal import POSIX_Kernel_Poll
internal import POSIX_Kernel_Socket
internal import SQL

extension Postgres {
    /// The byte transport a ``Postgres/Session`` speaks the PostgreSQL wire protocol over.
    ///
    /// `Session` owns framing, startup, SCRAM authentication and the extended query flow. This
    /// owns getting bytes to and from the far end. They are separated because they have
    /// different reasons to change — one tracks the PostgreSQL protocol, the other tracks the
    /// platform — and because the wire protocol is untestable while it is welded to a socket.
    ///
    /// A conforming type handles short reads and writes, applies the correct `EINTR` policy, and
    /// abandons a blocking wait when the surrounding `Task` is cancelled.
    protocol Transport: Sendable {
        /// Reads exactly `count` bytes, blocking until they arrive.
        ///
        /// Throws ``Postgres/Error/cancelled`` if the surrounding task is cancelled while
        /// waiting, and ``Postgres/Error/connection(_:)`` if the peer closes first.
        func readExact(_ count: Int) throws(Postgres.Error) -> [UInt8]

        /// Writes every byte, blocking until all of them are accepted.
        func writeAll(_ bytes: [UInt8]) throws(Postgres.Error)

        /// Releases the underlying resource. Idempotent.
        func close()
    }
}

extension Postgres {
    /// Namespace for the socket-backed transport.
    enum Socket {}
}

extension Postgres.Socket {
    /// A ``Postgres/Transport`` over a blocking IPv4 TCP socket.
    ///
    /// Every syscall goes through the Institute's POSIX stack rather than a platform module:
    /// `swift-iso-9945` binds the syscalls and owns the `#if canImport(Darwin)/Glibc` seam, and
    /// `swift-posix` layers the `EINTR` policy on top. Nothing here names a platform, which is
    /// what makes this file — and therefore the package — build off Apple platforms.
    ///
    /// The `connect` policy is the reason to compose rather than hand-roll. `EINTR` on
    /// `connect(2)` does **not** mean "retry the call": the connection attempt continues
    /// asynchronously, and the correct recovery is `poll(POLLOUT)` then `getsockopt(SO_ERROR)`.
    /// `POSIX.Kernel.Socket.Connect` implements exactly that. The hand-rolled predecessor
    /// retried nothing and closed the descriptor instead — swift-institute/Issues#60.
    ///
    /// Remaining limitations, all this type's rather than the protocol's: IPv4 literals only
    /// (`Kernel.Socket.Address.Info` would supply DNS and IPv6), and no TLS.
    final class Transport: @unchecked Sendable, Postgres.Transport {
        /// `ISO_9945.Kernel.Socket.Descriptor` is `~Copyable` with an owning `deinit`, so it
        /// cannot be moved out of a class property. `close()` therefore shuts the connection
        /// down — which only borrows — and the descriptor's own `deinit` performs `close(2)`
        /// when this object is released. Shutdown is what the peer observes; the descriptor is
        /// released deterministically with the transport.
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
                // Deliberately terminal. A failed shutdown means the connection is already
                // gone — `ENOTCONN` when the peer hung up first is the ordinary case — and
                // `close()` is the idempotent teardown path with no caller left to inform.
                // The descriptor is released by its own `deinit` regardless.
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
                // EINTR-safe: completes through poll(POLLOUT) + getsockopt(SO_ERROR) rather than
                // retrying connect(2), which would report EALREADY.
                try POSIX.Kernel.Socket.Connect.connect(descriptor, address: address)
            } catch {
                throw .connection("connect failed: \(error)")
            }
            return descriptor
        }

        /// Parses a dotted quad into the address an `IPv4` carries.
        ///
        /// Hand-parsed rather than via `inet_pton`, which lives in a platform module. Anything
        /// that is not exactly four decimal octets is rejected, so a hostname fails here with a
        /// configuration error rather than silently becoming a wrong address.
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

        /// Waits for readiness in short slices, so a cancelled task does not block on the kernel.
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
                if returned.contains(.error) || returned.contains(.hangUp) || returned.contains(.invalid) {
                    throw .connection("socket polling failed: \(returned)")
                }
                return
            }
        }
    }
}
