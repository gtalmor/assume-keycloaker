import Foundation

// MARK: Keychain

/// Keychain access through the `security` CLI. Items it creates trust `security` itself, so
/// reading them never prompts, even after the (ad-hoc signed) app is rebuilt.
public struct Keychain: Sendable {
    public static let passwordService = "Assume Keycloaker: Keycloak password"
    public static let totpService = "Assume Keycloaker: Keycloak TOTP"

    var runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public func read(service: String, account: String) async -> String? {
        guard let r = try? await runner.run("security", ["find-generic-password", "-a", account, "-s", service, "-w"],
                                            timeout: 30, quiet: true), r.succeeded
        else { return nil }
        let value = r.stdout.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    /// Presence only: the secret is not read.
    public func exists(service: String, account: String) async -> Bool {
        (try? await runner.run("security", ["find-generic-password", "-a", account, "-s", service],
                               timeout: 15, quiet: true))?.succeeded ?? false
    }

    /// saml2aws keeps the IdP password as an internet password for the IdP host.
    public func internetPasswordExists(server: String, account: String) async -> Bool {
        (try? await runner.run("security", ["find-internet-password", "-a", account, "-s", server],
                               timeout: 15, quiet: true))?.succeeded ?? false
    }

    public func store(service: String, account: String, secret: String) async throws {
        let r = try await runner.run("security", ["add-generic-password", "-U", "-a", account, "-s", service,
                                                  "-l", service, "-w", secret],
                                     timeout: 30, redact: [secret], quiet: true)
        guard r.succeeded else { throw ToolError("Could not save '\(service)' to the keychain: \(r.summary)") }
    }

    public func delete(service: String, account: String) async {
        _ = try? await runner.run("security", ["delete-generic-password", "-a", account, "-s", service],
                                  timeout: 15, quiet: true)
    }
}

// MARK: Keycloak identity

public enum PasswordSource: Equatable, Sendable {
    /// Stored by Assume Keycloaker; handed to saml2aws through SAML2AWS_PASSWORD.
    case app
    /// The internet password saml2aws saved itself (an existing saml2aws setup).
    case saml2aws
    case missing
}

public enum MFASource: Equatable, Sendable {
    /// TOTP secret stored by Assume Keycloaker: renewals run unattended.
    case appTOTP
    /// An existing keychain item with the seed (named in the config or in Setup).
    case legacyTOTP(service: String)
    /// No secret: ask for the 6-digit code when signing in.
    case prompt
}

public struct KeycloakIdentity: Equatable, Sendable {
    public var username: String?
    public var password: PasswordSource
    public var mfa: MFASource

    public var isComplete: Bool { username != nil && password != .missing }
    public var unattended: Bool { mfa != .prompt }

    /// - Parameters:
    ///   - preferPrompt: the user chose "ask me for the code" even though a secret exists.
    ///   - existingTOTPItem: a keychain item the person already keeps their seed in (Setup), if any.
    public static func resolve(settings: KeycloakSettings, storedUsername: String?, preferPrompt: Bool,
                               existingTOTPItem: String? = nil, keychain: Keychain) async -> KeycloakIdentity {
        let username = storedUsername ?? settings.username ?? Saml2awsFile.username()
        var password = PasswordSource.missing
        if let username {
            if await keychain.exists(service: Keychain.passwordService, account: username) {
                password = .app
            } else if let host = settings.idpHost ?? Saml2awsFile.idpHost(),
                      await keychain.internetPasswordExists(server: host, account: username) {
                password = .saml2aws
            }
        }
        var mfa = MFASource.prompt
        if !preferPrompt {
            if let username, await keychain.exists(service: Keychain.totpService, account: username) {
                mfa = .appTOTP
            } else if let item = existingTOTPItem ?? settings.totpKeychainService,
                      await keychain.exists(service: item, account: NSUserName()) {
                mfa = .legacyTOTP(service: item)
            }
        }
        return KeycloakIdentity(username: username, password: password, mfa: mfa)
    }
}

/// Read-only access to an existing ~/.saml2aws (so a pre-existing setup keeps working).
public enum Saml2awsFile {
    public static var url: URL { Paths.home.appending(path: ".saml2aws") }
    static func value(_ key: String) -> String? {
        let v = INIFile.load(url).sections["default"]?[key]
        return (v?.isEmpty ?? true) ? nil : v
    }
    public static func username() -> String? { value("username") }
    public static func idpHost() -> String? { value("url").flatMap { URL(string: $0)?.host } }
}

/// The base32 secret from a bare secret or an `otpauth://totp/...?secret=...` URI.
public func parseTOTPSecret(_ input: String) -> String? {
    OTPAuth.parseAll(input).first.map { Base32.encode($0.secret) }
}

// MARK: Tools

public struct ToolCheck: Identifiable, Equatable, Sendable {
    public var id: String { command }
    public var name: String
    public var command: String
    public var formula: String
    public var required: Bool
    public var purpose: String
    public var path: String?
    public var version: String?
    /// Installed but too old, or similar.
    public var problem: String?

