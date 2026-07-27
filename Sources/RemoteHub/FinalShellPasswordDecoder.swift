import CommonCrypto
import CryptoKit
import Foundation

enum FinalShellPasswordDecoder {
    static func decode(_ encodedPassword: String) -> String? {
        guard let buffer = Data(base64Encoded: encodedPassword), buffer.count > 8 else { return nil }
        let head = Array(buffer.prefix(8))
        let encrypted = Data(buffer.dropFirst(8))
        guard let key = derivedKey(from: head),
              let plaintext = decryptDES(encrypted, key: key) else { return nil }
        if let utf8 = String(data: plaintext, encoding: .utf8) {
            return utf8
        }
        return String(data: plaintext, encoding: .isoLatin1)
    }

    private static func derivedKey(from head: [UInt8]) -> Data? {
        guard head.count == 8 else { return nil }

        var divisorRandom = JavaRandom(seed: signedByte(head[5]))
        let divisor = divisorRandom.nextInt(bound: 127)
        guard divisor != 0 else { return nil }

        let seed = Int64(3_680_984_568_597_093_857) / Int64(divisor)
        var random = JavaRandom(seed: seed)
        let skipCount = Int(Int8(bitPattern: head[0]))
        if skipCount > 0 {
            for _ in 0..<skipCount { _ = random.nextLong() }
        }

        let nestedSeed = random.nextLong()
        var nestedRandom = JavaRandom(seed: nestedSeed)
        let values: [Int64] = [
            signedByte(head[4]),
            nestedRandom.nextLong(),
            signedByte(head[7]),
            signedByte(head[3]),
            nestedRandom.nextLong(),
            signedByte(head[1]),
            random.nextLong(),
            signedByte(head[2])
        ]

        var keyMaterial = Data()
        keyMaterial.reserveCapacity(values.count * MemoryLayout<Int64>.size)
        for value in values {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { keyMaterial.append(contentsOf: $0) }
        }

        let digest = Data(Insecure.MD5.hash(data: keyMaterial))
        return Data(digest.prefix(kCCKeySizeDES))
    }

    private static func decryptDES(_ encrypted: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeDES else { return nil }
        var output = Data(count: encrypted.count + kCCBlockSizeDES)
        let outputCapacity = output.count
        var outputLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            encrypted.withUnsafeBytes { encryptedBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        encryptedBytes.baseAddress,
                        encrypted.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func signedByte(_ value: UInt8) -> Int64 {
        Int64(Int8(bitPattern: value))
    }
}

private struct JavaRandom {
    private static let multiplier: UInt64 = 0x5DEECE66D
    private static let addend: UInt64 = 0xB
    private static let mask: UInt64 = (1 << 48) - 1

    private var seed: UInt64

    init(seed: Int64) {
        self.seed = (UInt64(bitPattern: seed) ^ Self.multiplier) & Self.mask
    }

    mutating func nextInt(bound: Int32) -> Int32 {
        precondition(bound > 0)
        if (bound & -bound) == bound {
            return Int32((Int64(bound) * Int64(next(bits: 31))) >> 31)
        }
        while true {
            let bits = next(bits: 31)
            let value = bits % bound
            let check = Int32(truncatingIfNeeded: bits &- value &+ (bound &- 1))
            if check >= 0 { return value }
        }
    }

    mutating func nextLong() -> Int64 {
        let high = Int64(next(bits: 32))
        let low = Int64(next(bits: 32))
        return (high << 32) &+ low
    }

    private mutating func next(bits: Int) -> Int32 {
        seed = (seed &* Self.multiplier &+ Self.addend) & Self.mask
        return Int32(truncatingIfNeeded: seed >> UInt64(48 - bits))
    }
}
