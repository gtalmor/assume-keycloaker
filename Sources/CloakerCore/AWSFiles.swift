import CryptoKit
import Foundation

/// Minimal INI reader for ~/.aws/credentials and ~/.aws/config.
public struct INIFile: Sendable {
    public var sections: [String: [String: String]] = [:]

    public init(sections: [String: [String: String]] = [:]) { self.sections = sections }

    public static func parse(_ text: String) -> INIFile {
        var result = INIFile()
        var current: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                current = name
                if result.sections[name] == nil { result.sections[name] = [:] }
                continue
            }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result.sections[section]?[key] = value
        }
        return result
    }

    public static func load(_ url: URL) -> INIFile {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return INIFile() }
        return parse(text)
    }

    /// `[profile x]` in ~/.aws/config, `[x]` in credentials (and `[default]` in both).
    public func profile(_ name: String) -> [String: String]? {
        sections["profile \(name)"] ?? sections[name]
    }
}

public enum AWSDate {
    /// Handles `2026-10-09T00:47:31+02:00`, `2026-07-01T15:48:57Z` and the older `...UTC` suffix.
    public static func parse(_ string: String) -> Date? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("UTC") { s = String(s.dropLast(3)) + "Z" }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }
}

/// What saml2aws left in the credentials file for a profile.
public struct SAMLCredentials: Equatable, Sendable {
    public var expires: Date?
    public var principalARN: String?

    /// `arn:aws:sts::111122223333:assumed-role/Developer/first.last` → `111122223333`.
    public var account: String? {
        // The region field is empty (`sts::acct`), so keep empty components.
        guard let parts = principalARN?.split(separator: ":", omittingEmptySubsequences: false),
              parts.count >= 6 else { return nil }
        return String(parts[4])
    }

    /// `Developer` from the assumed-role ARN.
    public var role: String? {
        guard let resource = principalARN?.split(separator: ":").last else { return nil }
        let bits = resource.split(separator: "/")
        return bits.count >= 2 ? String(bits[1]) : nil
    }

    public static func read(profile: String, from ini: INIFile) -> SAMLCredentials? {
        guard let section = ini.sections[profile],
              section["aws_access_key_id"] != nil || section["x_principal_arn"] != nil
        else { return nil }
        return SAMLCredentials(
            expires: section["x_security_token_expires"].flatMap(AWSDate.parse),
            principalARN: section["x_principal_arn"]
        )
    }
}

/// The IAM Identity Center token cache entry for a profile (no secrets are kept).
public struct SSOToken: Equatable, Sendable {
    public var cacheKey: String
    public var expiresAt: Date?
    public var hasRefreshToken: Bool
    public var registrationExpiresAt: Date?

    /// Can the CLI renew the access token by itself?
    public func renewable(now: Date = Date()) -> Bool {
        guard hasRefreshToken else { return false }
        guard let reg = registrationExpiresAt else { return true }
        return reg > now
    }
}

public struct SSOProfileInfo: Equatable, Sendable {
    public var profile: String
    public var sessionName: String?
    public var startURL: String?
    public var accountID: String?
    public var roleName: String?

    /// The CLI names the cache file after sha1(sso-session name), or sha1(start URL) for legacy profiles.
    public var cacheKey: String? {
        guard let source = sessionName ?? startURL else { return nil }
        return Insecure.SHA1.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func resolve(profile: String, config: INIFile) -> SSOProfileInfo? {
        guard let p = config.profile(profile) else { return nil }
        var info = SSOProfileInfo(
            profile: profile,
            sessionName: p["sso_session"],
            startURL: p["sso_start_url"],
            accountID: p["sso_account_id"],
            roleName: p["sso_role_name"]
        )
        if let session = info.sessionName, let s = config.sections["sso-session \(session)"] {
            info.startURL = s["sso_start_url"]
        }
        return info
    }

    public func loadToken(cacheDir: URL) -> SSOToken? {
        guard let key = cacheKey else { return nil }
        let url = cacheDir.appending(path: "\(key).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SSOToken(
            cacheKey: key,
            expiresAt: (obj["expiresAt"] as? String).flatMap(AWSDate.parse),
            hasRefreshToken: (obj["refreshToken"] as? String)?.isEmpty == false,
            registrationExpiresAt: (obj["registrationExpiresAt"] as? String).flatMap(AWSDate.parse)
        )
    }
}

public enum Kubeconfig {
    /// Reads `current-context:` without a YAML dependency (kubectl always writes it top-level).
    public static func currentContext(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) where raw.hasPrefix("current-context:") {
            var value = raw.dropFirst("current-context:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    public struct EKSContext: Equatable, Sendable {
        public var region: String
        public var account: String
        public var cluster: String
    }

    /// `arn:aws:eks:us-east-1:111122223333:cluster/dev`
    public static func parseEKS(_ context: String) -> EKSContext? {
        let parts = context.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", parts[2] == "eks", parts[5].hasPrefix("cluster/") else {
            return nil
        }
        return EKSContext(region: String(parts[3]), account: String(parts[4]),
                          cluster: String(parts[5].dropFirst("cluster/".count)))
    }
}
