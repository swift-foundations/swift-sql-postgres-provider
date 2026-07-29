import Darwin
internal import SQL

extension Postgres {
    /// The byte transport a ``Postgres/Session`` speaks the PostgreSQL wire protocol over.
    ///
    /// `Session` owns framing, startup, SCRAM authentication and the extended query flow. This
    /// owns getting bytes to and from the far end. They are separated because they have
    /// different reasons to change — one tracks the PostgreSQL protocol, the other tracks the
    /// platform — and because the wire protocol is untestable while it is welded to a socket.
    ///
    /// Everything platform-specific lives behind this protocol: descriptors, readiness polling,
    /// `EINTR` policy, and address handling. A conforming type is expected to handle short
    /// reads and writes, to retry on `EINTR` where that is the correct policy, and to abandon a
    /// blocking wait when the surrounding `Task` is cancelled.
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
    /// A ``Postgres/Transport`` over a blocking IPv4 TCP socket.
    ///
    /// This is the only type in the package that names the kernel. It is deliberately the whole
    /// platform surface: replacing it with a swift-posix / swift-iso-9945 implementation is what
    /// makes the package build off Apple platforms, and nothing outside this file has to change
    /// for that to happen.
    ///
    /// Known limitations, all of them this type's rather than the protocol's: IPv4 literals only
    /// (no DNS, no IPv6), no TLS, and `connect` without `EINTR` completion —
    /// see swift-institute/Issues#60.
    final class SocketTransport: @unchecked Sendable, Transport {
        private var descriptor: Int32
        private var closed = false

        init(configuration: Postgres.Configuration) throws(Postgres.Error) {
            self.descriptor = try Self.connect(configuration)
        }

        deinit {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        func close() {
            guard closed == false else { return }
            closed = true
            Darwin.close(descriptor)
            descriptor = -1
        }

        private static func connect(_ configuration: Postgres.Configuration) throws(Postgres.Error) -> Int32 {
            let host = configuration.host == "localhost" ? "127.0.0.1" : configuration.host
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = configuration.port.bigEndian
            let parsed = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            guard parsed == 1 else { throw .configuration("native client requires an IPv4 address") }
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { throw .connection("socket creation failed: \(errno)") }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                let code = errno
                Darwin.close(socket)
                throw .connection("connect failed: \(code)")
            }
            return socket
        }

        func readExact(_ count: Int) throws(Postgres.Error) -> [UInt8] {
            guard count >= 0 else { throw .protocolViolation("negative read length") }
            var result: [UInt8] = []
            result.reserveCapacity(count)
            while result.count < count {
                try wait(for: Int16(POLLIN))
                var buffer = [UInt8](repeating: 0, count: count - result.count)
                let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if readCount < 0, errno == EINTR { continue }
                if readCount < 0 { throw .connection("read failed: \(errno)") }
                if readCount == 0 { throw .connection("peer closed the connection") }
                result.append(contentsOf: buffer.prefix(readCount))
            }
            return result
        }

        func writeAll(_ bytes: [UInt8]) throws(Postgres.Error) {
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLOUT))
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                }
                if written < 0, errno == EINTR { continue }
                if written < 0 { throw .connection("write failed: \(errno)") }
                guard written > 0 else { throw .connection("write made no progress") }
                offset += written
            }
        }

        /// Waits for readiness, in short slices so a cancelled task does not block on the kernel.
        private func wait(for events: Int16) throws(Postgres.Error) {
            while true {
                guard Task.isCancelled == false else { throw .cancelled }
                var pollfd = Darwin.pollfd(fd: descriptor, events: events, revents: 0)
                let result = Darwin.poll(&pollfd, 1, 50)
                if result < 0, errno == EINTR { continue }
                if result < 0 { throw .connection("poll failed: \(errno)") }
                if result == 0 { continue }
                if pollfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw .connection("socket polling failed: \(pollfd.revents)")
                }
                return
            }
        }
    }
}
