import Foundation

public enum EnvKind: String, Codable, Sendable {
    /// saml2aws against a Keycloak SAML IdP.
    case keycloak
    /// AWS IAM Identity Center (`aws sso login`).
    case sso
}

/// A network prerequisite an environment needs to actually work.
public enum Requirement: String, Codable, Sendable, CaseIterable {
    case vpn, zscaler
}

public struct EnvConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var kind: EnvKind
    /// AWS profile the credentials live in (e.g. `saml` for Keycloak, the SSO profile otherwise).
    public var profile: String
    public var region: String
    public var cluster: String
    /// Keycloak: required. SSO: optional, read from `sso_account_id` in ~/.aws/config.
    public var account: String?
    /// Keycloak: role name (e.g. `Developer`). SSO: permission set (`sso_role_name`).
    public var role: String?
    /// SSO: name of the entry in `ssoSessions` this profile signs in with.
    public var ssoSession: String?
    public var mfa: Bool?
    public var sessionDurationSeconds: Int?
    /// Set as `proxy-url` on the kube cluster entry after update-kubeconfig.
    public var proxyURL: String?
    public var production: Bool?
    public var note: String?
    public var requires: [Requirement]?

    public init(id: String, name: String? = nil, kind: EnvKind, profile: String, region: String, cluster: String,
                account: String? = nil, role: String? = nil, ssoSession: String? = nil, mfa: Bool? = nil,
                sessionDurationSeconds: Int? = nil, proxyURL: String? = nil, production: Bool? = nil,
                note: String? = nil, requires: [Requirement]? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.profile = profile; self.region = region
        self.cluster = cluster; self.account = account; self.role = role; self.ssoSession = ssoSession
        self.mfa = mfa; self.sessionDurationSeconds = sessionDurationSeconds; self.proxyURL = proxyURL
        self.production = production; self.note = note; self.requires = requires
    }

    public var displayName: String { name ?? id }
    public var isProduction: Bool { production ?? false }
    public var usesMFA: Bool { mfa ?? false }
    public var sessionDuration: Int { sessionDurationSeconds ?? 28800 }
    public var requirements: [Requirement] { requires ?? Requirement.allCases }

    public var roleARN: String? {
        guard let account, let role else { return nil }
        return "arn:aws:iam::\(account):role/\(role)"
    }

    public func contextName(account resolvedAccount: String?) -> String? {
        guard let acct = resolvedAccount ?? account else { return nil }
        return "arn:aws:eks:\(region):\(acct):cluster/\(cluster)"
    }
}

public struct CheckPointSettings: Codable, Hashable, Sendable {
    public var enabled: Bool?
    public var tracPath: String?
    /// Site to connect. Defaults to the site `trac info` marks as active.
    public var site: String?
    /// Short name shown instead of the (often long) site name.
    public var label: String?

    public var isEnabled: Bool { enabled ?? false }
    public var trac: String {
        tracPath ?? "/Library/Application Support/Checkpoint/Endpoint Security/Endpoint Connect/trac"
    }
}

public struct ZscalerSettings: Codable, Hashable, Sendable {
    public var enabled: Bool?
    public var checkURL: String?
    public var isEnabled: Bool { enabled ?? false }
    public var url: String { checkURL ?? "https://ip.zscaler.com" }
}

public struct SmartCardSettings: Codable, Hashable, Sendable {
    public var enabled: Bool?
    /// Only count tokens whose id starts with this (e.g. `com.vendor.`). Default: any non-Apple token.
    public var tokenPrefix: String?
    /// Run `trac connectgui` as soon as the card is inserted while the VPN is down.
    /// Off by default: you get a "click to connect" notification instead.
    public var connectVPNOnInsert: Bool?

    public var isEnabled: Bool { enabled ?? false }
    public var autoConnect: Bool { connectVPNOnInsert ?? false }
}

/// Optional integration with kube-logger (https://github.com/gtalmor/Kube-Logger).
public struct KubeLoggerSettings: Codable, Hashable, Sendable {
    public var enabled: Bool?
    public var isEnabled: Bool { enabled ?? false }
}

public struct ReachabilityTarget: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int
    /// Which prerequisite a failure of this probe counts against (usually `vpn`).
    public var countsAs: Requirement?
    public var id: String { "\(host):\(port)" }
}

public struct NetworkSettings: Codable, Hashable, Sendable {
    public var checkPoint: CheckPointSettings?
    public var zscaler: ZscalerSettings?
    public var smartCard: SmartCardSettings?
    public var reachability: [ReachabilityTarget]?
}

public struct KeycloakSettings: Codable, Hashable, Sendable {
    /// SAML IdP URL. When set, saml2aws runs from this alone (no ~/.saml2aws needed).
    public var url: String?
    /// saml2aws `--idp-provider`.
    public var provider: String?
    /// saml2aws `--mfa` type.
    public var mfa: String?
    /// Normally entered per person in Setup; only set it here for a single-user config.
    public var username: String?
    public var saml2awsPath: String?
    /// An existing keychain item holding a base32 TOTP seed (account = macOS user), if the team has a
    /// convention for one. Each person can also pick one in Setup.
    public var totpKeychainService: String?
    /// Point `region` of the Keycloak profile in ~/.aws/config at whichever env holds it
    /// (e.g. dev → eu-west-1, staging → us-east-1), so tools that take the profile's region follow.
    public var syncProfileRegion: Bool?

    public var idpProvider: String { provider ?? "KeyCloak" }
    public var mfaType: String { mfa ?? "Auto" }
    public var syncsProfileRegion: Bool { syncProfileRegion ?? true }
    public var idpHost: String? { url.flatMap { URL(string: $0)?.host } }

