import AppKit
import CloakerCore
import CryptoKit
import CryptoTokenKit
import Network
import Observation
import ServiceManagement

/// Runs async operations one at a time (saml2aws logins share ~/.aws/credentials and the TOTP window).
actor SerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await op()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

@MainActor @Observable
final class ConnectionManager {
    nonisolated static let maxAutoFailures = 3
    private static let backoff: [TimeInterval] = [60, 300, 900]

    /// What the panel uses: the team config with this person's overlay applied.
    private(set) var config: AppConfig = .empty
    /// The team config as received (invite, imported file, or the maintainer's source).
    private(set) var teamConfig: AppConfig = .empty
    private(set) var personal = PersonalConfig()
    private(set) var configSource: ConfigSource = .none
    private(set) var configError: String?

    // Setup & checks
    private(set) var identity: KeycloakIdentity?
    private(set) var tools: [ToolCheck] = []
    private(set) var profileChecks: [ProfileCheck] = []
    private(set) var shellHookEnabled = false
    private(set) var installing: Set<String> = []
    private(set) var setupChecked = false
    @ObservationIgnored var openSetupWindow: (() -> Void)?
    /// Closes the menu bar panel, so dialogs don't open behind it.
    @ObservationIgnored var closePanel: (() -> Void)?

    // Updates (Homebrew)
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    private(set) var brewInstalledVersion: String?
    private(set) var latestVersion: String?
    private(set) var lastUpdateCheck: Date?
    private(set) var checkingUpdates = false
    /// formula short name → newer version available
    private(set) var outdatedTools: [String: String] = [:]
    @ObservationIgnored private var pendingAutoInstall = false

    // Kube Logger agent
    enum LogAgentState: Equatable { case stopped, starting, running(connected: Bool), failed(String) }
    private(set) var logAgent: LogAgentState = .stopped
    @ObservationIgnored private var agentProcess: Process?
    @ObservationIgnored private var agentLogOffset: UInt64 = 0
    @ObservationIgnored private var openViewerWhenConnected = false
    @ObservationIgnored private var agentStartedAt: Date?

    // Team config, from an encrypted invite
    private(set) var teamUpdatedAt: Date?
    private(set) var teamError: String?
    private(set) var joiningTeam = false
    static let teamKeyService = "Assume Cloaker: team config key"
    @ObservationIgnored private var didAutoOpenSetup = false
    @ObservationIgnored private var notifiedMFA: Set<String> = []
    private(set) var sessions: [String: EnvSession] = [:]
    private(set) var activeEnvID: String?
    private(set) var currentContext: String?
    private(set) var shellEnvID: String?
    private(set) var vpn = Check()
    private(set) var zscaler = Check()
    private(set) var probes: [String: Check] = [:]
    private(set) var checkPoint: CheckPointStatus?
    private(set) var log: [LogLine] = []
    private(set) var autoRenew = true
    /// Environments to keep connected ("like a VPN"): renewed before expiry, reconnected after sleep.
    private(set) var desired: Set<String> = []
    private(set) var vpnBusy = false
    /// The PKI ID card Check Point authenticates with.
    private(set) var card = Check()
    private(set) var cardInfo: SmartCardInfo?
    private(set) var ssoAccounts: [String: String] = [:]
    /// Snapshot mode: observe only. No logins, renewals, notifications or shell-state writes.
    @ObservationIgnored var passive = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var signatures: [String: String] = [:]
    @ObservationIgnored private var lastTick: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkUp = true
    @ObservationIgnored private var fastVPNUntil: Date?
    @ObservationIgnored private var notifiedSignIn: Set<String> = []
    @ObservationIgnored private let tokenWatcher = TKTokenWatcher()
    @ObservationIgnored private var cardTokens: [String]?
    @ObservationIgnored private var regionSyncInFlight: Set<String> = []
    @ObservationIgnored private let logWriter = LogWriter()
    @ObservationIgnored private let totp = TOTPDispenser()
    @ObservationIgnored private let loginQueue = SerialQueue()
    @ObservationIgnored let notifier = Notifier()

    // MARK: Derived

    var activeEnv: EnvConfig? { config.env(activeEnvID) }
    var keycloakEnvs: [EnvConfig] { config.environments.filter { $0.kind == .keycloak } }
    var ssoEnvs: [EnvConfig] { config.environments.filter { $0.kind == .sso } }

    func session(_ env: EnvConfig) -> EnvSession { sessions[env.id] ?? EnvSession() }

    func isKeptAlive(_ env: EnvConfig) -> Bool {
        autoRenew && desired.contains(env.id) && session(env).failures < Self.maxAutoFailures
    }

    /// Usable credentials right now (Keycloak: unexpired; SSO: unexpired or renewable token).
    func isLive(_ env: EnvConfig, now: Date = Date()) -> Bool {
        let s = session(env)
        let unexpired = (s.remaining(at: now) ?? 0) > 0
        switch env.kind {
        case .keycloak: return s.valid && unexpired
        case .sso: return s.valid || unexpired || s.autoRenewable
        }
    }

    func light(for env: EnvConfig, now: Date = Date()) -> Light {
        session(env).light(kind: env.kind, now: now, warn: config.warnWindow, renewing: isKeptAlive(env))
    }

    func account(for env: EnvConfig) -> String? {
        env.kind == .sso ? (env.account ?? ssoAccounts[env.profile]) : env.account
    }

    func requirementLight(_ r: Requirement) -> Light {
        switch r {
        case .vpn:
            let targets = config.reachability.filter { $0.countsAs == .vpn }
            if !targets.isEmpty { return targets.map { probes[$0.id]?.light ?? .gray }.max() ?? .gray }
            return config.checkPoint.isEnabled ? vpn.light : .green
        case .zscaler:
            return config.zscaler.isEnabled ? zscaler.light : .green
        }
    }

    /// The light in the menu bar, plus why it isn't green.
    func overall(now: Date = Date()) -> (light: Light, reasons: [String]) {
        guard let env = activeEnv else { return (.gray, ["No active environment"]) }
        var light = self.light(for: env, now: now)
        var reasons: [String] = []
        if light != .green { reasons.append("\(env.displayName): \(session(env).statusText(kind: env.kind, now: now))") }
        for r in env.requirements {
            let l = requirementLight(r)
            guard l == .red || l == .yellow else { continue }
            light = max(light, l)
            reasons.append(r == .vpn ? "VPN / private network not reachable (\(vpnTargetNames))" : "Zscaler: \(zscaler.title)")
        }
        return (light, reasons)
    }

    // MARK: Lifecycle

