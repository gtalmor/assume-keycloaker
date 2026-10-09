import CryptoTokenKit
import Foundation
import Security

/// A PKI card as macOS exposes it: a CryptoTokenKit token whose certificates sit in the keychain.
public struct SmartCardInfo: Equatable, Sendable {
    public var tokenID: String
    public var reader: String?
    public var holder: String?
    /// Expiry of the newest certificate on the card.
    public var validUntil: Date?
}

public enum SmartCard {
    /// Physical cards only: not the Secure Enclave or Platform SSO tokens.
    public static func isCardToken(_ id: String, prefix: String?) -> Bool {
        if let prefix, !prefix.isEmpty { return id.hasPrefix(prefix) }
        return !id.hasPrefix("com.apple.")
    }

    /// Reads the card's certificates (public data: no PIN, no keychain prompt).
    public static func info(tokenID: String, watcher: TKTokenWatcher) -> SmartCardInfo {
        var card = SmartCardInfo(tokenID: tokenID, reader: watcher.tokenInfo(forTokenID: tokenID)?.slotName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrTokenID as String: tokenID,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let certs = result as? [SecCertificate] else { return card }
        let dated = certs.map { ($0, notAfter($0)) }
        if let newest = dated.max(by: { ($0.1 ?? .distantPast) < ($1.1 ?? .distantPast) }) {
            card.holder = SecCertificateCopySubjectSummary(newest.0) as String?
            card.validUntil = newest.1
        }
        return card
    }

    static func notAfter(_ cert: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}