    /// `…/realms/<realm>/protocol/saml/…` → `<realm>`.
    public var realm: String? {
        guard let path = url.flatMap({ URL(string: $0)?.path }), let r = path.range(of: "/realms/") else { return nil }
        return path[r.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// The Keycloak account console, where people manage their authenticator.
    public var accountURL: URL? {
        guard let url, let r = url.range(of: "/realms/"), let realm else { return nil }
        return URL(string: String(url[..<r.lowerBound]) + "/realms/\(realm)/account")
    }
}

/// An `[sso-session x]` block for ~/.aws/config.
public struct SSOSessionConfig: Codable, Hashable, Sendable {
    public var name: String
    public var startURL: String
    public var region: String
    public var registrationScopes: String?
    public var scopes: String { registrationScopes ?? "sso:account:access" }
}

public struct AppConfig: Codable, Hashable, Sendable {
    /// Team / config name shown in Setup.
    public var name: String?
    public var environments: [EnvConfig]
    public var ssoSessions: [SSOSessionConfig]?
    /// Renew this many minutes before the session expires.
    public var refreshLeadMinutes: Int?
    /// Turn the light yellow when less than this is left and auto-renew is off.
    public var warnMinutes: Int?
    public var confirmProductionSwitch: Bool?
    public var keycloak: KeycloakSettings?
    public var network: NetworkSettings?
    /// Extra directories searched for aws/saml2aws/kubectl, ahead of the defaults.
    public var toolPaths: [String]?
    /// Homebrew cask the app updates itself from.
    public var updates: UpdateSettings?
    public var kubeLogger: KubeLoggerSettings?

    public var refreshLead: TimeInterval { TimeInterval((refreshLeadMinutes ?? 15) * 60) }
    public var warnWindow: TimeInterval { TimeInterval((warnMinutes ?? 30) * 60) }
    public var confirmProduction: Bool { confirmProductionSwitch ?? true }
    public var keycloakSettings: KeycloakSettings { keycloak ?? KeycloakSettings() }
    public var checkPoint: CheckPointSettings { network?.checkPoint ?? CheckPointSettings() }
    public var zscaler: ZscalerSettings { network?.zscaler ?? ZscalerSettings() }
    public var smartCard: SmartCardSettings { network?.smartCard ?? SmartCardSettings() }
    public var reachability: [ReachabilityTarget] { network?.reachability ?? [] }
    public var updateSettings: UpdateSettings { updates ?? UpdateSettings() }
    public var kubeLoggerEnabled: Bool { kubeLogger?.isEnabled ?? false }

    public func env(_ id: String?) -> EnvConfig? {
        guard let id else { return nil }
        return environments.first { $0.id == id }
    }

    public static func decode(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func ssoSession(_ name: String?) -> SSOSessionConfig? {
        guard let name else { return nil }
        return ssoSessions?.first { $0.name == name }
    }

    public static let empty = AppConfig(name: nil, environments: [], ssoSessions: nil, refreshLeadMinutes: nil,
                                        warnMinutes: nil, confirmProductionSwitch: nil, keycloak: nil,
                                        network: nil, toolPaths: nil, updates: nil, kubeLogger: nil)
}

public enum ConfigSource: Equatable, Sendable {
    /// ~/.config/assume-keycloaker/config.json (imported or hand-edited).
    case user(URL)
    /// The team config shipped inside the app.
    case bundled(URL)
    case none
}

/// Well-known file locations shared by the app and the shell integration.
public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var configDir: URL { home.appending(path: ".config/assume-keycloaker") }
    public static var configFile: URL { configDir.appending(path: "config.json") }
    /// Sourced by the zsh precmd hook so every terminal follows the active env.
    public static var shellStateFile: URL { configDir.appending(path: "current.env") }
    public static var awsCredentials: URL {
        if let p = ProcessInfo.processInfo.environment["AWS_SHARED_CREDENTIALS_FILE"] { return URL(filePath: p) }
        return home.appending(path: ".aws/credentials")
    }
    public static var awsConfig: URL {
        if let p = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"] { return URL(filePath: p) }
        return home.appending(path: ".aws/config")
    }
    public static var ssoCacheDir: URL { home.appending(path: ".aws/sso/cache") }
    public static var kubeconfig: URL {
        if let p = ProcessInfo.processInfo.environment["KUBECONFIG"]?.split(separator: ":").first {
            return URL(filePath: String(p))
        }
        return home.appending(path: ".kube/config")
    }
    public static var logDir: URL { home.appending(path: "Library/Logs/AssumeKeycloaker") }
    public static var logFile: URL { logDir.appending(path: "assume-keycloaker.log") }

    /// Team config bundled in the app (Contents/Resources/team.json).
    public static var bundledTeamConfig: URL? { Bundle.main.url(forResource: "team", withExtension: "json") }

    /// The user's own config wins; otherwise the team config shipped with the app.
    public static func loadConfig() throws -> (AppConfig, ConfigSource) {
        if FileManager.default.fileExists(atPath: configFile.path) {
            return (try AppConfig.decode(Data(contentsOf: configFile)), .user(configFile))
        }
        if let bundled = bundledTeamConfig {
            return (try AppConfig.decode(Data(contentsOf: bundled)), .bundled(bundled))
        }
        return (.empty, .none)
    }
}

/// Files of the kube-logger agent (https://github.com/gtalmor/Kube-Logger).
public enum KubeLoggerFiles {
    public static var dir: URL { Paths.home.appending(path: ".kube-logger") }
    public static var pidFile: URL { dir.appending(path: "agent.pid") }
    public static var log: URL { Paths.logDir.appending(path: "kube-logger.log") }

    /// PID of a live agent, from its pid file.
    public static func runningPID() -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 else { return nil }
        return pid
    }
}
