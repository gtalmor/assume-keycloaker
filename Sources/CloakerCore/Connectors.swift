import Foundation

/// Hands out TOTP codes without ever reusing one: Keycloak rejects a code that was already
/// accepted, which bites when two MFA logins land in the same 30 s window.
public actor TOTPDispenser {
    private var lastCounter: UInt64?
    private let minRemaining: TimeInterval

    public init(minRemaining: TimeInterval = 4) { self.minRemaining = minRemaining }

    public func nextCode(for totp: TOTP) async throws -> String {
        var now = Date()
        while totp.counter(at: now) == lastCounter || totp.secondsRemaining(at: now) < minRemaining {
            try await Task.sleep(for: .seconds(totp.secondsRemaining(at: now) + 0.2))
            now = Date()
        }
        let counter = totp.counter(at: now)
        lastCounter = counter
        return totp.code(counter: counter)
    }
}

public struct Connectors: Sendable {
    public var runner: ProcessRunner
    public var config: AppConfig
    public var totp: TOTPDispenser

    public init(runner: ProcessRunner, config: AppConfig, totp: TOTPDispenser) {
        self.runner = runner
        self.config = config
        self.totp = totp
    }

    // MARK: Keycloak (saml2aws)

    /// `saml2aws login` for one role, without `eval "$(saml2aws script)"`: credentials stay
    /// in the profile so renewals reach every shell and kubectl.
    ///
    /// Everything goes to saml2aws through SAML2AWS_* variables, so no ~/.saml2aws is needed and
    /// neither the password nor the MFA code shows up in the process list.
    /// - Parameter askCode: asked for the 6-digit code when there is no TOTP secret; nil = cancelled.
    public func keycloakLogin(_ env: EnvConfig, identity: KeycloakIdentity,
                              askCode: @Sendable () async -> String?) async throws -> SAMLCredentials {
        guard let roleARN = env.roleARN else { throw ToolError("\(env.id): account and role are required") }
        let kc = config.keycloakSettings
        var vars: [String: String] = [:]
        if let url = kc.url {
            vars["SAML2AWS_URL"] = url
            vars["SAML2AWS_IDP_PROVIDER"] = kc.idpProvider
            vars["SAML2AWS_MFA"] = kc.mfaType
        } else if !FileManager.default.fileExists(atPath: Saml2awsFile.url.path) {
            throw ToolError("No Keycloak URL in the team config and no ~/.saml2aws")
        }
        guard let username = identity.username else { throw ToolError("No Keycloak username: open Setup") }
        vars["SAML2AWS_USERNAME"] = username
        switch identity.password {
        case .app:
            guard let password = await keychain.read(service: Keychain.passwordService, account: username) else {
                throw ToolError("Keycloak password missing from the keychain: open Setup")
            }
            vars["SAML2AWS_PASSWORD"] = password
            vars["SAML2AWS_DISABLE_KEYCHAIN"] = "true"
        case .saml2aws:
            break  // saml2aws finds its own keychain entry for this URL + username
        case .missing:
            throw ToolError("No Keycloak password: open Setup")
        }
        if env.usesMFA {
            vars["SAML2AWS_MFA_TOKEN"] = try await mfaCode(identity, askCode: askCode)
        }
        let args = ["login", "--force", "--session-duration=\(env.sessionDuration)",
                    "--profile", env.profile, "--skip-prompt", "--role", roleARN]
        let result = try await runner.run(kc.saml2awsPath ?? "saml2aws", args, timeout: 120, extraEnv: vars)
        logOutput(result)
        guard result.succeeded else { throw ToolError("saml2aws: \(result.summary)") }

        let creds = SAMLCredentials.read(profile: env.profile, from: INIFile.load(Paths.awsCredentials))
        guard let creds, creds.account == env.account else {
            throw ToolError("saml2aws finished but [\(env.profile)] does not hold \(env.account ?? "?") credentials")
        }
        return creds
    }

    private var keychain: Keychain { Keychain(runner: runner) }

    private func mfaCode(_ identity: KeycloakIdentity, askCode: @Sendable () async -> String?) async throws -> String {
        let seed: String?
        switch identity.mfa {
        case .appTOTP:
            seed = await keychain.read(service: Keychain.totpService, account: identity.username ?? "")
        case .legacyTOTP(let service):
            seed = await keychain.read(service: service, account: NSUserName())
        case .prompt:
            guard let code = await askCode()?.filter(\.isNumber), code.count >= 6 else {
                throw ToolError("MFA code needed")
            }
            return code
        }
        guard let seed, let totp = TOTP(base32: seed) else { throw ToolError("TOTP secret missing or invalid: open Setup") }
        return try await self.totp.nextCode(for: totp)
    }

