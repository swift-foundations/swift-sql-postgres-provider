internal import Domain_Name_System
internal import Byte_Channel
internal import Cardinal_Primitives_Standard_Library_Integration
internal import IO
internal import Kernel
internal import Sockets
internal import Sockets_Byte_Channel
internal import TLS
internal import TLS_Engine_Interface

extension Postgres {
    /// The asynchronous byte transport a PostgreSQL session speaks over.
    protocol Transport {
        func readExact(_ count: Index<Byte>.Count) async throws(Postgres.Error) -> sending Byte.Chunk
        func writeAll(_ bytes: borrowing Byte.Chunk) async throws(Postgres.Error)
        func close() async
    }
}

extension Postgres {
    /// Namespace for the provider's composition of ordered DNS, TCP, and authenticated TLS.
    enum Socket {}
}

extension Postgres.Socket {
    /// A PostgreSQL byte transport backed by one authenticated TLS session.
    ///
    /// TCP ownership and all platform I/O remain in `Sockets`; the injected TLS engine owns its
    /// handshake and certificate validation. This adapter only supplies exact-read buffering for
    /// the PostgreSQL framing protocol.
    actor Transport: Postgres.Transport {
        /// Actor isolation serializes the live-to-closed transition. Moving the session out and
        /// installing `nil` before the first suspension makes exactly one caller the close owner.
        /// If this actor is dropped while live, `TLS.Session` and `Pump` synchronously initiate
        /// their guarded cancellation hooks; orderly asynchronous runner shutdown requires close.
        private var session: TLS.Session?
        private var pump: Sockets.TCP.Connection.Pump<TLS.Failure>?
        private let runner: IO<Sockets.Capabilities>.Runner
        private var buffered: [Byte] = []

        init<Resolver: DNS.Resolving>(
            configuration: Postgres.Configuration,
            resolver: Resolver,
            tls: TLS.Engine.Witness,
            peer: TLS.PeerPolicy
        ) async throws(Postgres.Error) {
            let tlsConfiguration = TLS.Configuration(identity: configuration.identity, peer: peer)

            let addresses: [IP.Address]
            do {
                addresses = try await tlsConfiguration.resolve(using: resolver)
            } catch {
                throw .connection("DNS resolution failed: \(error)")
            }
            guard addresses.isEmpty == false else { throw .connection("DNS resolution returned no addresses") }

            var failure: Postgres.Error = .connection("no resolved address accepted a connection")
            for address in addresses {
                let io: IO<Sockets.Capabilities>
                do {
                    io = try .events()
                } catch {
                    failure = .connection("event I/O creation failed: \(error)")
                    continue
                }

                do {
                    let socket = try await Self.connect(address, port: configuration.port, io: io)
                    let (pumpChannel, tlsChannel) = Byte.Channel<TLS.Failure>.pair(capacity: .init(.init(16_384)))
                    let pump = socket.pump(
                        consume pumpChannel,
                        maximum: .init(16_384),
                        failure: Self.tlsFailure
                    )
                    do {
                        let establishedSession = try await tls.wrap(
                            encrypted: consume tlsChannel,
                            configuration: tlsConfiguration
                        )
                        // The handshake sends unique, non-Sendable session ownership into this
                        // actor. Install it once; no alias remains in the caller's region.
                        self.session = consume establishedSession
                    } catch {
                        await pump.close()
                        throw error
                    }
                    self.pump = consume pump
                    runner = io.runner
                    return
                } catch let error as Postgres.Error {
                    failure = error
                } catch {
                    failure = .connection("connection or TLS handshake failed: \(error)")
                }
                await io.runner.shutdown()
            }
            throw failure
        }

        func readExact(_ count: Index<Byte>.Count) async throws(Postgres.Error) -> sending Byte.Chunk {
            let required = Int(clamping: count)
            while buffered.count < required {
                let chunk: Byte.Chunk?
                switch session {
                case .some(let session):
                    do {
                        chunk = try await session.read(
                            maximum: .init(UInt(Swift.max(1, required - buffered.count)))
                        )
                    }
                    catch { throw Self.error(error) }
                case .none:
                    throw .connection("connection is closed")
                }
                guard let chunk else { throw .connection("peer closed the connection") }
                let span = chunk.span
                for index in span.indices { buffered.append(span[index]) }
            }
            let result = Byte.Chunk(capacity: count) { output in
                for byte in buffered.prefix(required) { output.append(byte) }
            }
            buffered.removeFirst(required)
            return consume result
        }

        func writeAll(_ bytes: borrowing Byte.Chunk) async throws(Postgres.Error) {
            switch session {
            case .some(let session):
                do { try await session.write(bytes) }
                catch { throw Self.error(error) }
            case .none:
                throw .connection("connection is closed")
            }
        }

        func close() async {
            let session = consume self.session
            self.session = nil
            guard let session = consume session else { return }
            await session.close()
            let pump = consume self.pump
            self.pump = nil
            if let pump = consume pump {
                await pump.close()
            }
            await runner.shutdown()
        }

        private static func connect(
            _ address: IP.Address,
            port: UInt16,
            io: IO<Sockets.Capabilities>
        ) async throws(Postgres.Error) -> sending Sockets.TCP.Connection {
            do {
                switch address {
                case .v4(let address):
                    return try await Sockets.TCP.Connection.connect(
                        to: Kernel.Socket.Address.IPv4(address: address.bigEndian, port: port), io: io
                    )
                case .v6(let address):
                    return try await Sockets.TCP.Connection.connect(
                        to: Kernel.Socket.Address.IPv6(segments: address.segments, port: port), io: io
                    )
                }
            } catch { throw .connection("TCP connection failed: \(error)") }
        }

        private static func error(_ error: TLS.Failure) -> Postgres.Error {
            switch error {
            case .cancelled: .cancelled
            case .closed: .connection("TLS session is closed")
            default: .connection("TLS session failed: \(error)")
            }
        }

        /// Maps every socket-domain outcome at the Sockets/TLS membrane.
        private static func tlsFailure(_ error: Sockets.Error) -> TLS.Failure {
            switch error {
            case .cancelled:
                .cancelled
            case .closed:
                .closed
            case .descriptor, .registration, .wouldBlock, .connectionReset, .notConnected, .ioShutdown, .timeout, .platform:
                .transport
            }
        }
    }
}
