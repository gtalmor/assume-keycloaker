import KeycloakerCore
import SwiftUI

/// The menu bar panel. It redraws when the manager changes; only countdown labels tick every second
/// (a whole-panel timer would close open menus and reset hovers).
struct PopoverView: View {
    let manager: ConnectionManager

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(manager: manager)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            Divider()
            if manager.kubeLoggerAvailable {
                LogsRow(manager: manager)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                if let error = manager.configError {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let problem = manager.setupProblems.first {
                    SetupBanner(problem: problem, more: manager.setupProblems.count - 1) {
                        manager.openSetupWindow?()
                    }
                    .padding(.bottom, 4)
                }
                NetworkSection(manager: manager)
                EnvSection(id: "keycloak", title: "Keycloak", caption: "saml2aws", envs: manager.keycloakEnvs, manager: manager)
                EnvSection(id: "sso", title: "AWS SSO", caption: manager.config.ssoSessions?.map(\.name).joined(separator: ", "),
                           envs: manager.ssoEnvs, manager: manager)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            Divider()
            ActivityView(manager: manager)
            if let toast = manager.toast {
                HStack(spacing: 6) {
                    Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.ok ? Color.green : Color.orange)
                    Text(toast.text).font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            FooterView(manager: manager)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 392)
        .animation(.easeInOut(duration: 0.2), value: manager.toast?.text)
    }
}

/// Re-renders its content every second (only where seconds matter).
private struct Ticking<Content: View>: View {
    @ViewBuilder var content: (Date) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
    }
}

// MARK: Header

private struct HeaderView: View {
    let manager: ConnectionManager

