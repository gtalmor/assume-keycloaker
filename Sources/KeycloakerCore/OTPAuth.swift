import CryptoKit
import Foundation

/// One authenticator entry: what an `otpauth://totp/…` QR code (or an authenticator export) holds.
public struct OTPAuth: Equatable, Sendable {
    public enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    public var secret: Data
    public var issuer: String?
    public var account: String?
    public var algorithm: Algorithm = .sha1
    public var digits: Int = 6
    public var period: TimeInterval = 30

    public init(secret: Data, issuer: String? = nil, account: String? = nil,
                algorithm: Algorithm = .sha1, digits: Int = 6, period: TimeInterval = 30) {
        self.secret = secret; self.issuer = issuer; self.account = account
        self.algorithm = algorithm; self.digits = digits; self.period = period
    }

    public var label: String {
        [issuer, account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? "Authenticator entry"
    }

    public var totp: TOTP { TOTP(secret: secret, digits: digits, period: period, algorithm: algorithm) }

    /// What gets stored in the keychain: a canonical otpauth URI (keeps digits/algorithm/period).
    public var uri: String {
        var c = URLComponents()
        c.scheme = "otpauth"
        c.host = "totp"
        c.path = "/" + (account ?? "assume-keycloaker")
        c.queryItems = [
            URLQueryItem(name: "secret", value: Base32.encode(secret)),
            issuer.map { URLQueryItem(name: "issuer", value: $0) },
            URLQueryItem(name: "algorithm", value: algorithm.rawValue),
            URLQueryItem(name: "digits", value: String(digits)),
            URLQueryItem(name: "period", value: String(Int(period))),
        ].compactMap { $0 }
        return c.string ?? ""
    }

    /// Anything a person might paste or scan: a bare base32 secret, an `otpauth://totp/…` link, or a
    /// Google Authenticator `otpauth-migration://` export (which can hold several entries).
    public static func parseAll(_ input: String) -> [OTPAuth] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("otpauth-migration://") { return parseMigration(text) }
        if lower.hasPrefix("otpauth://") { return parseURI(text).map { [$0] } ?? [] }
        let compact = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard compact.count >= 16, let data = Base32.decode(compact), data.count >= 10 else { return [] }
        return [OTPAuth(secret: data)]
    }

    static func parseURI(_ text: String) -> OTPAuth? {
        guard let c = URLComponents(string: text), c.host?.lowercased() == "totp" else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let secretText = q["secret"], let secret = Base32.decode(secretText), !secret.isEmpty else { return nil }
        var label = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        var issuer = q["issuer"]
        if let colon = label.firstIndex(of: ":") {
            if issuer == nil { issuer = String(label[..<colon]) }
            label = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return OTPAuth(secret: secret, issuer: issuer, account: label.isEmpty ? nil : label,
                       algorithm: Algorithm(rawValue: (q["algorithm"] ?? "SHA1").uppercased()) ?? .sha1,
                       digits: Int(q["digits"] ?? "") ?? 6,
                       period: TimeInterval(q["period"] ?? "") ?? 30)
    }

    /// Google Authenticator "Transfer accounts" QR: base64 protobuf MigrationPayload.
    static func parseMigration(_ text: String) -> [OTPAuth] {
        guard let c = URLComponents(string: text),
              let raw = c.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = Data(base64Encoded: raw.replacingOccurrences(of: " ", with: "+"))
                ?? Base64URL.decode(raw) else { return [] }
        var out: [OTPAuth] = []
        for (field, value) in Protobuf.fields(data) where field == 1 {
            guard case .bytes(let entry) = value else { continue }
            var secret = Data(), name: String?, issuer: String?, algorithm = Algorithm.sha1, digits = 6, isTOTP = true
            for (f, v) in Protobuf.fields(entry) {
                switch (f, v) {
                case (1, .bytes(let b)): secret = b
                case (2, .bytes(let b)): name = String(data: b, encoding: .utf8)
                case (3, .bytes(let b)): issuer = String(data: b, encoding: .utf8)
                case (4, .varint(let n)): algorithm = [2: .sha256, 3: .sha512][n] ?? .sha1
                case (5, .varint(let n)): digits = n == 2 ? 8 : 6
                case (6, .varint(let n)): isTOTP = n != 1  // 1 = HOTP
                default: break
                }
            }
            guard isTOTP, !secret.isEmpty else { continue }
            var account = name
            if let n = name, let colon = n.firstIndex(of: ":") {
                if issuer == nil || issuer!.isEmpty { issuer = String(n[..<colon]) }
                account = String(n[n.index(after: colon)...])
            }
            out.append(OTPAuth(secret: secret, issuer: issuer?.nilIfEmpty, account: account?.nilIfEmpty,
                               algorithm: algorithm, digits: digits))
        }
        return out
    }
}

/// Just enough protobuf to read Google Authenticator exports.
enum Protobuf {
    enum Value { case varint(UInt64), bytes(Data) }

    static func fields(_ data: Data) -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return out }
                out.append((field, .varint(v)))
            case 2:
                guard let len = varint(), i + Int(len) <= bytes.count else { return out }
                out.append((field, .bytes(Data(bytes[i..<i + Int(len)]))))
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
