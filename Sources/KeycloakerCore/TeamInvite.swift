import CryptoKit
import Foundation

/// How a team hands out its config without publishing it: the config is encrypted (AES-256-GCM) and
/// stored at a URL; the invite carries that URL and the key. Without the invite the file is noise.
///
/// Code: `acx1.<base64url(https URL)>.<base64url(32-byte key)>`
/// Link: `assume-keycloaker://join?invite=<code>`
public struct TeamInvite: Equatable, Sendable {
    public var url: URL
    public var key: Data

    public static let prefix = "acx1."

    public init(url: URL, key: Data) {
        self.url = url
        self.key = key
    }

    public var code: String { Self.prefix + Base64URL.encode(Data(url.absoluteString.utf8)) + "." + Base64URL.encode(key) }
    public var link: String { "assume-keycloaker://join?invite=\(code)" }

    /// Accepts the code, the link, or a chat message containing either.
    public static func parse(_ text: String) -> TeamInvite? {
        guard let r = text.range(of: #"acx1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, options: .regularExpression) else {
            return nil
        }
        let parts = text[r].split(separator: ".")
        guard parts.count == 3,
              let urlData = Base64URL.decode(String(parts[1])),
              let urlString = String(data: urlData, encoding: .utf8),
              let url = URL(string: urlString), url.scheme == "https", url.host != nil,
              let key = Base64URL.decode(String(parts[2])), key.count == 32
        else { return nil }
        return TeamInvite(url: url, key: key)
    }

    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// The encrypted team config file.
public enum SealedTeamConfig {
    static let header = "assume-keycloaker team config v1\n"

    public static func seal(_ plaintext: Data, key: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: Data(header.utf8))
        guard let combined = box.combined else { throw ToolError("encryption failed") }
        return Data((header + combined.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) + "\n").utf8)
    }

    public static func open(_ blob: Data, key: Data) throws -> Data {
        let text = String(decoding: blob, as: UTF8.self)
        // Files published before the rename carry the old header (it's also the authenticated data).
        guard let header = [header, Legacy.sealedHeader].first(where: { text.hasPrefix($0) }) else {
            throw ToolError("not an Assume Keycloaker team config")
        }
        guard let combined = Data(base64Encoded: String(text.dropFirst(header.count)),
                                  options: .ignoreUnknownCharacters) else {
            throw ToolError("team config file is damaged")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(header.utf8))
        } catch {
            throw ToolError("this invite can't open the team config (it may have been replaced: ask for a new invite)")
        }
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// `AssumeKeycloaker team …`: the publisher side, used by scripts/team-config.sh.
public enum TeamCLI {
    public static func run(_ args: [String]) -> Int32 {
        func keyFrom(_ args: [String]) throws -> Data {
            guard let i = args.firstIndex(of: "--key-file"), i + 1 < args.count else { throw ToolError("--key-file is required") }
            let text = try String(contentsOfFile: args[i + 1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = Base64URL.decode(text), key.count == 32 else { throw ToolError("key file must hold a 32-byte base64url key") }
            return key
        }
        do {
            switch args.first {
            case "keygen":
                print(Base64URL.encode(TeamInvite.generateKey()))
            case "seal" where args.count >= 3:
                let plain = try Data(contentsOf: URL(filePath: args[1]))
                let config = try AppConfig.decode(plain)  // refuse to publish something the app can't read
                try SealedTeamConfig.seal(plain, key: try keyFrom(args)).write(to: URL(filePath: args[2]), options: .atomic)
                FileHandle.standardError.write(Data("sealed \(config.environments.count) environments → \(args[2])\n".utf8))
            case "open" where args.count >= 2:
                let plain = try SealedTeamConfig.open(Data(contentsOf: URL(filePath: args[1])), key: try keyFrom(args))
                FileHandle.standardOutput.write(plain)
            case "invite" where args.count >= 2:
                guard let url = URL(string: args[1]), url.scheme == "https" else { throw ToolError("URL must be https") }
                let invite = TeamInvite(url: url, key: try keyFrom(args))
                print(invite.code)
                print(invite.link)
            default:
                print("usage: AssumeKeycloaker team keygen | seal <config.json> <out.acx> --key-file <k> | open <file.acx> --key-file <k> | invite <https-url> --key-file <k>")
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
