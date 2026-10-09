import CryptoKit
import Foundation

/// RFC 6238 TOTP (HMAC-SHA1 by default, 30 s step), the same as `oathtool --base32 --totp`.
public struct TOTP: Sendable {
    public var secret: Data
    public var digits: Int
    public var period: TimeInterval
    public var algorithm: OTPAuth.Algorithm

    public init(secret: Data, digits: Int = 6, period: TimeInterval = 30, algorithm: OTPAuth.Algorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// A stored secret: an otpauth URI (what the app saves) or a bare base32 seed.
    public init?(stored: String) {
        guard let entry = OTPAuth.parseAll(stored).first else { return nil }
        self = entry.totp
    }

    public init?(base32 seed: String, digits: Int = 6, period: TimeInterval = 30) {
        guard let data = Base32.decode(seed), !data.isEmpty else { return nil }
        self.init(secret: data, digits: digits, period: period)
    }

    public func counter(at date: Date) -> UInt64 {
        UInt64(floor(date.timeIntervalSince1970 / period))
    }

    /// Seconds until the current code rolls over.
    public func secondsRemaining(at date: Date) -> TimeInterval {
        period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
    }

    public func code(at date: Date) -> String { code(counter: counter(at: date)) }

    public func code(counter: UInt64) -> String {
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secret)
        let mac: Data
        switch algorithm {
        case .sha1: mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let truncated = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = truncated % modulus
        return String(repeating: "0", count: max(0, digits - String(value).count)) + String(value)
    }
}

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1f)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1f)]) }
        return out
    }

    /// Lenient RFC 4648 decode: ignores case, spaces, dashes and `=` padding.
    public static func decode(_ input: String) -> Data? {
        var lookup = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for ch in input.uppercased() where !" -=\t\n".contains(ch) {
            guard let v = lookup[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return out
    }
}