    public var ok: Bool { path != nil && problem == nil }
}

public enum Doctor {
    struct Spec {
        var name, command, formula, purpose: String
        var required: Bool
        var versionArgs: [String]
        var minimum: [Int]?
    }

    static func specs(for config: AppConfig) -> [Spec] {
        let keycloak = config.environments.contains { $0.kind == .keycloak }
        var specs = [
            Spec(name: "AWS CLI v2", command: "aws", formula: "awscli",
                 purpose: "AWS SSO sign-in, update-kubeconfig, EKS tokens", required: true,
                 versionArgs: ["--version"], minimum: [2, 9]),
            Spec(name: "kubectl", command: "kubectl", formula: "kubernetes-cli",
                 purpose: "switching kube contexts", required: true,
                 versionArgs: ["version", "--client"], minimum: nil),
        ]
        if keycloak {
            specs.insert(Spec(name: "saml2aws", command: "saml2aws", formula: "saml2aws",
                              purpose: "Keycloak sign-in", required: true,
                              versionArgs: ["--version"], minimum: [2, 36]), at: 0)
        }
        if config.kubeLoggerEnabled {
            specs.append(Spec(name: "kube-logger agent", command: "kube-logger-agent",
                              formula: "gtalmor/kube-logger/kube-logger-agent",
                              purpose: "streaming pod logs to Kube Logger", required: false,
                              versionArgs: ["--version"], minimum: nil))
        }
        return specs
    }

    public static func tools(config: AppConfig, runner: ProcessRunner) async -> [ToolCheck] {
        var out: [ToolCheck] = []
        for spec in specs(for: config) {
            var check = ToolCheck(name: spec.name, command: spec.command, formula: spec.formula,
                                  required: spec.required, purpose: spec.purpose,
                                  path: runner.which(spec.command))
            if check.path != nil,
               let r = try? await runner.run(spec.command, spec.versionArgs, timeout: 20, quiet: true) {
                check.version = parseVersion(r.stdout + " " + r.stderr)
                if let min = spec.minimum, let v = check.version, !isAtLeast(v, min) {
                    check.problem = "version \(v) is too old (need \(min.map(String.init).joined(separator: ".")) or newer)"
                }
            }
            out.append(check)
        }
        return out
    }

    /// First `x.y[.z]` in the output: `aws-cli/2.23.10 Python/…`, `Client Version: v1.30.2`, `2.36.16`.
    public static func parseVersion(_ text: String) -> String? {
        guard let r = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    public static func isAtLeast(_ version: String, _ minimum: [Int]) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        for (i, m) in minimum.enumerated() {
            let v = i < parts.count ? parts[i] : 0
            if v != m { return v > m }
        }
        return true
    }

    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: ~/.aws/config profiles for AWS SSO

public enum ProfileStatus: Equatable, Sendable {
    case ok
    case missing
    /// Present but with different values: reported, never overwritten.
    case mismatch([String])
}

public struct ProfileCheck: Identifiable, Equatable, Sendable {
    public var id: String { section }
    public var section: String
    public var status: ProfileStatus
}

public enum AWSProfiles {
    static func expected(_ config: AppConfig) -> [(section: String, keys: [(String, String)])] {
        var out: [(String, [(String, String)])] = []
        for s in config.ssoSessions ?? [] {
            out.append(("sso-session \(s.name)", [("sso_start_url", s.startURL), ("sso_region", s.region),
                                                  ("sso_registration_scopes", s.scopes)]))
        }
        for env in config.environments where env.kind == .sso {
            guard let session = env.ssoSession, let account = env.account, let role = env.role else { continue }
            out.append(("profile \(env.profile)", [("sso_session", session), ("sso_account_id", account),
                                                   ("sso_role_name", role), ("region", env.region)]))
        }
        return out
    }

