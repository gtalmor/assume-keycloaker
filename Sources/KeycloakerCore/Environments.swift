import Foundation

/// Each person's additions on top of the team config: their own environments, and team ones they hide.
/// Kept in ~/.config/assume-keycloaker/personal.json, so team updates never touch it.
public struct PersonalConfig: Codable, Equatable, Sendable {
    public var environments: [EnvConfig]
    public var hidden: [String]

    public init(environments: [EnvConfig] = [], hidden: [String] = []) {
        self.environments = environments
        self.hidden = hidden
    }

    public static var file: URL { Paths.configDir.appending(path: "personal.json") }

    public static func load(_ url: URL = file) -> PersonalConfig {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(PersonalConfig.self, from: data) else { return PersonalConfig() }
        return p
    }

    public func save(_ url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension AppConfig {
    /// Team environments minus the hidden ones, then the personal ones (which win on an id clash).
    public func merging(_ personal: PersonalConfig) -> AppConfig {
        var out = self
        let mine = Set(personal.environments.map(\.id))
        out.environments = environments.filter { !personal.hidden.contains($0.id) && !mine.contains($0.id) }
            + personal.environments
        return out
    }
}

public enum EnvID {
    /// `My Cluster (EU)` → `my-cluster-eu`, unique among `taken`.
    public static func make(from name: String, taken: Set<String>) -> String {
        let base = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "env" : base
        var id = stem
        var n = 2
        while taken.contains(id) { id = "\(stem)-\(n)"; n += 1 }
        return id
    }
}

/// Suggestions for new environments from what's already on this Mac.
public enum Discovery {
    /// EKS contexts in the kubeconfig, with the AWS profile their exec plugin uses.
    public static func kubeContexts(runner: ProcessRunner, awsConfig: INIFile) async -> [EnvConfig] {
        guard let r = try? await runner.run("kubectl", ["config", "view", "-o", "json"], timeout: 15, quiet: true),
              r.succeeded,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        else { return [] }
        return parseKubeconfig(obj, awsConfig: awsConfig)
    }

    public static func parseKubeconfig(_ obj: [String: Any], awsConfig: INIFile) -> [EnvConfig] {
        var profiles: [String: String] = [:]
        for user in obj["users"] as? [[String: Any]] ?? [] {
            guard let name = user["name"] as? String,
                  let exec = (user["user"] as? [String: Any])?["exec"] as? [String: Any] else { continue }
            let env = exec["env"] as? [[String: Any]] ?? []
            if let p = env.first(where: { $0["name"] as? String == "AWS_PROFILE" })?["value"] as? String { profiles[name] = p }
            // `--profile x` in the args, as some setups do
            if let args = exec["args"] as? [String], let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
                profiles[name] = args[i + 1]
            }
        }
        var out: [EnvConfig] = []
        for ctx in obj["contexts"] as? [[String: Any]] ?? [] {
            guard let name = ctx["name"] as? String, let eks = Kubeconfig.parseEKS(name) else { continue }
            let user = (ctx["context"] as? [String: Any])?["user"] as? String ?? name
            let profile = profiles[user] ?? "default"
            out.append(suggestion(cluster: eks.cluster, region: eks.region, account: eks.account,
                                  profile: profile, awsConfig: awsConfig))
        }
        return out
    }

    /// SSO profiles in ~/.aws/config (the cluster is picked afterwards).
    public static func ssoProfiles(_ awsConfig: INIFile) -> [EnvConfig] {
        awsConfig.sections.keys.sorted().compactMap { section -> EnvConfig? in
            guard section.hasPrefix("profile "), let p = awsConfig.sections[section],
                  p["sso_session"] != nil || p["sso_start_url"] != nil else { return nil }
            let profile = String(section.dropFirst("profile ".count))
            return EnvConfig(id: profile, name: profile, kind: .sso, profile: profile,
                             region: p["region"] ?? p["sso_region"] ?? "us-east-1", cluster: "",
                             account: p["sso_account_id"], role: p["sso_role_name"], ssoSession: p["sso_session"])
        }
    }

    static func suggestion(cluster: String, region: String, account: String, profile: String,
                           awsConfig: INIFile) -> EnvConfig {
        let p = awsConfig.profile(profile)
        let isSSO = p?["sso_session"] != nil || p?["sso_start_url"] != nil
        return EnvConfig(id: cluster, name: cluster, kind: isSSO ? .sso : .keycloak, profile: profile,
                         region: region, cluster: cluster, account: account,
                         role: isSSO ? p?["sso_role_name"] : nil, ssoSession: isSSO ? p?["sso_session"] : nil,
                         mfa: isSSO ? nil : true)
    }

    /// `aws eks list-clusters` for a profile and region (needs a live session).
    public static func clusters(profile: String, region: String, runner: ProcessRunner) async throws -> [String] {
        let r = try await runner.run("aws", ["eks", "list-clusters", "--profile", profile, "--region", region,
                                             "--output", "json"], timeout: 45, quiet: true)
        guard r.succeeded else { throw ToolError(r.summary) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let names = obj["clusters"] as? [String] else { return [] }
        return names.sorted()
    }
}