    func start() {
        autoRenew = defaults.object(forKey: "autoRenew") as? Bool ?? true
        loadSettings()
        desired = Set(defaults.stringArray(forKey: "desired") ?? [])
        appendLog("Assume Cloaker started")
        if !passive { ShellHook.installFromBundle() }
        scanFiles()
        Task { await runChecks(autoOpen: true) }
        // First update check a minute after launch, then every `checkHours`.
        lastTick["updates"] = Date().addingTimeInterval(10 - (updateInterval ?? 0))
        reportFinishedUpdate()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        notifier.onAction = { [weak self] action in
            guard let self else { return }
            if action == Notifier.connectVPNAction { self.connectVPN(); return }
            if action == Notifier.updateAction { self.installUpdate(); return }
            if let env = self.config.env(action) { self.renewNow(env) }
        }
        // Card inserted: re-check right away instead of waiting for the next poll.
        tokenWatcher.setInsertionHandler { [weak self] _ in
            Task { @MainActor in self?.lastTick["card"] = nil }
        }
        notifier.enabled = !passive
        notifier.setUp()

        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.heartbeat()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func heartbeat() {
        if due("files", every: 2) { scanFiles() }
        let vpnEvery: TimeInterval = (fastVPNUntil.map { $0 > Date() } ?? false) ? 3 : 15
        if due("card", every: 3) { checkCard() }
        if due("vpn", every: vpnEvery) { spawn("vpn") { await $0.checkVPN() } }
        if due("reach", every: 30) { spawn("reach") { await $0.checkReachability() } }
        let zEvery: TimeInterval = zscaler.light == .green ? 120 : 30
        if due("zscaler", every: zEvery) { spawn("zscaler") { await $0.checkZscaler() } }
        if due("renew", every: 10) { renewIfNeeded() }
        if let interval = updateInterval, due("updates", every: interval) { spawn("updates") { await $0.checkForUpdates() } }
        if joinedTeam, due("team", every: 3600) { spawn("team") { await $0.refreshTeamConfig() } }
        if due("clock", every: 30) { clock = Date() }
        if due("sections", every: 2) { autoCollapseNetwork() }
        if pendingAutoInstall, isIdle { pendingAutoInstall = false; installUpdate() }
        if config.kubeLoggerEnabled, due("logs", every: 2) { checkLogAgent() }
    }

    private func due(_ key: String, every interval: TimeInterval) -> Bool {
        let now = Date()
        if let last = lastTick[key], now.timeIntervalSince(last) < interval { return false }
        lastTick[key] = now
        return true
    }

    private func spawn(_ key: String, _ op: @escaping @MainActor (ConnectionManager) async -> Void) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            await op(self)
            inFlight.remove(key)
        }
    }

    /// Re-run every network check on the next heartbeat.
    /// Runs every check now and returns when they're done (the refresh button waits on it).
    func recheckAll() async {
        scanFiles()
        checkCard()
        async let vpnCheck: Void = checkVPN()
        async let reach: Void = checkReachability()
        async let zs: Void = checkZscaler()
        _ = await (vpnCheck, reach, zs)
        for key in ["files", "card", "vpn", "reach", "zscaler"] { lastTick[key] = Date() }
        renewIfNeeded()
    }

    /// Runs an alert in front of everything: the app may not be active (the menu bar panel doesn't
    /// activate it), and a plain runModal could open behind other apps' windows.
    private func presentModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        closePanel?()
        NSApp.activate()
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
        return alert.runModal()
    }

    // MARK: Feedback

    /// A short message at the bottom of the panel, for actions whose result isn't otherwise visible.
    private(set) var toast: (text: String, ok: Bool)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func flash(_ text: String, ok: Bool = true) {
        toast = (text, ok)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func recheckNow() {
        for key in ["card", "vpn", "reach", "zscaler", "renew", "files"] { lastTick[key] = nil }
    }

    private func networkChanged(up: Bool) {
        let wasUp = networkUp
        networkUp = up
        if up != wasUp { appendLog(up ? "Network is back" : "Network is down") }
        if up && !wasUp { networkRecovered() }
        recheckNow()
    }

    private func didWake() {
        appendLog("Woke from sleep")
        for id in sessions.keys { sessions[id]?.nextAttempt = nil }
        recheckNow()
    }

    /// VPN/network came back: give paused environments a fresh set of attempts.
    private func networkRecovered() {
        for id in sessions.keys where (sessions[id]?.failures ?? 0) > 0 {
            sessions[id]?.failures = 0
            sessions[id]?.nextAttempt = nil
        }
    }

    // MARK: Files (this is how terminal logins are noticed)

    private func signature(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(date)/\(attrs?[.size] as? Int ?? -1)"
    }

    private func ssoCacheSignature() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.ssoCacheDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.map(signature).joined(separator: ",")
    }

    private func changed(_ key: String, _ sig: String) -> Bool {
        defer { signatures[key] = sig }
        return signatures[key] != sig
    }

    private func scanFiles() {
        let teamFile = changed("config", signature(Paths.configFile))
        let personalFile = changed("personal", signature(PersonalConfig.file))
        let sourceFile = changed("source", teamSourceURL.map(signature) ?? "")
        if teamFile || personalFile || sourceFile { loadConfig() }
        let awsCfg = changed("awsconfig", signature(Paths.awsConfig))
        if changed("creds", signature(Paths.awsCredentials)) { reloadKeycloak() }
        if changed("sso", ssoCacheSignature()) || awsCfg { reloadSSO() }
        if awsCfg, setupChecked { profileChecks = AWSProfiles.check(config: config, ini: INIFile.load(Paths.awsConfig)) }
        // Read the shell state before kubeconfig, so a terminal login isn't re-published.
        if changed("shell", signature(Paths.shellStateFile)) {
            let raw = (try? String(contentsOf: Paths.shellStateFile, encoding: .utf8)).flatMap(ShellState.envID)
            // The shell wrappers publish the cluster name; map it back to the env id.
            shellEnvID = raw.map { id in config.env(id)?.id ?? config.environments.first { $0.cluster == id }?.id ?? id }
        }
        if changed("kube", signature(Paths.kubeconfig)) || awsCfg { reloadKube() }
    }

    private func loadConfig() {
        do {
            if let source = teamSourceURL, FileManager.default.fileExists(atPath: source.path) {
                // Maintainer: work from the source file itself, published or not.
                teamConfig = try AppConfig.decode(Data(contentsOf: source))
                configSource = .user(source)
            } else {
                (teamConfig, configSource) = try Paths.loadConfig()
            }
            personal = PersonalConfig.load()
            config = teamConfig.merging(personal)
            configError = nil
            if setupChecked { Task { await runChecks() } }
        } catch {
            configError = "config.json: \(error.localizedDescription)"
            appendLog(configError!, error: true)
        }
        signatures["creds"] = nil
        signatures["sso"] = nil
        signatures["kube"] = nil
    }

    private func reloadKeycloak() {
        let ini = INIFile.load(Paths.awsCredentials)
        for env in keycloakEnvs {
            let creds = SAMLCredentials.read(profile: env.profile, from: ini)
            let mine = creds?.account == env.account && creds?.expires != nil
            var s = session(env)
            s.valid = mine
            s.expiresAt = mine ? creds?.expires : nil
            s.identity = mine ? creds?.principalARN : nil
            sessions[env.id] = s
        }
        // Adopt a login done elsewhere (e.g. saml2aws in a terminal) so it is kept alive too.
        var seen = defaults.dictionary(forKey: "lastSeenExpiry") as? [String: Double] ?? [:]
        for profile in Set(keycloakEnvs.map(\.profile)) {
            guard let creds = SAMLCredentials.read(profile: profile, from: ini), let exp = creds.expires else { continue }
            let stamp = exp.timeIntervalSince1970
            defer { seen[profile] = stamp }
            guard exp > Date(), seen[profile] != stamp,
                  let env = keycloakEnvs.first(where: { $0.profile == profile && $0.account == creds.account })
            else { continue }
            if !desired.contains(env.id) { appendLog("Noticed a new \(env.displayName) session (until \(Fmt.clock(exp)))") }
            adopt(env)
        }
        if !passive { defaults.set(seen, forKey: "lastSeenExpiry") }
        // Whoever holds a shared profile now (app or a terminal login) decides its region.
        for profile in Set(keycloakEnvs.map(\.profile)) {
            if let holder = keycloakEnvs.first(where: { $0.profile == profile && isLive($0) }) {
                syncProfileRegion(holder)
            }
        }
    }

    private func syncProfileRegion(_ env: EnvConfig) {
        guard env.kind == .keycloak, config.keycloakSettings.syncsProfileRegion, !passive,
              !regionSyncInFlight.contains(env.profile),
              INIFile.load(Paths.awsConfig).profile(env.profile)?["region"] != env.region
        else { return }
        regionSyncInFlight.insert(env.profile)
        Task {
            defer { regionSyncInFlight.remove(env.profile) }
            do {
                try await connectors.setProfileRegion(env.profile, region: env.region)
                appendLog("[profile \(env.profile)] region → \(env.region) (\(env.displayName))")
            } catch {
                appendLog(error.localizedDescription, error: true)
            }
        }
    }

    private func reloadSSO() {
        let awsCfg = INIFile.load(Paths.awsConfig)
        for env in ssoEnvs {
            var s = session(env)
            guard let info = SSOProfileInfo.resolve(profile: env.profile, config: awsCfg) else {
                s.error = "profile \(env.profile) not found in ~/.aws/config"
                sessions[env.id] = s
                continue
            }
            ssoAccounts[env.profile] = info.accountID
            let token = info.loadToken(cacheDir: Paths.ssoCacheDir)
            let previous = s.expiresAt
            s.expiresAt = token?.expiresAt
            s.autoRenewable = token?.renewable() ?? false
            if let exp = token?.expiresAt, exp > Date(), exp != previous {
                // A sign-in or renewal happened (possibly `aws sso login` in a terminal).
                s.needsSignIn = false
                s.lastProbe = nil
                if let key = info.cacheKey { notifiedSignIn.remove(key) }
            }
            sessions[env.id] = s
        }
    }

    private func reloadKube() {
        let text = (try? String(contentsOf: Paths.kubeconfig, encoding: .utf8)) ?? ""
        let context = Kubeconfig.currentContext(in: text)
        currentContext = context
        let env = envForContext(context)
        guard env?.id != activeEnvID else { return }
        activeEnvID = env?.id
        guard let env else {
            if let context { appendLog("kubectl context is \(context) (not a configured environment)") }
            return
        }
        appendLog("Active environment: \(env.displayName)")
        // Keep it alive only if it is live right now: never start a login on our own just
        // because kubectl points at an env whose old credentials have lapsed.
        if isLive(env) { adopt(env) }
        publishShellState(env)
    }

    func envForContext(_ context: String?) -> EnvConfig? {
        guard let context else { return nil }
        guard let eks = Kubeconfig.parseEKS(context) else { return nil }
        return config.environments.first { env in
            env.cluster == eks.cluster && env.region == eks.region && (account(for: env).map { $0 == eks.account } ?? true)
        }
    }

    /// Keep `env` alive from now on. Envs sharing its profile can't be live at the same time.
    private func adopt(_ env: EnvConfig) {
        var next = desired
        if env.kind == .keycloak {
            for other in keycloakEnvs where other.id != env.id && other.profile == env.profile { next.remove(other.id) }
        }
        next.insert(env.id)
        setDesired(next)
    }

    private func setDesired(_ set: Set<String>) {
        guard set != desired, !passive else { return }
        desired = set
        defaults.set(Array(set).sorted(), forKey: "desired")
    }

    private func publishShellState(_ env: EnvConfig) {
        guard shellEnvID != env.id, !passive else { return }
        do {
            try ShellState.write(env: env)
            shellEnvID = env.id
            appendLog("Shells → AWS_PROFILE=\(env.profile) AWS_REGION=\(env.region)")
        } catch {
            appendLog("Could not write \(Paths.shellStateFile.path): \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Network checks

    private func checkVPN() async {
        guard config.checkPoint.isEnabled else {
            vpn = Check(light: .gray, title: "Not monitored")
            return
        }
        let status = await connectors.checkPointStatus()
        checkPoint = status
        let previous = vpn
        let wasConnected = previous.title == "Connected"
        if let status {
            if let site = status.connectedSite {
                vpn = Check(light: .green, title: "Connected", detail: siteLabel(site.name))
                fastVPNUntil = nil
                if !wasConnected { networkRecovered() }
            } else if let site = status.connectingSite {
                vpn = Check(light: .yellow, title: "Connecting…", detail: siteLabel(site.name))
            } else {
                let site = status.activeSite.map { siteLabel($0.name) }
                if wasConnected {
                    notifier.post(title: "VPN disconnected",
                                  body: "Check Point dropped the connection, so private endpoints will fail. Click to reconnect.",
                                  action: Notifier.connectVPNAction)
                }
                // Only call the VPN unnecessary when it never was up here and the proxy answers anyway
                // (e.g. office network). Right after a drop the last probe is stale.
                if !wasConnected, vpnProbesReachable {
                    vpn = Check(light: .gray, title: "Disconnected", detail: "not needed: \(vpnTargetNames) reachable")
                } else {
                    vpn = Check(light: .red, title: "Disconnected", detail: needsCard ? "insert your ID card" : site)
                }
            }
        } else {
            vpn = Check(light: .gray, title: "Check Point not found")
        }
        if vpn.title != previous.title {
            lastTick["reach"] = nil  // re-probe the proxy now that the tunnel changed
            appendLog("Check Point VPN: \(vpn.title)\(vpn.detail.map { " (\($0))" } ?? "")",
                      error: wasConnected && vpn.light == .red)
        }
    }

    private var vpnProbesReachable: Bool {
        let targets = config.reachability.filter { $0.countsAs == .vpn }
        return !targets.isEmpty && targets.allSatisfy { probes[$0.id]?.light == .green }
    }

    /// What to call the Check Point site: the config's label, else the site name.
    private func siteLabel(_ name: String) -> String { config.checkPoint.label ?? name }

    private var vpnTargetNames: String {
        let names = config.reachability.filter { $0.countsAs == .vpn }.map(\.name)
        return names.isEmpty ? "private network" : names.joined(separator: ", ")
    }

    private func checkCard() {
        guard config.smartCard.isEnabled else {
            card = Check(light: .gray, title: "Not monitored")
            cardInfo = nil
            return
        }
        let prefix = config.smartCard.tokenPrefix
        let tokens = tokenWatcher.tokenIDs.filter { SmartCard.isCardToken($0, prefix: prefix) }.sorted()
        let first = cardTokens == nil
        if tokens != cardTokens {
            cardTokens = tokens
            let wasPresent = cardInfo != nil
            cardInfo = tokens.first.map { SmartCard.info(tokenID: $0, watcher: tokenWatcher) }
            if first {
                appendLog(cardInfo.map { "ID card: inserted (\($0.holder ?? "card"))" } ?? "ID card: not inserted")
            } else {
                cardChanged(wasPresent: wasPresent)
            }
        }
        let vpnUp = checkPoint?.isConnected ?? false
        guard let info = cardInfo else {
            card = vpnUp
                ? Check(light: .gray, title: "Not inserted", detail: "not needed while the VPN is up")
                : Check(light: .yellow, title: "Not inserted", detail: "needed to connect the VPN")
            return
        }
        let holder = info.holder ?? "card"
        if let until = info.validUntil {
            if until < Date() {
                card = Check(light: .red, title: "Certificate expired", detail: "\(holder) · \(until.formatted(date: .abbreviated, time: .omitted))")
            } else if until.timeIntervalSinceNow < 30 * 86400 {
                card = Check(light: .yellow, title: "Expires soon", detail: "\(holder) · \(until.formatted(date: .abbreviated, time: .omitted))")
            } else {
                card = Check(light: .green, title: "Inserted", detail: "\(holder) · valid to \(until.formatted(.dateTime.month(.abbreviated).year()))")
            }
        } else {
            card = Check(light: .green, title: "Inserted", detail: info.reader ?? holder)
        }
    }

    private func cardChanged(wasPresent: Bool) {
        let present = cardInfo != nil
        guard present != wasPresent else { return }
        appendLog(present ? "ID card inserted (\(cardInfo?.holder ?? "card"))" : "ID card removed")
        lastTick["vpn"] = nil
        guard present, config.checkPoint.isEnabled, !(checkPoint?.isConnected ?? false), !vpnProbesReachable else { return }
        if config.smartCard.autoConnect {
            connectVPN()
        } else {
            notifier.post(title: "ID card inserted", body: "The VPN is down. Click to connect Check Point.",
                          action: Notifier.connectVPNAction)
        }
    }

    private func checkReachability() async {
        let targets = config.reachability
        let results = await withTaskGroup(of: (ReachabilityTarget, TimeInterval?).self) { group in
            for t in targets { group.addTask { (t, await Probes.tcp(host: t.host, port: t.port)) } }
            var out: [(ReachabilityTarget, TimeInterval?)] = []
            for await r in group { out.append(r) }
            return out
        }
        var recovered = false
        for (t, latency) in results {
            let was = probes[t.id]?.light
            if let latency {
                probes[t.id] = Check(light: .green, title: "Reachable", detail: "\(Int(latency * 1000)) ms")
                if was == .red, t.countsAs != nil { recovered = true }
                if was != .green { appendLog("\(t.name): reachable (\(Int(latency * 1000)) ms)") }
            } else {
                probes[t.id] = Check(light: .red, title: "Unreachable", detail: "\(t.host):\(t.port)")
                if was != .red { appendLog("\(t.name): unreachable (\(t.host):\(t.port))", error: was == .green) }
            }
        }
        if recovered { networkRecovered() }
    }

    private func checkZscaler() async {
        guard config.zscaler.isEnabled else {
            zscaler = Check(light: .gray, title: "Not monitored")
            return
        }
        let running = await isZscalerRunning()
        var result = ZscalerRouting.unknown
        if let url = URL(string: config.zscaler.url) { result = await Probes.zscaler(url: url) }
        let was = zscaler.light
        switch (running, result) {
        case (_, .routed(let cloud)):
            zscaler = Check(light: .green, title: "Protected", detail: cloud)
        case (false, _):
            zscaler = Check(light: .red, title: "Not running", detail: "Zscaler Client Connector is not running")
        case (true, .notRouted):
            zscaler = Check(light: .red, title: "Not routing", detail: "running, but traffic bypasses Zscaler")
        case (true, .unknown):
            zscaler = Check(light: .yellow, title: "Unknown", detail: "check page did not answer")
        }
        if zscaler.light != was {
            appendLog("Zscaler: \(zscaler.title)\(zscaler.detail.map { " (\($0))" } ?? "")",
                      error: was == .green && zscaler.light == .red)
        }
        if was == .green, zscaler.light == .red {
            notifier.post(title: "Zscaler is off", body: zscaler.detail ?? zscaler.title)
        } else if was == .red, zscaler.light == .green {
            networkRecovered()
        }
    }

    private func isZscalerRunning() async -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier?.lowercased() == "com.zscaler.zscaler" }) {
            return true
        }
        let r = try? await runner.run("/usr/bin/pgrep", ["-x", "ZscalerTunnel"], timeout: 5, quiet: true)
        return r?.succeeded ?? false
    }

    // MARK: Keep-alive

    private func renewIfNeeded() {
        guard autoRenew, networkUp, !passive else { return }
        let now = Date()
        for env in config.environments where desired.contains(env.id) && !inFlight.contains(env.id) {
            let s = session(env)
            guard s.operation == nil, s.failures < Self.maxAutoFailures else { continue }
            if let next = s.nextAttempt, next > now { continue }
            switch env.kind {
            case .keycloak:
                if s.valid, let left = s.remaining(at: now), left > config.refreshLead { continue }
                // Another kept-alive env currently owns this shared profile: leave it alone.
                let owned = keycloakEnvs.contains {
                    $0.id != env.id && $0.profile == env.profile && desired.contains($0.id) && session($0).valid
                }
                if owned { continue }
                if env.usesMFA, identity?.unattended == false {
                    // No TOTP secret: renewing needs the person's code, so ask with a notification.
                    if !notifiedMFA.contains(env.id) {
                        notifiedMFA.insert(env.id)
                        notifier.post(title: "\(env.displayName): MFA code needed",
                                      body: s.valid ? "The session expires soon. Click to renew." : "The session expired. Click to reconnect.",
                                      action: env.id)
                    }
                    continue
                }
                Task { await renewKeycloak(env, reconnect: !s.valid || (s.remaining(at: now) ?? 0) <= 0) }
            case .sso:
                if s.needsSignIn { continue }
                let age = s.lastProbe.map { now.timeIntervalSince($0) } ?? .infinity
                let nearExpiry = s.remaining(at: now).map { $0 < config.refreshLead } ?? false
                guard age > 300 || (nearExpiry && age > 60) else { continue }
                Task { await probeSSO(env, interactive: false) }
            }
        }
    }

    private func renewKeycloak(_ env: EnvConfig, reconnect: Bool) async {
        guard !inFlight.contains(env.id) else { return }
        inFlight.insert(env.id)
        defer { inFlight.remove(env.id) }
        update(env) { $0.operation = reconnect ? "Reconnecting…" : "Renewing…" }
        appendLog("\(reconnect ? "Reconnecting" : "Renewing") \(env.displayName)…")
        do {
            let creds = try await keycloakLogin(env)
            succeed(env, creds: creds)
        } catch {
            fail(env, error, notify: true)
        }
    }

    private func probeSSO(_ env: EnvConfig, interactive: Bool) async {
        guard !inFlight.contains(env.id) else { return }
        inFlight.insert(env.id)
        defer { inFlight.remove(env.id) }
        do {
            let arn = try await connectors.ssoProbe(env)
            update(env) { s in
                s.valid = true; s.identity = arn; s.error = nil; s.failures = 0
                s.nextAttempt = nil; s.needsSignIn = false; s.lastProbe = Date()
            }
        } catch {
            let message = error.localizedDescription
            let expired = Self.looksLikeSSOExpiry(message)
            update(env) { s in
                s.valid = false; s.lastProbe = Date(); s.error = message
                s.needsSignIn = expired
                if !expired {
                    s.failures += 1
                    s.nextAttempt = Date().addingTimeInterval(Self.backoff[min(s.failures, Self.backoff.count) - 1])
                }
            }
            appendLog("\(env.displayName): \(message)", error: true)
            if expired, !interactive { notifySignIn(env) }
        }
    }

    static func looksLikeSSOExpiry(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["token has expired", "refresh failed", "error loading sso token", "sso session", "expired", "unauthorized"]
            .contains { m.contains($0) }
    }

    private func notifySignIn(_ env: EnvConfig) {
        let key = SSOProfileInfo.resolve(profile: env.profile, config: INIFile.load(Paths.awsConfig))?.cacheKey ?? env.id
        guard !notifiedSignIn.contains(key) else { return }
        notifiedSignIn.insert(key)
        notifier.post(title: "AWS SSO sign-in needed",
                      body: "The AWS SSO session ended. Click to sign in again (opens your browser).",
                      action: env.id)
    }

    private func keycloakLogin(_ env: EnvConfig) async throws -> SAMLCredentials {
        if identity == nil { await refreshIdentity() }
        guard let identity, identity.isComplete else {
            openSetupWindow?()
            throw ToolError("Keycloak account not set up: finish Setup")
        }
        let c = connectors
        let ask: @Sendable () async -> String? = { [weak self] in await self?.askMFACode(for: env) }
        return try await loginQueue.run { try await c.keycloakLogin(env, identity: identity, askCode: ask) }
    }

    /// Used when there is no TOTP secret ("ask me for the code").
    private func askMFACode(for env: EnvConfig) async -> String? {
        closePanel?()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Keycloak MFA code"
        alert.informativeText = "Enter the 6-digit code from your authenticator to sign in to \(env.displayName)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "123456"
        if let clip = NSPasteboard.general.string(forType: .string)?.filter(\.isNumber), (6...8).contains(clip.count) {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return presentModal(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func succeed(_ env: EnvConfig, creds: SAMLCredentials) {
        update(env) { s in
            s.operation = nil; s.error = nil; s.failures = 0; s.nextAttempt = nil
            s.valid = true; s.expiresAt = creds.expires; s.identity = creds.principalARN
        }
        appendLog("✓ \(env.displayName) session until \(creds.expires.map(Fmt.clock) ?? "?")")
        notifiedMFA.remove(env.id)
        adopt(env)
    }

    private func fail(_ env: EnvConfig, _ error: Error, notify: Bool) {
        let message = error.localizedDescription
        var failures = 0
        update(env) { s in
            s.operation = nil
            s.error = message
            s.failures += 1
            failures = s.failures
            s.nextAttempt = Date().addingTimeInterval(Self.backoff[min(s.failures, Self.backoff.count) - 1])
        }
        appendLog("✗ \(env.displayName): \(message)", error: true)
        guard notify else { return }
        var hint = ""
        if env.requirements.contains(.vpn), requirementLight(.vpn) == .red { hint = " (VPN looks down)" }
        if env.requirements.contains(.zscaler), requirementLight(.zscaler) == .red { hint = " (Zscaler looks off)" }
        if failures == 1 {
            notifier.post(title: "\(env.displayName): renewal failed\(hint)", body: message, action: env.id)
        } else if failures == Self.maxAutoFailures {
            notifier.post(title: "\(env.displayName): auto-renew paused",
                          body: "\(failures) failures in a row. It resumes when the network/VPN changes, or click to retry.",
                          action: env.id)
        }
    }

    private func update(_ env: EnvConfig, _ change: (inout EnvSession) -> Void) {
        var s = session(env)
        change(&s)
        sessions[env.id] = s
    }

    // MARK: User actions

    /// Connect if needed and make `env` the active environment (kubectl context + shells).
    func use(_ env: EnvConfig) {
        Task { _ = await useAndWait(env) }
    }

    /// `use`, for buttons that show progress: true once `env` is connected and active.
    func useAndWait(_ env: EnvConfig) async -> Bool {
        if env.isProduction, config.confirmProduction, activeEnvID != env.id {
            guard confirm(title: "Switch to \(env.displayName)? (production)",
                          text: "kubectl and every terminal following Assume Cloaker will point at the production cluster \(env.cluster).")
            else { return false }
        }
        await switchTo(env)
        return session(env).error == nil && activeEnvID == env.id && isLive(env)
    }

    private func switchTo(_ env: EnvConfig) async {
        guard !inFlight.contains(env.id) else { return }
        inFlight.insert(env.id)
        defer { inFlight.remove(env.id) }
        var signedIn = false
        do {
            switch env.kind {
            case .keycloak:
                let s = session(env)
                if !(s.valid && (s.remaining(at: Date()) ?? 0) > config.refreshLead) {
                    update(env) { $0.operation = "Signing in…"; $0.failures = 0 }
                    appendLog("Signing in to \(env.displayName)…")
                    let creds = try await keycloakLogin(env)
                    succeed(env, creds: creds)
                    signedIn = true
                }
            case .sso:
                update(env) { $0.operation = "Checking session…" }
                do {
                    let arn = try await connectors.ssoProbe(env)
                    update(env) { $0.valid = true; $0.identity = arn }
                } catch {
                    update(env) { $0.operation = "Finish sign-in in your browser…" }
                    appendLog("Opening AWS SSO sign-in for \(env.displayName)…")
                    try await connectors.ssoLogin(env)
                    let arn = try await connectors.ssoProbe(env)
                    update(env) { $0.valid = true; $0.identity = arn }
                    signedIn = true
                }
                update(env) { s in s.error = nil; s.failures = 0; s.needsSignIn = false; s.lastProbe = Date() }
            }
            update(env) { $0.operation = "Switching kubectl…" }
            try await connectors.useKubeContext(env, account: account(for: env), refresh: signedIn)
            update(env) { $0.operation = nil }
            adopt(env)
            activeEnvID = env.id
            currentContext = env.contextName(account: account(for: env))
            publishShellState(env)
            appendLog("✓ Using \(env.displayName)")
        } catch {
            fail(env, error, notify: false)
        }
    }

    func renewNow(_ env: EnvConfig) {
        Task {
            let ok = await renewAndWait(env)
            flash(ok ? "\(env.displayName) renewed" : "\(env.displayName): renewal failed", ok: ok)
        }
    }

    /// A fresh session for `env` now; true when it worked (for buttons that show the outcome).
    func renewAndWait(_ env: EnvConfig) async -> Bool {
        update(env) { $0.failures = 0; $0.nextAttempt = nil; $0.error = nil }
        switch env.kind {
        case .keycloak:
            await renewKeycloak(env, reconnect: !session(env).valid)
        case .sso:
            await probeSSO(env, interactive: true)
            if session(env).needsSignIn { await signIn(env) }
        }
        let s = session(env)
        return s.error == nil && (env.kind == .sso ? s.valid : isLive(env))
    }

    func signIn(_ env: EnvConfig) async {
        guard !inFlight.contains(env.id) else { return }
        inFlight.insert(env.id)
        defer { inFlight.remove(env.id) }
        update(env) { $0.operation = "Finish sign-in in your browser…" }
        do {
            try await connectors.ssoLogin(env)
            let arn = try await connectors.ssoProbe(env)
            update(env) { s in
                s.operation = nil; s.valid = true; s.identity = arn; s.error = nil
                s.needsSignIn = false; s.failures = 0; s.lastProbe = Date()
            }
            adopt(env)
            appendLog("✓ AWS SSO signed in (\(env.displayName))")
        } catch {
            fail(env, error, notify: false)
        }
    }

    func stopKeepingAlive(_ env: EnvConfig) {
        var next = desired
        next.remove(env.id)
        setDesired(next)
        appendLog("\(env.displayName): stopped keeping alive")
        flash("\(env.displayName) won't be renewed automatically")
    }

    func keepAlive(_ env: EnvConfig) {
        update(env) { $0.failures = 0; $0.nextAttempt = nil }
        adopt(env)
        appendLog("\(env.displayName): keeping alive")
        flash("\(env.displayName) will be kept alive")
    }

    func setAutoRenew(_ on: Bool) {
        autoRenew = on
        defaults.set(on, forKey: "autoRenew")
        appendLog(on ? "Auto-renew on" : "Auto-renew off")
        if on { networkRecovered() }
    }

    /// Smart card monitoring is on and no card is inserted: Check Point can't authenticate.
    var needsCard: Bool { config.smartCard.isEnabled && cardInfo == nil }

    func connectVPN() {
        guard !vpnBusy else { return }
        if needsCard {
            appendLog("Insert your ID card first: the VPN authenticates with its certificate", error: true)
            return
        }
        vpnBusy = true
        fastVPNUntil = Date().addingTimeInterval(120)
        Task {
            defer { vpnBusy = false; recheckNow() }
            let site = config.checkPoint.site ?? checkPoint?.activeSite?.name
            appendLog("Asking Check Point to connect\(site.map { " to \(siteLabel($0))" } ?? "")…")
            do {
                try await connectors.checkPointConnect(site: site)
            } catch {
                appendLog(error.localizedDescription, error: true)
                openCheckPointApp()
            }
        }
    }

    func openCheckPointApp() {
        let app = URL(filePath: config.checkPoint.trac).deletingLastPathComponent()
            .appending(path: "Endpoint Security VPN.app")
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    func openZscalerApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.zscaler.zscaler") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func copyExports(_ env: EnvConfig) {
        let text = "export AWS_PROFILE=\(env.profile) AWS_REGION=\(env.region)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("Copied: \(text)")
        flash("Copied: \(text)")
    }


    func openLog() {
        logWriter.flush()
        NSWorkspace.shared.open(Paths.logFile)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            appendLog("Launch at login: \(error.localizedDescription)", error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        expandedSections = Set(defaults.stringArray(forKey: "expandedSections") ?? [])
        updateHours = defaults.object(forKey: "updateHours") as? Double ?? config.updateSettings.checkHours ?? 1
    }

    private func confirm(title: String, text: String) -> Bool {
        closePanel?()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return presentModal(alert) == .alertFirstButtonReturn
    }

    // MARK: Setup & checks

    /// What still blocks a working setup (empty = all good). Optional items are not listed.
    var setupProblems: [String] {
        guard setupChecked else { return [] }
        var problems: [String] = []
        if config.environments.isEmpty { problems.append("Not set up yet: paste the team invite you received") }
        for t in tools where t.required && !t.ok {
            problems.append(t.path == nil ? "\(t.name) is not installed" : "\(t.name): \(t.problem ?? "problem")")
        }
        if !keycloakEnvs.isEmpty, let id = identity {
            if id.username == nil { problems.append("Keycloak username not set") }
            else if id.password == .missing { problems.append("Keycloak password not saved") }
            else if id.mfa == .prompt, mfaMode == .automatic, keycloakEnvs.contains(where: \.usesMFA) {
                problems.append("No authenticator secret yet: load it in Settings → Account & MFA, or choose Ask me")
            }
        }
        let missing = profileChecks.filter { $0.status == .missing }.count
        if missing > 0 { problems.append("\(missing) AWS SSO profile\(missing == 1 ? "" : "s") missing in ~/.aws/config") }
        return problems
    }

    func runChecks(autoOpen: Bool = false) async {
        tools = await Doctor.tools(config: config, runner: runner)
        if let brew = Doctor.brewPath {
            brewInstalledVersion = Brew.installedCaskVersion(config.updateSettings.caskName, brew: brew)
        }
        await refreshIdentity()
        profileChecks = AWSProfiles.check(config: config, ini: INIFile.load(Paths.awsConfig))
        shellHookEnabled = ShellHook.isEnabled
        setupChecked = true
        if autoOpen, !passive, !didAutoOpenSetup, !setupProblems.isEmpty {
            didAutoOpenSetup = true
            openSetupWindow?()
        }
    }

    func refreshIdentity() async {
        identity = await KeycloakIdentity.resolve(
            settings: config.keycloakSettings,
            storedUsername: keycloakUsername.isEmpty ? nil : keycloakUsername,
            preferPrompt: mfaMode == .ask,
            existingTOTPItem: existingTOTPItem,
            keychain: Keychain(runner: runner))
        await refreshCurrentCode()
    }

    // Settings, kept as observable state so the Settings window always shows what's saved.

    enum MFAMode: String { case automatic, ask }
    private(set) var keycloakUsername = ""
    private(set) var mfaMode: MFAMode = .automatic
    /// A keychain item this person already keeps their TOTP seed in (account = macOS user).
    private(set) var existingTOTPItem: String?
    /// Several authenticator entries were found (e.g. an export): the person picks one.
    private(set) var otpChoices: [OTPAuth] = []
    private(set) var otpMessage: (text: String, ok: Bool)?
    private(set) var currentCode: String?
    private(set) var launchAtLogin = false

    private func loadSettings() {
        keycloakUsername = defaults.string(forKey: "keycloakUsername") ?? ""
        mfaMode = defaults.bool(forKey: "mfaPrompt") ? .ask : .automatic
        existingTOTPItem = defaults.string(forKey: "existingTOTPItem")
        autoUpdate = defaults.object(forKey: "autoUpdate") as? Bool
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var storedUsername: String { keycloakUsername.isEmpty ? (identity?.username ?? "") : keycloakUsername }

    func saveUsername(_ name: String) async {
        keycloakUsername = name.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(keycloakUsername.isEmpty ? nil : keycloakUsername, forKey: "keycloakUsername")
        await refreshIdentity()
    }

    /// Returns an error message, or nil on success.
    func savePassword(_ password: String) async -> String? {
        let user = storedUsername
        guard !user.isEmpty else { return "Set the username first" }
        guard !password.isEmpty else { return "Enter the password" }
        do {
            try await Keychain(runner: runner).store(service: Keychain.passwordService, account: user, secret: password)
            appendLog("Keycloak password saved to the keychain for \(user)")
        } catch {
            return error.localizedDescription
        }
        await refreshIdentity()
        return nil
    }

    func setMFAMode(_ mode: MFAMode) async {
        mfaMode = mode
        defaults.set(mode == .ask, forKey: "mfaPrompt")
        await refreshIdentity()
    }

    func setExistingTOTPItem(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        existingTOTPItem = trimmed.isEmpty ? nil : trimmed
        defaults.set(existingTOTPItem, forKey: "existingTOTPItem")
        await refreshIdentity()
        if let item = existingTOTPItem {
            otpMessage = identity?.mfa == .legacyTOTP(service: item)
                ? ("Using keychain item \(item)", true)
                : ("No keychain item named \(item) for \(NSUserName())", false)
        }
    }

    /// A pasted base32 secret, otpauth:// link or authenticator export link.
    func loadOTP(fromText text: String) async {
        await useOTPEntries(OTPAuth.parseAll(text), source: "text")
    }

    /// Text, or a screenshot of the QR (⌃⇧⌘4 copies one to the clipboard).
    func loadOTPFromClipboard() async {
        let (text, qr) = QRReader.clipboard()
        let entries = qr.flatMap(OTPAuth.parseAll) + (text.map(OTPAuth.parseAll) ?? [])
        await useOTPEntries(entries, source: qr.isEmpty ? "clipboard text" : "QR on the clipboard")
    }

    func loadOTPFromImageFile() async {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Open a QR code image"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        await useOTPEntries(QRReader.payloads(in: image).flatMap(OTPAuth.parseAll), source: url.lastPathComponent)
    }

    func loadOTPFromImages(_ images: [NSImage]) async {
        await useOTPEntries(images.flatMap(QRReader.payloads(in:)).flatMap(OTPAuth.parseAll), source: "dropped image")
    }

    func loadOTPFromScreen() async {
        do {
            let screens = try await QRReader.screens()
            await useOTPEntries(screens.flatMap(QRReader.payloads(in:)).flatMap(OTPAuth.parseAll), source: "screen")
        } catch {
            otpMessage = (error.localizedDescription, false)
        }
    }

    func chooseOTP(_ entry: OTPAuth) async {
        otpChoices = []
        await saveOTP(entry)
    }

    func cancelOTPChoice() { otpChoices = [] }

    private func useOTPEntries(_ entries: [OTPAuth], source: String) async {
        switch entries.count {
        case 0:
            otpMessage = ("No authenticator QR code or secret found in the \(source)", false)
        case 1:
            await saveOTP(entries[0])
        default:
            if let match = bestOTPMatch(entries) { await saveOTP(match) } else { otpChoices = entries }
        }
    }

    /// In an export with many accounts, the one for this Keycloak (by host, realm or username).
    private func bestOTPMatch(_ entries: [OTPAuth]) -> OTPAuth? {
        let kc = config.keycloakSettings
        let hints = [kc.idpHost?.split(separator: ".").first.map(String.init), kc.realm, storedUsername]
            .compactMap { $0?.lowercased() }.filter { $0.count >= 3 }
        let matches = entries.filter { e in hints.contains { e.label.lowercased().contains($0) } }
        return matches.count == 1 ? matches[0] : nil
    }

    private func saveOTP(_ entry: OTPAuth) async {
        let user = storedUsername
        guard !user.isEmpty else {
            otpMessage = ("Set your Keycloak username first", false)
            return
        }
        do {
            try await Keychain(runner: runner).store(service: Keychain.totpService, account: user, secret: entry.uri)
        } catch {
            otpMessage = (error.localizedDescription, false)
            return
        }
        mfaMode = .automatic
        defaults.set(false, forKey: "mfaPrompt")
        await refreshIdentity()
        otpMessage = ("Saved \(entry.label). Check the code below matches your authenticator.", true)
        appendLog("TOTP secret saved to the keychain (\(entry.label)): renewals run unattended")
    }

    func removeOTP() async {
        await Keychain(runner: runner).delete(service: Keychain.totpService, account: storedUsername)
        existingTOTPItem = nil
        defaults.removeObject(forKey: "existingTOTPItem")
        otpMessage = nil
        await refreshIdentity()
    }

    /// The current code for the stored secret, to compare with an authenticator app.
    func refreshCurrentCode() async {
        guard let id = identity else { currentCode = nil; return }
        let keychain = Keychain(runner: runner)
        let seed: String?
        switch id.mfa {
        case .appTOTP: seed = await keychain.read(service: Keychain.totpService, account: id.username ?? "")
        case .legacyTOTP(let service): seed = await keychain.read(service: service, account: NSUserName())
        case .prompt: seed = nil
        }
        currentCode = seed.flatMap { TOTP(stored: $0) }?.code(at: Date())
    }

    func openKeycloakAccount() {
        if let url = config.keycloakSettings.accountURL { NSWorkspace.shared.open(url) }
    }

    func install(_ tool: ToolCheck) {
        guard let brew = Doctor.brewPath else {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        guard !installing.contains(tool.id) else { return }
        installing.insert(tool.id)
        Task {
            defer { installing.remove(tool.id) }
            appendLog("\(tool.path == nil ? "Installing" : "Upgrading") \(tool.name) with Homebrew…")
            do {
                let verb = tool.path == nil ? "install" : "upgrade"
                let r = try await runner.run(brew, [verb, tool.formula], timeout: 1800,
                                             extraEnv: ["HOMEBREW_NO_ENV_HINTS": "1"])
                for line in (r.stdout + r.stderr).split(whereSeparator: \.isNewline).suffix(6) { appendLog("  \(line)") }
                appendLog(r.succeeded ? "✓ \(tool.name) \(verb)d" : "✗ brew \(verb) \(tool.formula): \(r.summary)",
                          error: !r.succeeded)
            } catch {
                appendLog(error.localizedDescription, error: true)
            }
            outdatedTools[Brew.shortName(tool.formula)] = nil
            await runChecks()
        }
    }

    func addMissingProfiles() {
        do {
            let n = try AWSProfiles.addMissing(config: config)
            appendLog("Added \(n) section\(n == 1 ? "" : "s") to ~/.aws/config (backup next to it)")
        } catch {
            appendLog("Could not update ~/.aws/config: \(error.localizedDescription)", error: true)
        }
        profileChecks = AWSProfiles.check(config: config, ini: INIFile.load(Paths.awsConfig))
    }

    func enableShellHook() {
        do {
            try ShellHook.enable()
            appendLog("Added the shell hook to ~/.zshrc (backup: ~/.zshrc.bak-assume-cloaker). Open a new terminal.")
        } catch {
            appendLog("Could not update ~/.zshrc: \(error.localizedDescription)", error: true)
        }
        shellHookEnabled = ShellHook.isEnabled
    }

    var configSourceText: String {
        switch configSource {
        case .user(let url):
            if joinedTeam { return "from your team invite" }
            return url.path.replacingOccurrences(of: Paths.home.path, with: "~")
        case .bundled: return "bundled with the app"
        case .none: return "none"
        }
    }

    /// Replaces the user config with a team config file someone shared.
    func importConfig() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Import team config"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try AppConfig.decode(data)
            try FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
            backupUserConfig()
            try data.write(to: Paths.configFile, options: .atomic)
            appendLog("Imported \(imported.name ?? url.lastPathComponent): \(imported.environments.count) environments")
        } catch {
            appendLog("Import failed: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Kube Logger

    var kubeLoggerAvailable: Bool {
        config.kubeLoggerEnabled && tools.contains { $0.command == "kube-logger-agent" && $0.path != nil }
    }

    /// Starts the agent (in the background, no terminal) and opens the viewer once it's connected.
    /// If an agent is already running, just opens the viewer.
    func startLogs() {
        if KubeLoggerFiles.runningPID() != nil {
            openLogViewer()
            return
        }
        guard let path = runner.which("kube-logger-agent") else {
            logAgent = .failed("kube-logger-agent is not installed")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: KubeLoggerFiles.log.path))?[.size] as? Int, size > 5_000_000 {
                let old = Paths.logDir.appending(path: "kube-logger.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: KubeLoggerFiles.log, to: old)
            }
            if !fm.fileExists(atPath: KubeLoggerFiles.log.path) { fm.createFile(atPath: KubeLoggerFiles.log.path, contents: nil) }
            let out = try FileHandle(forWritingTo: KubeLoggerFiles.log)
            agentLogOffset = try out.seekToEnd()
            out.write(Data("\n== \(Date()) started by Assume Cloaker\n".utf8))
            // Output goes straight to a file (not a pipe), so the agent keeps streaming if this app
            // restarts, e.g. for an update.
            let p = Process()
            p.executableURL = URL(filePath: path)
            p.environment = runner.environment.merging(["KUBE_LOGGER_NO_BROWSER": "1"]) { _, b in b }
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { [weak self] proc in
                let status = proc.terminationStatus
                Task { @MainActor in self?.agentExited(status: status) }
            }
            try p.run()
            agentProcess = p
            agentStartedAt = Date()
            openViewerWhenConnected = true
            logAgent = .starting
            appendLog("Kube Logger agent started (pid \(p.processIdentifier))")
        } catch {
            logAgent = .failed(error.localizedDescription)
            appendLog("Could not start kube-logger-agent: \(error.localizedDescription)", error: true)
        }
    }

    func openLogViewer() {
        // `--open` prints the persisted session's viewer URL and opens it.
        Task { _ = try? await runner.run("kube-logger-agent", ["--open"], timeout: 20, quiet: true) }
    }

    func stopLogs() {
        openViewerWhenConnected = false
        if let p = agentProcess, p.isRunning {
            p.terminate()
        } else if let pid = KubeLoggerFiles.runningPID() {
            kill(pid, SIGTERM)
        }
        appendLog("Kube Logger agent stopped")
        logAgent = .stopped
    }

    func openLogFile() { NSWorkspace.shared.open(KubeLoggerFiles.log) }

    private func agentExited(status: Int32) {
        agentProcess = nil
        if case .stopped = logAgent { return }
        logAgent = status == 0 ? .stopped : .failed("agent exited (code \(status)), see its log")
        if status != 0 { appendLog("Kube Logger agent exited with code \(status)", error: true) }
    }

    /// Tracks the agent (ours or one started elsewhere) and spots "[saas] connected" in its log.
    private func checkLogAgent() {
        let ours = agentProcess?.isRunning == true
        guard ours || KubeLoggerFiles.runningPID() != nil else {
            if case .running = logAgent { logAgent = .stopped }
            if logAgent == .starting { logAgent = .stopped }
            return
        }
        guard ours else {
            if logAgent != .running(connected: true) { logAgent = .running(connected: true) }  // started elsewhere
            return
        }
        let data = (try? Data(contentsOf: KubeLoggerFiles.log)) ?? Data()
        let tail = data.count > Int(agentLogOffset) ? String(decoding: data.dropFirst(Int(agentLogOffset)), as: UTF8.self) : ""
        // Connected if the last "[saas] connected" isn't followed by a disconnect/error.
        let connected = tail.range(of: "[saas] connected", options: .backwards).map { r in
            let after = tail[r.upperBound...]
            return after.range(of: "[saas] disconnected") == nil && after.range(of: "[saas] error") == nil
        } ?? false
        logAgent = .running(connected: connected)
        let waited = agentStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if openViewerWhenConnected, connected || waited > 10 {
            openViewerWhenConnected = false
            openLogViewer()
        }
    }

    // MARK: Environment management

    var teamEnvIDs: Set<String> { Set(teamConfig.environments.map(\.id)) }
    func isPersonal(_ env: EnvConfig) -> Bool { personal.environments.contains { $0.id == env.id } }
    func isHidden(_ id: String) -> Bool { personal.hidden.contains(id) }

    /// Adds or replaces one of this person's own environments.
    func savePersonalEnv(_ env: EnvConfig, replacing oldID: String? = nil) {
        var p = personal
        p.environments.removeAll { $0.id == (oldID ?? env.id) || $0.id == env.id }
        p.environments.append(env)
        writePersonal(p, log: "Saved \(env.displayName) (personal)")
    }

    func deletePersonalEnv(_ id: String) {
        var p = personal
        p.environments.removeAll { $0.id == id }
        setDesired(desired.subtracting([id]))
        writePersonal(p, log: "Removed \(id) (personal)")
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        var p = personal
        p.hidden.removeAll { $0 == id }
        if hidden { p.hidden.append(id); setDesired(desired.subtracting([id])) }
        writePersonal(p, log: hidden ? "Hid \(id)" : "Showing \(id) again")
    }

    private func writePersonal(_ p: PersonalConfig, log: String) {
        do {
            try p.save()
            appendLog(log)
            loadConfig()
        } catch {
            appendLog("Could not save personal environments: \(error.localizedDescription)", error: true)
        }
    }

    /// Suggestions from this Mac: kube contexts first, then SSO profiles not yet used.
    func discoverEnvironments() async -> [EnvConfig] {
        let aws = INIFile.load(Paths.awsConfig)
        let known = Set(config.environments.map { "\($0.profile)|\($0.cluster)" })
        let fromKube = await Discovery.kubeContexts(runner: runner, awsConfig: aws)
        let usedProfiles = Set(config.environments.map(\.profile) + fromKube.map(\.profile))
        let fromProfiles = Discovery.ssoProfiles(aws).filter { !usedProfiles.contains($0.profile) }
        return (fromKube + fromProfiles).filter { !known.contains("\($0.profile)|\($0.cluster)") }
    }

    func listClusters(profile: String, region: String) async -> Result<[String], ToolError> {
        do {
            return .success(try await Discovery.clusters(profile: profile, region: region, runner: runner))
        } catch {
            return .failure(ToolError(error.localizedDescription))
        }
    }

    // MARK: Team maintainer

    /// The team config this Mac maintains (e.g. a git-ignored private/team.json), if any. Its folder
    /// also holds team.key and team.id, created by scripts/team-config.sh.
    var teamSourceURL: URL? { defaults.string(forKey: "teamSourcePath").map { URL(filePath: $0) } }
    var isMaintainer: Bool { teamSourceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    private(set) var publishing = false

    var hasUnpublishedChanges: Bool {
        guard let url = teamSourceURL, let data = try? Data(contentsOf: url) else { return false }
        return defaults.string(forKey: "teamPublishedHash") != Self.hash(data)
    }

    func chooseTeamSource() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Team config you maintain"
        panel.message = "Pick the team's source config (kept private, e.g. private/team.json)."
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard (try? AppConfig.decode(Data(contentsOf: url))) != nil else {
            appendLog("\(url.lastPathComponent) is not a valid config", error: true)
            return
        }
        defaults.set(url.path, forKey: "teamSourcePath")
        appendLog("Maintaining the team config at \(url.path)")
        loadConfig()
    }

    func stopMaintaining() {
        defaults.removeObject(forKey: "teamSourcePath")
        loadConfig()
    }

    /// Edits the team source (maintainer only). Colleagues get it after Publish.
    func saveTeamEnv(_ env: EnvConfig, replacing oldID: String? = nil) {
        updateTeamSource(log: "Saved \(env.displayName) to the team config (not published yet)") { cfg in
            if let i = cfg.environments.firstIndex(where: { $0.id == (oldID ?? env.id) }) {
                cfg.environments[i] = env
            } else {
                cfg.environments.append(env)
            }
        }
    }

    func deleteTeamEnv(_ id: String) {
        updateTeamSource(log: "Removed \(id) from the team config (not published yet)") { cfg in
            cfg.environments.removeAll { $0.id == id }
        }
    }

    private func updateTeamSource(log: String, _ change: (inout AppConfig) -> Void) {
        guard let url = teamSourceURL else { return }
        do {
            var cfg = try AppConfig.decode(Data(contentsOf: url))
            change(&cfg)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(cfg).write(to: url, options: .atomic)
            appendLog(log)
            loadConfig()
        } catch {
            appendLog("Could not update the team config: \(error.localizedDescription)", error: true)
        }
    }

    /// Encrypts the source and replaces the published file through the GitHub API (`gh`).
    /// Returns an error message, or nil on success.
    func publishTeam() async -> String? {
        guard let source = teamSourceURL else { return "No team source chosen" }
        let dir = source.deletingLastPathComponent()
        guard let keyText = try? String(contentsOf: dir.appending(path: "team.key"), encoding: .utf8),
              let key = Base64URL.decode(keyText.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32,
              let id = try? String(contentsOf: dir.appending(path: "team.id"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else { return "team.key / team.id not found next to \(source.lastPathComponent): run scripts/team-config.sh publish once" }
        guard let invite = await currentInvite() ?? defaults.string(forKey: "teamRepo").flatMap({ repo in
            URL(string: "https://raw.githubusercontent.com/\(repo)/main/teams/\(id).acx").map { TeamInvite(url: $0, key: key) }
        }) else { return "Join your own team once (scripts/team-config.sh invite) so the app knows where it's published" }
        // https://raw.githubusercontent.com/<owner>/<repo>/<branch>/teams/<id>.acx
        let parts = invite.url.path.split(separator: "/").map(String.init)
        guard invite.url.host == "raw.githubusercontent.com", parts.count >= 5 else {
            return "Publishing from the app supports GitHub-hosted team configs only"
        }
        let repo = "\(parts[0])/\(parts[1])", branch = parts[2], path = parts[3...].joined(separator: "/")
        publishing = true
        defer { publishing = false }
        do {
            let plain = try Data(contentsOf: source)
            _ = try AppConfig.decode(plain)
            let sealed = try SealedTeamConfig.seal(plain, key: key)
            let existingSHA = try? await runner.run("gh", ["api", "repos/\(repo)/contents/\(path)?ref=\(branch)", "--jq", ".sha"],
                                                    timeout: 30, quiet: true)
            var body: [String: Any] = ["message": "Update team config", "branch": branch,
                                       "content": sealed.base64EncodedString()]
            if let sha = existingSHA, sha.succeeded { body["sha"] = sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            let tmp = FileManager.default.temporaryDirectory.appending(path: "assume-cloaker-publish-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: body).write(to: tmp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = try await runner.run("gh", ["api", "-X", "PUT", "repos/\(repo)/contents/\(path)", "--input", tmp.path],
                                         timeout: 60, quiet: true)
            guard r.succeeded else { return "gh: \(r.summary)" }
            defaults.set(Self.hash(plain), forKey: "teamPublishedHash")
            appendLog("Published the team config (\(teamConfig.environments.count) environments). Colleagues get it at their next check.")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Team invite

    var joinedTeam: Bool { defaults.string(forKey: "teamConfigURL") != nil }

    /// Downloads and decrypts the team config the invite points at, then keeps it up to date.
    /// Returns an error message, or nil on success.
    func joinTeam(_ text: String) async -> String? {
        guard let invite = TeamInvite.parse(text) else { return "That isn't an Assume Cloaker invite" }
        joiningTeam = true
        defer { joiningTeam = false }
        do {
            let (data, team) = try await fetchTeamConfig(invite)
            try await Keychain(runner: runner).store(service: Self.teamKeyService, account: "team",
                                                     secret: Base64URL.encode(invite.key))
            defaults.set(invite.url.absoluteString, forKey: "teamConfigURL")
            try writeTeamConfig(data)
            teamUpdatedAt = Date()
            teamError = nil
            appendLog("Joined \(team.name ?? "the team"): \(team.environments.count) environments")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshTeamConfig() async {
        guard let invite = await currentInvite() else { return }
        do {
            let (data, team) = try await fetchTeamConfig(invite)
            teamUpdatedAt = Date()
            teamError = nil
            if (try? Data(contentsOf: Paths.configFile)) != data {
                try writeTeamConfig(data)
                appendLog("Team config updated: \(team.environments.count) environments")
            }
        } catch {
            teamError = error.localizedDescription
            appendLog("Team config: \(error.localizedDescription)", error: true)
        }
    }

    func currentInvite() async -> TeamInvite? {
        guard let s = defaults.string(forKey: "teamConfigURL"), let url = URL(string: s),
              let keyText = await Keychain(runner: runner).read(service: Self.teamKeyService, account: "team"),
              let key = Base64URL.decode(keyText), key.count == 32 else { return nil }
        return TeamInvite(url: url, key: key)
    }

    /// Copies the invite code to pass to a colleague (over an internal channel).
    func copyInvite() async {
        guard let invite = await currentInvite() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.code, forType: .string)
        appendLog("Invite copied. Share it on internal channels only.")
        flash("Invite copied. Share it on internal channels only")
    }

    func leaveTeam() async {
        await Keychain(runner: runner).delete(service: Self.teamKeyService, account: "team")
        defaults.removeObject(forKey: "teamConfigURL")
        backupUserConfig()
        teamUpdatedAt = nil
        appendLog("Left the team: config removed")
    }

    /// From the `assume-cloaker://join?invite=…` link.
    func handleInviteLink(_ link: String) {
        guard let invite = TeamInvite.parse(link) else { return }
        closePanel?()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Join this team?"
        alert.informativeText = "Assume Cloaker will download the team's encrypted configuration from \(invite.url.host ?? "?") and keep it up to date."
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        guard presentModal(alert) == .alertFirstButtonReturn else { return }
        Task {
            if let error = await joinTeam(link) { appendLog("Join failed: \(error)", error: true) }
            openSetupWindow?()
        }
    }

    private func fetchTeamConfig(_ invite: TeamInvite) async throws -> (Data, AppConfig) {
        let request = URLRequest(url: invite.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (blob, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ToolError("could not download the team config (HTTP \(status))") }
        let plain = try SealedTeamConfig.open(blob, key: invite.key)
        return (plain, try AppConfig.decode(plain))
    }

    private func writeTeamConfig(_ data: Data) throws {
        try FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        try data.write(to: Paths.configFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.configFile.path)
    }

    /// Opens the user config for editing, starting from the bundled one if there is none yet.
    func editConfig() {
        if case .bundled(let url) = configSource, !FileManager.default.fileExists(atPath: Paths.configFile.path) {
            try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: url, to: Paths.configFile)
        }
        NSWorkspace.shared.open(Paths.configFile)
    }

    func useBundledConfig() {
        backupUserConfig()
        appendLog("Using the team config bundled with the app")
    }

    private func backupUserConfig() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.configFile.path) else { return }
        let backup = Paths.configDir.appending(path: "config.json.bak")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: Paths.configFile, to: backup)
    }

    // MARK: Panel sections & clock

    /// Coarse time for lights and texts that change by the minute (per-second labels tick on their own).
    private(set) var clock = Date()
    private(set) var expandedSections: Set<String> = []
    @ObservationIgnored private var lastNetworkProblem: Bool?

    func isExpanded(_ id: String) -> Bool { expandedSections.contains(id) }

    func toggleSection(_ id: String) { setExpanded(id, !isExpanded(id)) }

    func setExpanded(_ id: String, _ on: Bool) {
        if on { expandedSections.insert(id) } else { expandedSections.remove(id) }
        if !passive { defaults.set(Array(expandedSections).sorted(), forKey: "expandedSections") }
    }

    /// The network checks the config enables, in panel order.
    var networkChecks: [(name: String, check: Check)] {
        var out: [(String, Check)] = []
        if config.checkPoint.isEnabled { out.append(("VPN", vpn)) }
        if config.smartCard.isEnabled { out.append(("Smart card", card)) }
        if config.zscaler.isEnabled { out.append(("Zscaler", zscaler)) }
        for t in config.reachability { out.append((t.name, probes[t.id] ?? Check())) }
        return out
    }

    /// Network folds itself away while everything is fine and opens when something needs attention.
    private func autoCollapseNetwork() {
        let checks = networkChecks
        guard !checks.isEmpty, !checks.contains(where: { $0.check.title == "Checking…" }) else { return }
        let problem = checks.contains { $0.check.light == .red || $0.check.light == .yellow }
        guard problem != lastNetworkProblem else { return }
        lastNetworkProblem = problem
        setExpanded("network", problem)
    }

    // MARK: Update schedule

    /// Hours between app update checks; 0 = only when asked. The person's choice wins over the team's.
    private(set) var updateHours: Double = 1
    var updateInterval: TimeInterval? { updateHours > 0 ? updateHours * 3600 : nil }

    func setUpdateHours(_ hours: Double) {
        updateHours = hours
        defaults.set(hours, forKey: "updateHours")
        if let interval = updateInterval { lastTick["updates"] = Date().addingTimeInterval(10 - interval) }
    }

    // MARK: Updates

    var brewManaged: Bool { brewInstalledVersion != nil }

    var updateAvailable: Bool {
        guard brewManaged, let latest = latestVersion else { return false }
        return Version.isNewer(latest, than: appVersion)
    }

    private(set) var autoUpdate: Bool?
    var autoInstallUpdates: Bool { autoUpdate ?? config.updateSettings.autoInstallDefault }

    func setAutoInstallUpdates(_ on: Bool) {
        autoUpdate = on
        defaults.set(on, forKey: "autoUpdate")
        if on, updateAvailable { pendingAutoInstall = true }
    }

    /// No sign-in or switch in progress, so restarting for an update loses nothing.
    private var isIdle: Bool {
        !sessions.values.contains { $0.operation != nil } && !inFlight.contains { config.env($0) != nil }
    }

    /// Compares the cask's latest version with this app (refreshing just its tap, which is quick),
    /// and once a day runs a full `brew update` to list outdated CLIs.
    func checkForUpdates(userInitiated: Bool = false) async {
        guard let brew = Doctor.brewPath, !passive, !checkingUpdates else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        let settings = config.updateSettings
        let lastFull = defaults.object(forKey: "lastBrewUpdate") as? Date ?? .distantPast
        let fullDue = userInitiated || Date().timeIntervalSince(lastFull) > 86400
        let tapRefreshed = fullDue ? false : await Brew.refreshTap(of: settings, runner: runner, brew: brew)
        if fullDue || !tapRefreshed {
            _ = await Brew.update(runner: runner, brew: brew)
            defaults.set(Date(), forKey: "lastBrewUpdate")
            outdatedTools = await Brew.outdatedFormulae(tools.filter { $0.path != nil }.map { Brew.shortName($0.formula) },
                                                        runner: runner, brew: brew)
        }
        brewInstalledVersion = Brew.installedCaskVersion(settings.caskName, brew: brew)
        if brewManaged { latestVersion = await Brew.latestCaskVersion(settings.token, runner: runner, brew: brew) }
        lastUpdateCheck = Date()
        if !outdatedTools.isEmpty {
            appendLog("Updates for: " + outdatedTools.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        }
        guard updateAvailable, let latest = latestVersion else {
            if userInitiated {
                let text = brewManaged ? "Assume Cloaker \(appVersion) is up to date"
                                       : "Not installed with Homebrew: brew install --cask \(settings.token)"
                appendLog(text)
                flash(text, ok: brewManaged)
            }
            return
        }
        appendLog("Assume Cloaker \(latest) is available (running \(appVersion))")
        if autoInstallUpdates {
            pendingAutoInstall = true
        } else if defaults.string(forKey: "notifiedUpdate") != latest {
            defaults.set(latest, forKey: "notifiedUpdate")
            notifier.post(title: "Assume Cloaker \(latest) is available", body: "Click to update (it restarts itself).",
                          action: Notifier.updateAction)
        }
    }

    /// Hands off to a detached shell: brew upgrades the cask (which quits this app), then reopens it.
    func installUpdate() {
        guard let brew = Doctor.brewPath, brewManaged else { return }
        let log = Paths.logDir.appending(path: "update.log").path
        let token = config.updateSettings.token
        appendLog("Updating to \(latestVersion ?? "latest") with Homebrew; restarting…")
        logWriter.flush()
        defaults.set(appVersion, forKey: "updatedFrom")
        let script = """
        exec >> \(shellQuote(log)) 2>&1
        echo "== $(date) brew upgrade --cask \(token)"
        sleep 2
        \(shellQuote(brew)) upgrade --cask \(token)
        open -b com.gtalmor.AssumeCloaker
        """
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.environment = runner.environment.merging(Brew.environment) { _, b in b }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            appendLog("Could not start the update: \(error.localizedDescription)", error: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    private func reportFinishedUpdate() {
        guard let from = defaults.string(forKey: "updatedFrom") else { return }
        defaults.removeObject(forKey: "updatedFrom")
        if from != appVersion {
            appendLog("Updated from \(from) to \(appVersion)")
            notifier.post(title: "Assume Cloaker updated to \(appVersion)", body: "Your sessions carried on as before.")
        } else {
            appendLog("The update did not apply; see ~/Library/Logs/AssumeCloaker/update.log", error: true)
        }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Plumbing

    private var runner: ProcessRunner {
        ProcessRunner(extraPaths: config.toolPaths ?? []) { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
    }

    private var connectors: Connectors { Connectors(runner: runner, config: config, totp: totp) }

    func appendLog(_ text: String, error: Bool = false) {
        let line = LogLine(date: Date(), text: text, isError: error)
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        if !passive { logWriter.write(line) }
    }
}
