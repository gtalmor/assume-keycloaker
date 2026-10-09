import Foundation

/// The app was called "Assume Cloaker" before 0.2. These are its old names, used once to carry
/// people's setup over and to keep old invites and published team configs working.
public enum Legacy {
    public static let bundleID = "com.gtalmor.AssumeCloaker"
    public static let caskName = "assume-cloaker"
    public static let urlScheme = "assume-cloaker"
    public static let shellEnvVar = "CLOAKER_ENV"
    public static let shellHookFile = "assume-cloaker.zsh"
    static let sealedHeader = "assume-cloaker team config v1\n"

    public static var configDir: URL { Paths.home.appending(path: ".config/assume-cloaker") }

    /// New keychain service → the name the old app stored it under.
    public static let keychainServices: [(new: String, old: String)] = [
        (Keychain.passwordService, "Assume Cloaker: Keycloak password"),
        (Keychain.totpService, "Assume Cloaker: Keycloak TOTP"),
    ]
    public static let teamKeyService = "Assume Cloaker: team config key"

    /// Copies the old app's preferences that this app doesn't have yet. Runs once.
    public static func migrateDefaults(into defaults: UserDefaults) -> Bool {
        let flag = "migratedFromAssumeCloaker"
        guard !defaults.bool(forKey: flag) else { return false }
        defaults.set(true, forKey: flag)
        guard let old = defaults.persistentDomain(forName: bundleID), !old.isEmpty else { return false }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        return true
    }

    /// Copies the team and personal config from ~/.config/assume-cloaker when the new folder has none.
    /// The old folder is left alone (an old shell hook may still source files from it).
    public static func migrateConfigDir() -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configDir.path) else { return [] }
        try? fm.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        var copied: [String] = []
        for name in ["config.json", "personal.json"] {
            let from = configDir.appending(path: name), to = Paths.configDir.appending(path: name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            if (try? fm.copyItem(at: from, to: to)) != nil { copied.append(name) }
        }
        return copied
    }

    /// Copies keychain items stored under the old names (the new ones win if both exist).
    public static func migrateKeychain(_ keychain: Keychain, username: String?) async -> Int {
        var moved = 0
        if let username {
            for (new, old) in keychainServices where await !keychain.exists(service: new, account: username) {
                if let secret = await keychain.read(service: old, account: username) {
                    if (try? await keychain.store(service: new, account: username, secret: secret)) != nil { moved += 1 }
                }
            }
        }
        if await !keychain.exists(service: TeamKeyNames.current, account: "team"),
           let key = await keychain.read(service: teamKeyService, account: "team"),
           (try? await keychain.store(service: TeamKeyNames.current, account: "team", secret: key)) != nil {
            moved += 1
        }
        return moved
    }
}

/// Where the team invite key lives in the keychain.
public enum TeamKeyNames {
    public static let current = "Assume Keycloaker: team config key"
}