    public static func check(config: AppConfig, ini: INIFile) -> [ProfileCheck] {
        expected(config).map { section, keys in
            guard let existing = ini.sections[section] else { return ProfileCheck(section: section, status: .missing) }
            // Scopes are optional in practice; only the identifying keys must match.
            let differing = keys.filter { $0.0 != "sso_registration_scopes" && existing[$0.0] != $0.1 }.map(\.0)
            return ProfileCheck(section: section, status: differing.isEmpty ? .ok : .mismatch(differing))
        }
    }

    /// INI text for the sections that are missing entirely.
    public static func missingSections(config: AppConfig, ini: INIFile) -> String {
        expected(config)
            .filter { ini.sections[$0.section] == nil }
            .map { section, keys in "[\(section)]\n" + keys.map { "\($0.0) = \($0.1)" }.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// Appends missing sections (after a timestamped backup). Existing sections are left alone.
    @discardableResult
    public static func addMissing(config: AppConfig, file: URL = Paths.awsConfig) throws -> Int {
        let fm = FileManager.default
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let ini = INIFile.parse(existing)
        let count = expected(config).filter { ini.sections[$0.section] == nil }.count
        guard count > 0 else { return 0 }
        if fm.fileExists(atPath: file.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try fm.copyItem(at: file, to: file.appendingPathExtension("bak-\(stamp)"))
        }
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try appendText("\(sep)\n# Added by Assume Keycloaker\n\(missingSections(config: config, ini: ini))\n",
                       to: file, mode: 0o600)
        return count
    }
}

// MARK: Shell hook

public enum ShellHook {
    public static var installed: URL { Paths.configDir.appending(path: "assume-keycloaker.zsh") }
    public static var zshrc: URL { Paths.home.appending(path: ".zshrc") }
    public static let sourceLine = "source ~/.config/assume-keycloaker/assume-keycloaker.zsh"

    public static var isEnabled: Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains("assume-keycloaker.zsh")
    }

    /// Keeps ~/.config/assume-keycloaker/assume-keycloaker.zsh in step with the copy in the app bundle.
    public static func installFromBundle() {
        guard let bundled = Bundle.main.url(forResource: "assume-keycloaker", withExtension: "zsh"),
              let data = try? Data(contentsOf: bundled) else { return }
        if (try? Data(contentsOf: installed)) == data { return }
        try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        try? data.write(to: installed, options: .atomic)
    }

    /// Appends the source line to ~/.zshrc (after a backup). Optional: the app works without it.
    public static func enable() throws {
        installFromBundle()
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains("assume-keycloaker.zsh") else { return }
        // A line from before the rename: point it at the new file instead of adding a second one.
        if existing.contains(Legacy.shellHookFile) {
            let real = zshrc.resolvingSymlinksInPath()
            try? FileManager.default.removeItem(at: real.appendingPathExtension("bak-assume-keycloaker"))
            try FileManager.default.copyItem(at: real, to: real.appendingPathExtension("bak-assume-keycloaker"))
            let updated = existing.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.contains(Legacy.shellHookFile) ? Substring(sourceLine) : line
            }.joined(separator: "\n")
            try Data(updated.utf8).write(to: real, options: .atomic)
            return
        }
        if FileManager.default.fileExists(atPath: zshrc.path) {
            try? FileManager.default.removeItem(at: zshrc.appendingPathExtension("bak-assume-keycloaker"))
            try FileManager.default.copyItem(at: zshrc, to: zshrc.appendingPathExtension("bak-assume-keycloaker"))
        }
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try appendText("\(sep)\n# Assume Keycloaker: terminals follow the active environment\n\(sourceLine)\n",
                       to: zshrc, mode: 0o644)
    }
}

/// Appends in place, so symlinks (dotfile repos) and permissions (~/.aws is 600) survive.
func appendText(_ text: String, to file: URL, mode: Int) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: file.path) {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: mode]) else {
            throw ToolError("Could not create \(file.path)")
        }
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}
