import Crypto

extension Postgres {
    enum SCRAM {
        static func first(username: String, nonce: String) -> String {
            "n,,n=\(escape(username)),r=\(nonce)"
        }

        static func final(
            password: String,
            first: String,
            serverFirst: String,
            nonce: String
        ) throws(Postgres.Error) -> (message: String, serverSignature: [UInt8]) {
            let fields = Dictionary(
                uniqueKeysWithValues: serverFirst.split(separator: ",").compactMap { field in
                    let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? (pair[0], pair[1]) : nil
                }
            )
            guard let combinedNonce = fields["r"], combinedNonce.hasPrefix(nonce),
                let encodedSalt = fields["s"], let iteration = Int(fields["i"] ?? "")
            else {
                throw .authentication("invalid SCRAM server-first-message")
            }
            guard let salt = Self.decodeBase64(encodedSalt), iteration > 0 else {
                throw .authentication("invalid SCRAM salt or iteration count")
            }

            let clientBare = String(first.dropFirst(3))
            let withoutProof = "c=biws,r=\(combinedNonce)"
            let authMessage = "\(clientBare),\(serverFirst),\(withoutProof)"
            let salted = pbkdf2(
                password: Array(password.utf8),
                salt: Array(salt),
                iterations: iteration
            )
            let clientKey = hmac(key: salted, message: Array("Client Key".utf8))
            let storedKey = Array(SHA256.hash(data: clientKey))
            let clientSignature = hmac(key: storedKey, message: Array(authMessage.utf8))
            let proof = zip(clientKey, clientSignature).map { $0 ^ $1 }
            let serverKey = hmac(key: salted, message: Array("Server Key".utf8))
            let serverSignature = hmac(key: serverKey, message: Array(authMessage.utf8))
            return ("\(withoutProof),p=\(Self.encodeBase64(proof))", serverSignature)
        }

        static func verify(serverFinal: String, expected: [UInt8]) throws(Postgres.Error) {
            let fields = Dictionary(
                uniqueKeysWithValues: serverFinal.split(separator: ",").compactMap { field in
                    let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? (pair[0], pair[1]) : nil
                }
            )
            guard fields["v"] == Self.encodeBase64(expected) else {
                throw .authentication("SCRAM server signature mismatch")
            }
        }

        private static func escape(_ username: String) -> String {
            username.reduce(into: "") { result, character in
                switch character {
                case "=": result.append("=3D")
                case ",": result.append("=2C")
                default: result.append(character)
                }
            }
        }

        private static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
            Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        }

        private static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
            var first = salt
            first.append(contentsOf: [0, 0, 0, 1])
            var result = hmac(key: password, message: first)
            var previous = result
            if iterations > 1 {
                for _ in 2...iterations {
                    previous = hmac(key: password, message: previous)
                    result = zip(result, previous).map { $0 ^ $1 }
                }
            }
            return result
        }

        private static let alphabet = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        ).map { UInt8($0.asciiValue!) }

        private static func encodeBase64(_ bytes: [UInt8]) -> String {
            var result: [UInt8] = []
            result.reserveCapacity((bytes.count + 2) / 3 * 4)
            var index = 0
            while index < bytes.count {
                let first = bytes[index]
                let second = index + 1 < bytes.count ? bytes[index + 1] : 0
                let third = index + 2 < bytes.count ? bytes[index + 2] : 0
                result.append(alphabet[Int(first >> 2)])
                result.append(alphabet[Int((first & 3) << 4 | second >> 4)])
                result.append(
                    index + 1 < bytes.count ? alphabet[Int((second & 15) << 2 | third >> 6)] : 61
                )
                result.append(index + 2 < bytes.count ? alphabet[Int(third & 63)] : 61)
                index += 3
            }
            return String(decoding: result, as: UTF8.self)
        }

        private static func decodeBase64(_ value: String) -> [UInt8]? {
            let bytes = Array(value.utf8)
            guard bytes.count.isMultiple(of: 4) else { return nil }
            var lookup = [UInt8](repeating: 255, count: 256)
            for (index, byte) in alphabet.enumerated() { lookup[Int(byte)] = UInt8(index) }
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count / 4 * 3)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let a = lookup[Int(bytes[index])]
                let b = lookup[Int(bytes[index + 1])]
                guard a != 255, b != 255 else { return nil }
                let c = bytes[index + 2] == 61 ? 0 : lookup[Int(bytes[index + 2])]
                let d = bytes[index + 3] == 61 ? 0 : lookup[Int(bytes[index + 3])]
                guard c != 255, d != 255 else { return nil }
                result.append(a << 2 | b >> 4)
                if bytes[index + 2] != 61 { result.append(b << 4 | c >> 2) }
                if bytes[index + 3] != 61 { result.append(c << 6 | d) }
            }
            return result
        }
    }
}