    /// Sets `region` for a profile in ~/.aws/config (only that key is touched).
    public func setProfileRegion(_ profile: String, region: String) async throws {
        let r = try await runner.run("aws", ["configure", "set", "region", region, "--profile", profile], timeout: 30)
        guard r.succeeded else { throw ToolError("aws configure set region: \(r.summary)") }
    }

    // MARK: AWS SSO

    /// Opens the browser sign-in (`aws sso login`) and waits for it to complete. The CLI's output,
    /// including the fallback URL if the browser did not open, goes to the activity log.
    public func ssoLogin(_ env: EnvConfig) async throws {
        let result = try await runner.run("aws", ["sso", "login", "--profile", env.profile], timeout: 300)
        logOutput(result)
        guard result.succeeded else { throw ToolError("aws sso login: \(result.summary)") }
    }

    /// Exercises the profile so the CLI renews the SSO access token with its refresh token.
    /// Returns the caller ARN.
    public func ssoProbe(_ env: EnvConfig) async throws -> String {
        let result = try await runner.run("aws", ["sts", "get-caller-identity", "--profile", env.profile,
                                                  "--output", "text", "--query", "Arn"],
                                          timeout: 45, quiet: true)
        guard result.succeeded else { throw ToolError(result.summary) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Kubernetes

    public func kubeContexts() async -> Set<String> {
        guard let result = try? await runner.run("kubectl", ["config", "get-contexts", "-o", "name"],
                                                 timeout: 15, quiet: true), result.succeeded
        else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Points kubectl at `env`. Runs update-kubeconfig when the context is missing or `refresh` is set,
    /// then re-applies the proxy (update-kubeconfig drops it).
    public func useKubeContext(_ env: EnvConfig, account: String?, refresh: Bool) async throws {
        guard let context = env.contextName(account: account) else {
            throw ToolError("\(env.id): unknown AWS account, cannot name the kube context")
        }
        let exists = await kubeContexts().contains(context)
        if refresh || !exists {
            let r = try await runner.run("aws", ["eks", "update-kubeconfig", "--name", env.cluster,
                                                 "--region", env.region, "--profile", env.profile],
                                         timeout: 60)
            logOutput(r)
            guard r.succeeded else { throw ToolError("update-kubeconfig: \(r.summary)") }
        }
        if let proxy = env.proxyURL {
            let r = try await runner.run("kubectl", ["config", "set-cluster", context, "--proxy-url=\(proxy)"],
                                         timeout: 15)
            guard r.succeeded else { throw ToolError("kubectl set-cluster: \(r.summary)") }
        }
        let r = try await runner.run("kubectl", ["config", "use-context", context], timeout: 15)
        guard r.succeeded else { throw ToolError("kubectl use-context: \(r.summary)") }
    }

    // MARK: Check Point VPN

    public func checkPointStatus() async -> CheckPointStatus? {
        let trac = config.checkPoint.trac
        guard FileManager.default.isExecutableFile(atPath: trac),
              let r = try? await runner.run(trac, ["info"], timeout: 10, quiet: true), r.succeeded
        else { return nil }
        return CheckPointStatus.parse(r.stdout)
    }

    /// Asks the Check Point GUI to connect, so it can prompt for the smartcard PIN itself.
    public func checkPointConnect(site: String?) async throws {
        var args = ["connectgui"]
        if let site { args += ["-s", site] }
        let r = try await runner.run(config.checkPoint.trac, args, timeout: 20)
        logOutput(r)
        guard r.succeeded else { throw ToolError("trac connectgui: \(r.summary)") }
    }

    private func logOutput(_ r: ProcessResult) {
        for line in (r.stdout + "\n" + r.stderr).split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { runner.log("  \(l)") }
        }
    }
}

/// The file the zsh precmd hook sources so every terminal follows the active environment.
public enum ShellState {
    public static func render(env: EnvConfig) -> String {
        """
        # Written by Assume Cloaker. Sourced by the precmd hook in shell/assume-cloaker.zsh.
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION SAML2AWS_PROFILE
        export CLOAKER_ENV=\(shellQuote(env.id))
        export CLOAKER_ENV_KIND=\(env.kind.rawValue)
        export AWS_PROFILE=\(shellQuote(env.profile))
        export AWS_REGION=\(shellQuote(env.region))

        """
    }

    /// Reads back `CLOAKER_ENV` (wrapped shell functions write the same file).
    public static func envID(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("export CLOAKER_ENV=") {
            return String(line.dropFirst("export CLOAKER_ENV=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return nil
    }

    public static func write(env: EnvConfig, to url: URL = Paths.shellStateFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(render(env: env).utf8).write(to: url, options: .atomic)
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@".contains($0) } ? s : "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