    var body: some View {
        let now = manager.clock
        let env = manager.activeEnv
        let overall = manager.overall(now: now)
        let session = env.map(manager.session)
        HStack(alignment: .top, spacing: 12) {
            StatusOrb(light: overall.light, busy: session?.operation != nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(env?.displayName ?? "Not connected")
                        .font(.system(size: 17, weight: .semibold))
                    if env?.isProduction == true { Badge(text: "PROD", color: .red) }
                    Spacer(minLength: 4)
                    if let env {
                        Ticking { now in
                            Text(manager.session(env).statusText(kind: env.kind, now: now))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(manager.light(for: env, now: now).color)
                        }
                    }
                }
                Text(subtitle(env)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let env, let session, env.kind == .keycloak, session.valid, session.expiresAt != nil {
                    Ticking { now in
                        VStack(alignment: .leading, spacing: 4) {
                            SessionBar(fraction: (session.remaining(at: now) ?? 0) / Double(env.sessionDuration),
                                       color: manager.light(for: env, now: now).color)
                                .padding(.top, 3)
                            Text(renewalText(env, session, now: now))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(alignment: .center) {
                    SyncLine(manager: manager)
                    Spacer()
                    if let env { RenewButton(manager: manager, env: env) }
                }
                ForEach(env == nil ? [] : overall.reasons.filter { !$0.hasPrefix(env?.displayName ?? "\u{0}") }, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = session?.error, session?.valid != true {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
        }
    }

    private func subtitle(_ env: EnvConfig?) -> String {
        guard let env else {
            return manager.currentContext.map { "kubectl: \($0)" } ?? "Pick an environment below"
        }
        let kind = env.kind == .keycloak ? "Keycloak" : "AWS SSO"
        return [kind, manager.account(for: env), env.region, env.cluster].compactMap { $0 }.joined(separator: " · ")
    }

    private func renewalText(_ env: EnvConfig, _ s: EnvSession, now: Date) -> String {
        guard let exp = s.expiresAt else { return "" }
        if exp <= now { return "Expired \(Fmt.clock(exp))" }
        if manager.isKeptAlive(env) {
            return "Expires \(Fmt.clock(exp)) · auto-renews around \(Fmt.clock(exp.addingTimeInterval(-manager.config.refreshLead)))"
        }
        return "Expires \(Fmt.clock(exp)) · not kept alive"
    }
}

/// One click to renew the active session, or to sign in again once it lapsed.
private struct RenewButton: View {
    let manager: ConnectionManager
    let env: EnvConfig

    var body: some View {
        let s = manager.session(env)
        let live = manager.isLive(env) && !s.needsSignIn
        FeedbackButton(look: .text(live ? "Renew" : "Sign in", systemImage: live ? "arrow.clockwise" : "person.badge.key"),
                       prominent: !live,
                       help: live ? "Get a fresh session now" : (env.kind == .sso ? "Opens the AWS sign-in in your browser" : "Signs in with Keycloak")) {
            live ? await manager.renewAndWait(env) : await manager.useAndWait(env)
        }
        .controlSize(.small)
    }
}

/// Shows whether kubectl and new shell prompts follow the active environment.
private struct SyncLine: View {
    let manager: ConnectionManager

    var body: some View {
        let active = manager.activeEnvID
        HStack(spacing: 10) {
            item("kubectl", ok: active != nil)
            item("shells", ok: active != nil && manager.shellEnvID == active)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func item(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .symbolRenderingMode(.palette)
                .foregroundStyle(ok ? Color.white : Color.secondary, ok ? Color.green : Color.secondary)
            Text(name)
        }
        .help(ok ? "\(name) follow the active environment" : "\(name) are not on the active environment")
    }
}

// MARK: Sections

/// A section with a clickable header; collapsed it shows a one-line summary.
private struct CollapsibleSection<Summary: View, Content: View>: View {
    let manager: ConnectionManager
    let id: String
    let title: String
    let caption: String?
    @ViewBuilder var summary: () -> Summary
    @ViewBuilder var content: () -> Content

    var body: some View {
        let expanded = manager.isExpanded(id)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { manager.toggleSection(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.secondary)
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    if !expanded { summary() }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content() }
        }
    }
}

private struct NetworkSection: View {
    let manager: ConnectionManager

    var body: some View {
        let checks = manager.networkChecks
        if !checks.isEmpty {
            CollapsibleSection(manager: manager, id: "network", title: "Network", caption: nil) {
                HStack(spacing: 5) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                        StatusDot(light: c.check.light, busy: false).help("\(c.name): \(c.check.title)")
                    }
                    Text(summary(checks)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } content: {
                VStack(spacing: 1) {
                    if manager.config.checkPoint.isEnabled {
                        CheckRow(name: "Check Point VPN", check: manager.vpn) {
                            if manager.vpn.light != .green {
                                if manager.vpnBusy {
                                    ProgressView().controlSize(.small)
                                } else if manager.needsCard {
                                    Button("Insert card") {}.controlSize(.small).disabled(true)
                                        .help("The VPN authenticates with the certificate on your smart card")
                                } else {
                                    Button("Connect") { manager.connectVPN() }.controlSize(.small)
                                        .help("Asks Check Point to connect; it prompts for your card PIN")
                                }
                            }
                        }
                    }
                    if manager.config.smartCard.isEnabled {
                        CheckRow(name: "ID card (PKI)", check: manager.card) { EmptyView() }
                    }
                    if manager.config.zscaler.isEnabled {
                        CheckRow(name: "Zscaler", check: manager.zscaler) {
                            if manager.zscaler.light == .red {
                                Button("Open") { manager.openZscalerApp() }.controlSize(.small)
                            }
                        }
                    }
                    ForEach(manager.config.reachability) { target in
                        CheckRow(name: target.name, check: manager.probes[target.id] ?? Check()) { EmptyView() }
                    }
                }
            }
        }
    }

    private func summary(_ checks: [(name: String, check: Check)]) -> String {
        if let bad = checks.first(where: { $0.check.light == .red }) { return "\(bad.name): \(bad.check.title)" }
        if let warn = checks.first(where: { $0.check.light == .yellow }) { return "\(warn.name): \(warn.check.title)" }
        if checks.contains(where: { $0.check.title == "Checking…" }) { return "Checking…" }
        return "All good"
    }
}

private struct CheckRow<Trailing: View>: View {
    let name: String
    let check: Check
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(light: check.light, busy: false)
            Text(name).font(.system(size: 12.5))
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text(check.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(check.light == .red ? .red : .primary)
                if let detail = check.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            trailing()
        }
        .padding(.leading, 24).padding(.trailing, 8).padding(.vertical, 3)
        .frame(minHeight: 26)
    }
}

/// kube-logger: one row with its controls, no need to expand.
private struct LogsRow: View {
    let manager: ConnectionManager

    var body: some View {
        if manager.kubeLoggerAvailable {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                Text("LOGS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                StatusDot(light: check.light, busy: manager.logAgent == .starting)
                Text(check.title).font(.system(size: 11)).foregroundStyle(.secondary).help(check.detail ?? "")
                switch manager.logAgent {
                case .running:
                    Button("Open viewer") { manager.openLogViewer() }.controlSize(.small)
                    Button("Stop") { manager.stopLogs() }.controlSize(.small)
                case .starting:
                    Button("Stop") { manager.stopLogs() }.controlSize(.small)
                case .stopped, .failed:
                    Button("Start logs") { manager.startLogs() }.controlSize(.small)
                        .help("Starts the kube-logger agent in the background and opens the viewer")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contextMenu { Button("Open agent log") { manager.openLogFile() } }
        }
    }

    private var check: Check {
        switch manager.logAgent {
        case .running(connected: true): Check(light: .green, title: "Running", detail: "agent connected · pick namespaces in the viewer")
        case .running(connected: false): Check(light: .yellow, title: "Connecting…", detail: "agent started, waiting for the relay")
        case .starting: Check(light: .yellow, title: "Starting…")
        case .stopped: Check(light: .gray, title: "Stopped")
        case .failed(let why): Check(light: .red, title: "Failed", detail: why)
        }
    }
}

private struct EnvSection: View {
    let id: String
    let title: String
    let caption: String?
    let envs: [EnvConfig]
    let manager: ConnectionManager

    var body: some View {
        if !envs.isEmpty {
            CollapsibleSection(manager: manager, id: id, title: title, caption: caption) {
                summary
            } content: {
                VStack(spacing: 2) {
                    ForEach(envs) { env in EnvRow(manager: manager, env: env) }
                }
            }
        }
    }

    /// The live ones, e.g. "● demo 6h 54m", else a count.
    private var summary: some View {
        let live = envs.filter { manager.isLive($0) }
        return HStack(spacing: 5) {
            if live.isEmpty {
                Text("\(envs.count) · none connected").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(live.prefix(2)) { env in
                    StatusDot(light: manager.light(for: env, now: manager.clock), busy: manager.session(env).operation != nil)
                    Text(env.displayName).font(.system(size: 11, weight: manager.activeEnvID == env.id ? .semibold : .regular))
                }
                if live.count > 2 { Text("+\(live.count - 2)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .lineLimit(1)
    }
}

private struct EnvRow: View {
    let manager: ConnectionManager
    let env: EnvConfig
    @State private var hover = false

    var body: some View {
        let s = manager.session(env)
        let active = manager.activeEnvID == env.id
        let live = manager.isLive(env)
        HStack(spacing: 8) {
            StatusDot(light: manager.light(for: env, now: manager.clock), busy: s.operation != nil)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(env.displayName).font(.system(size: 13, weight: active ? .semibold : .regular))
                    if env.isProduction { Badge(text: "PROD", color: .red) }
                    if let note = env.note { Badge(text: note, color: .gray) }
                    if manager.isKeptAlive(env) {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                            .help("Kept alive: renewed automatically")
                    }
                }
                if let error = s.error, !s.valid, s.operation == nil {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1).help(error)
                } else if !live, s.operation == nil, hover {
                    Text(env.kind == .keycloak && manager.mfaMode == .ask && env.usesMFA ? "click to sign in · asks for your code" : "click to sign in")
                        .font(.system(size: 10)).foregroundStyle(Color.accentColor).lineLimit(1)
                } else {
                    Text([manager.account(for: env), env.region].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if s.operation != nil { ProgressView().controlSize(.mini) }
            Ticking { now in
                Text(manager.session(env).statusText(kind: env.kind, now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            if live, s.operation == nil, hover {
                FeedbackButton(look: .icon("arrow.clockwise"), help: "Renew now") { await manager.renewAndWait(env) }
            }
            if active {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
            }
            MenuButton(systemImage: "ellipsis.circle", help: "More") { entries(s, active: active) }
                .frame(width: 18, height: 18)
                .opacity(hover ? 1 : 0.45)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if !active || !live { manager.use(env) } }
        .help(active ? "Active environment" : "Click to connect and switch kubectl + shells to \(env.displayName)")
    }

    private func entries(_ s: EnvSession, active: Bool) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if !active { out.append(MenuEntry(title: "Use \(env.displayName)") { manager.use(env) }) }
        if env.kind == .sso, s.needsSignIn || !s.valid {
            out.append(MenuEntry(title: "Sign in…") { Task { await manager.signIn(env) } })
        } else {
            out.append(MenuEntry(title: "Renew now") { manager.renewNow(env) })
        }
        if manager.desired.contains(env.id) {
            out.append(MenuEntry(title: "Stop keeping alive") { manager.stopKeepingAlive(env) })
        } else {
            out.append(MenuEntry(title: "Keep alive") { manager.keepAlive(env) })
        }
        out.append(.separator)
        out.append(MenuEntry(title: "Copy shell exports") { manager.copyExports(env) })
        return out
    }
}

// MARK: Activity & footer

private struct ActivityView: View {
    let manager: ConnectionManager

    var body: some View {
        let expanded = manager.isExpanded("activity")
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { manager.toggleSection("activity") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Activity").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if !expanded, let last = manager.log.last {
                        Text(last.text).font(.system(size: 10.5)).lineLimit(1)
                            .foregroundStyle(last.isError ? Color.red : Color.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(manager.log.suffix(120)) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(Fmt.time(line.date)).foregroundStyle(.tertiary)
                                    Text(line.text).foregroundStyle(line.isError ? Color.red : Color.primary)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .id(line.id)
                            }
                        }
                    }
                    .frame(height: 170)
                    .onAppear { proxy.scrollTo(manager.log.last?.id, anchor: .bottom) }
                    .onChange(of: manager.log.last?.id) { _, id in proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct FooterView: View {
    let manager: ConnectionManager

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Auto-renew", isOn: Binding(get: { manager.autoRenew }, set: { manager.setAutoRenew($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11.5))
                .help("Renew kept-alive sessions \(Int(manager.config.refreshLead / 60)) min before they expire and reconnect after sleep")
            Spacer()
            if manager.updateAvailable, let latest = manager.latestVersion {
                Button("Update \(latest)") { manager.installUpdate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help("brew upgrade --cask \(manager.config.updateSettings.token), then restart")
            }
            FeedbackButton(look: .icon("arrow.clockwise"), help: "Re-check VPN, network, files and sessions now") {
                await manager.recheckAll()
                return true
            }
            MenuButton(systemImage: "gearshape", help: "Settings and more") { gearEntries }
                .frame(width: 18, height: 18)
        }
    }

    private var gearEntries: [MenuEntry] {
        var out: [MenuEntry] = [MenuEntry(title: "Settings…") { manager.openSetupWindow?() }, .separator]
        if manager.joinedTeam {
            out.append(MenuEntry(title: "Copy invite for a colleague") { Task { await manager.copyInvite() } })
        } else {
            out.append(MenuEntry(title: "Join a team…") { manager.openSetupWindow?() })
        }
        out.append(MenuEntry(title: "Open activity log") { manager.openLog() })
        out.append(MenuEntry(title: "Launch at login", checked: manager.launchAtLogin) {
            manager.setLaunchAtLogin(!manager.launchAtLogin)
        })
        out.append(.separator)
        out.append(MenuEntry(title: manager.checkingUpdates ? "Checking for updates…" : "Check for updates",
                             enabled: !manager.checkingUpdates && Doctor.brewPath != nil) {
            Task { await manager.checkForUpdates(userInitiated: true, ask: true) }
        })
        out.append(MenuEntry(title: "Version \(manager.appVersion)\(manager.brewManaged ? " (Homebrew)" : "")", enabled: false))
        out.append(.separator)
        out.append(MenuEntry(title: "Quit Assume Keycloaker") { NSApp.terminate(nil) })
        return out
    }
}

// MARK: Bits

private struct SetupBanner: View {
    let problem: String
    let more: Int
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finish setup").font(.system(size: 12, weight: .semibold))
                Text(more > 0 ? "\(problem) (+\(more) more)" : problem)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Open Settings", action: open).controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Time left in the session, as a slim capsule.
private struct SessionBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color.gradient)
                    .frame(width: max(4, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: 5)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct StatusDot: View {
    let light: Light
    let busy: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(light.color.gradient)
            .frame(width: 9, height: 9)
            .shadow(color: light == .green ? light.color.opacity(0.7) : .clear, radius: 3)
            .opacity(busy ? (pulse ? 0.35 : 1) : 1)
            .animation(busy ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
            .onAppear { pulse = busy }
            .onChange(of: busy) { _, b in pulse = b }
    }
}

private struct StatusOrb: View {
    let light: Light
    let busy: Bool

    var body: some View {
        ZStack {
            Circle().fill(light.color.opacity(0.18))
            Circle().fill(light.color.gradient).padding(7)
                .shadow(color: light.color.opacity(0.6), radius: light == .gray ? 0 : 5)
            Image(systemName: busy ? "arrow.triangle.2.circlepath" : icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.rotate, isActive: busy)
        }
        .frame(width: 38, height: 38)
    }

    private var icon: String {
        switch light {
        case .green: "checkmark"
        case .yellow: "exclamationmark"
        case .red: "xmark"
        case .gray: "minus"
        }
    }
}
