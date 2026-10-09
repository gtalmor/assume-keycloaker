import Foundation

public struct UpdateSettings: Codable, Hashable, Sendable {
    /// Tap holding the cask, e.g. `gtalmor/tap`. Omit to let brew find the cask in any installed tap.
    public var tap: String?
    public var cask: String?
    public var checkHours: Double?
    /// Team default for "install updates automatically" (each person can change it).
    public var autoInstall: Bool?

    public var caskName: String { cask ?? "assume-cloaker" }
    public var token: String { tap.map { "\($0)/\(caskName)" } ?? caskName }
    public var interval: TimeInterval { (checkHours ?? 1) * 3600 }
    public var autoInstallDefault: Bool { autoInstall ?? true }
}

public enum Version {
    /// `0.10.0` > `0.9.3`; missing parts count as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func parts(_ v: String) -> [Int] {
        v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

/// Homebrew as the update channel for the app and the CLIs it drives.
public enum Brew {
    /// `/opt/homebrew` for `/opt/homebrew/bin/brew`.
    public static func prefix(_ brew: String) -> URL {
        URL(filePath: brew).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Installed cask version, read from the Caskroom (no brew call needed).
    public static func installedCaskVersion(_ cask: String, brew: String) -> String? {
        let dir = prefix(brew).appending(path: "Caskroom/\(cask)")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") } ?? []
        return versions.max { Version.isNewer($1, than: $0) }
    }

    public static var environment: [String: String] {
        ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
    }

    /// Fetches the latest formulae and taps (what `brew upgrade` would do first).
    public static func update(runner: ProcessRunner, brew: String) async -> Bool {
        (try? await runner.run(brew, ["update", "--quiet"], timeout: 600, extraEnv: environment, quiet: true))?
            .succeeded ?? false
    }

    /// Pulls just the tap that holds the cask (a quick git fetch instead of a full `brew update`).
    public static func refreshTap(of settings: UpdateSettings, runner: ProcessRunner, brew: String) async -> Bool {
        var tap = settings.tap
        if tap == nil,
           let r = try? await runner.run(brew, ["info", "--cask", "--json=v2", settings.caskName], timeout: 60,
                                         extraEnv: environment, quiet: true), r.succeeded,
           let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
           let cask = (obj["casks"] as? [[String: Any]])?.first {
            tap = cask["tap"] as? String
        }
        guard let tap,
              let repo = try? await runner.run(brew, ["--repo", tap], timeout: 30, extraEnv: environment, quiet: true),
              repo.succeeded else { return false }
        let path = repo.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return false }
        let pull = try? await runner.run("git", ["-C", path, "pull", "--ff-only", "--quiet"], timeout: 60, quiet: true)
        return pull?.succeeded ?? false
    }

    /// Latest version of the cask in its tap.
    public static func latestCaskVersion(_ token: String, runner: ProcessRunner, brew: String) async -> String? {
        guard let r = try? await runner.run(brew, ["info", "--cask", "--json=v2", token], timeout: 120,
                                            extraEnv: environment, quiet: true), r.succeeded
        else { return nil }
        return parseCaskVersion(r.stdout)
    }

    public static func parseCaskVersion(_ json: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]], let version = casks.first?["version"] as? String
        else { return nil }
        // Cask versions can carry a build suffix (`1.2.3,45`).
        return version.split(separator: ",").first.map(String.init)
    }

    /// Outdated formulae among `names` (short names), as name → newest version.
    public static func outdatedFormulae(_ names: [String], runner: ProcessRunner, brew: String) async -> [String: String] {
        guard let r = try? await runner.run(brew, ["outdated", "--formula", "--json=v2"], timeout: 120,
                                            extraEnv: environment, quiet: true), r.succeeded
        else { return [:] }
        return parseOutdated(r.stdout, names: Set(names))
    }

    public static func parseOutdated(_ json: String, names: Set<String>) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let formulae = obj["formulae"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for f in formulae {
            guard let name = f["name"] as? String, names.contains(name),
                  let current = f["current_version"] as? String else { continue }
            out[name] = current
        }
        return out
    }

    /// `gtalmor/kube-logger/kube-logger-agent` → `kube-logger-agent`.
    public static func shortName(_ formula: String) -> String {
        String(formula.split(separator: "/").last ?? Substring(formula))
    }
}
