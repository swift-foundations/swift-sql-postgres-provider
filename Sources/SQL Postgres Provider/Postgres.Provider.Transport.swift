internal import Domain_Name_System
internal import Byte_Channel
internal import IO
internal import Kernel
internal import Sockets
internal import Sockets_Byte_Channel
internal import TLS
internal import TLS_Engine_Interface

extension Postgres {
    /// The asynchronous byte transport a PostgreSQL session speaks over.
    protocol Transport: Sendable {
        func readExact(_ count: Int) async throws(Postgres.Error) -> [UInt8]
        func writeAll(_ bytes: [UInt8]) async throws(Postgres.Error)
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
        private let session: TLS.Session
        private var pump: Sockets.TCP.Connection.Pump<TLS.Failure>?
        private let runner: IO<Sockets.Capabilities>.Runner
        private var buffered: [UInt8] = []
        private var closed = false

        init<Resolver: DNS.Resolving>(
            configuration: Postgres.Configuration,
            resolver: Resolver,
            tls: TLS.Engine.Witness,
            tlsConfiguration: TLS.Configuration
        ) async throws(Postgres.Error) {
            guard let query = configuration.query else {
                throw .configuration("production transport requires a DNS query")
            }
            guard tlsConfiguration.query == query, tlsConfiguration.hostname == configuration.host else {
                throw .configuration("TLS identity must match the PostgreSQL DNS endpoint")
            }

            let addresses: [IP.Address]
            do {
                addresses = try await resolver.resolve(query)
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
                        session = try await tls.wrap(encrypted: consume tlsChannel, configuration: tlsConfiguration)
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

        func readExact(_ count: Int) async throws(Postgres.Error) -> [UInt8] {
            guard count >= 0 else { throw .protocolViolation("negative read length") }
            guard closed == false else { throw .connection("connection is closed") }
            while buffered.count < count {
                let bytes: [UInt8]
                do { bytes = try await session.read(maximum: Swift.max(1, count - buffered.count)) }
                catch { throw Self.error(error) }
                guard bytes.isEmpty == false else { throw .connection("peer closed the connection") }
                buffered.append(contentsOf: bytes)
            }
            let result = Array(buffered.prefix(count))
            buffered.removeFirst(count)
            return result
        }

        func writeAll(_ bytes: [UInt8]) async throws(Postgres.Error) {
            guard closed == false else { throw .connection("connection is closed") }
            do { try await session.write(bytes) }
            catch { throw Self.error(error) }
        }

        func close() async {
            guard closed == false else { return }
            closed = true
            await session.close()
            if let pump = consume self.pump {
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
