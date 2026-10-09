import AppKit
import KeycloakerCore
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: a sidebar of panes, each with a status light.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let manager: ConnectionManager
    private let selection = PaneSelection()

    init(manager: ConnectionManager) { self.manager = manager }

    func show(pane: SettingsPane? = nil) {
        // A menu-bar-only app's windows aren't managed by Stage Manager (and may open behind others):
        // be a regular app, with a Dock icon, while Settings is open.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(manager: manager, selection: selection))
            let w = NSWindow(contentViewController: host)
            w.title = "Assume Keycloaker Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 820, height: 600))
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
            w.delegate = self
            w.center()
            window = w
        }
        selection.pane = pane ?? SettingsPane.firstNeedingAttention(manager) ?? selection.pane
        Task { await manager.runChecks() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // The menu bar panel doesn't activate the app, and macOS may refuse the request above:
        // bring the window forward anyway so it never opens hidden behind other apps.
        window?.orderFrontRegardless()
    }

    /// Back to menu-bar-only once Settings closes.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor @Observable
final class PaneSelection {
    var pane: SettingsPane = .team
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case team, account, environments, profiles, network, tools, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .team: "Team"
        case .account: "Account & MFA"
        case .environments: "Environments"
        case .profiles: "AWS profiles"
        case .network: "Network & security"
        case .tools: "Tools & updates"
        case .general: "General"
        }
    }

    var icon: String {
        switch self {
        case .team: "person.2"
        case .account: "key"
        case .environments: "square.stack.3d.up"
        case .profiles: "doc.text"
        case .network: "network"
        case .tools: "wrench.adjustable"
        case .general: "gearshape"
        }
    }

    @MainActor func status(_ m: ConnectionManager) -> RowStatus {
        switch self {
        case .team:
            return m.config.environments.isEmpty ? .error : (m.teamError != nil ? .warn : .ok)
        case .account:
            guard !m.keycloakEnvs.isEmpty, let id = m.identity else { return .off }
            if id.username == nil || id.password == .missing { return .error }
            return id.unattended || m.mfaMode == .ask ? .ok : .warn
        case .environments:
            return m.config.environments.isEmpty ? .off : .ok
        case .profiles:
            if m.profileChecks.isEmpty { return .off }
            if m.profileChecks.contains(where: { $0.status == .missing }) { return .error }
            return m.profileChecks.contains(where: { if case .mismatch = $0.status { return true }; return false }) ? .warn : .ok
        case .network:
            let lights = [m.config.checkPoint.isEnabled ? m.vpn.light : nil,
                          m.config.zscaler.isEnabled ? m.zscaler.light : nil] + m.config.reachability.map { m.probes[$0.id]?.light }
            let known = lights.compactMap { $0 }
            if known.isEmpty { return .off }
            if known.contains(.red) { return .error }
            return known.contains(.yellow) ? .warn : .ok
        case .tools:
            if m.tools.contains(where: { $0.required && !$0.ok }) { return .error }
            return m.updateAvailable || !m.outdatedTools.isEmpty ? .warn : .ok
        case .general:
            return .off
        }
    }

    /// Where Settings opens when something blocks a working setup.
    @MainActor static func firstNeedingAttention(_ m: ConnectionManager) -> SettingsPane? {
        guard m.setupChecked else { return nil }
        return [.team, .tools, .account, .profiles].first { $0.status(m) == .error }
    }
}

enum RowStatus {
    case ok, warn, error, off

    var icon: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .off: "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .error: .red
        case .off: .secondary
        }
    }
}

struct SettingsView: View {
    let manager: ConnectionManager
    @Bindable var selection: PaneSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { selection.pane }, set: { if let p = $0 { selection.pane = p } })) { pane in
                SidebarRow(pane: pane, status: pane.status(manager))
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 250)
        } detail: {
            Group {
                switch selection.pane {
                case .environments: EnvironmentsView(manager: manager)
                default: ScrollView { PaneContent(manager: manager, pane: selection.pane).padding(24) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem {
                    FeedbackButton(look: .icon("arrow.clockwise"), help: "Re-run all checks") {
                        await manager.runChecks()
                        await manager.recheckAll()
                        return true
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

/// The sidebar rows outside a List (for --snapshot, which can't draw split views).
struct SidebarPreview: View {
    let manager: ConnectionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                SidebarRow(pane: pane, status: pane.status(manager))
                    .padding(.horizontal, 8)
                    .background(pane == .team ? Color.accentColor.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
    }
}

/// Sidebar entry: icons in a fixed-width column so titles line up, status badge on the right.
private struct SidebarRow: View {
    let pane: SettingsPane
    let status: RowStatus

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: pane.icon)
                .font(.system(size: 13, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 20, height: 20, alignment: .center)
            Text(pane.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: status.icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(status.color)
                .frame(width: 14)
                .opacity(status == .off ? 0 : 1)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

/// One pane's content (also rendered on its own by --snapshot).
struct PaneContent: View {
    let manager: ConnectionManager
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(pane.title).font(.title2.weight(.semibold))
            switch pane {
            case .team: TeamPane(manager: manager)
            case .account: AccountPane(manager: manager)
            case .environments: EnvironmentsView(manager: manager)
            case .profiles: ProfilesPane(manager: manager)
            case .network: NetworkPane(manager: manager)
            case .tools: ToolsPane(manager: manager)
            case .general: GeneralPane(manager: manager)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: Team

private struct TeamPane: View {
    let manager: ConnectionManager
    @State private var invite = ""
    @State private var message: String?

    var body: some View {
        if manager.joinedTeam || !manager.config.environments.isEmpty {
            SetupGroup(title: manager.config.name ?? "Your team", caption: manager.configSourceText) {
                SettingsRow(status: manager.teamError == nil ? .ok : .warn,
                            title: "\(manager.teamConfig.environments.count) team environments",
                            detail: manager.teamError ?? manager.teamUpdatedAt.map { "checked for changes \(Fmt.clock($0))" } ?? "kept up to date automatically") {
                    if manager.joinedTeam {
                        FeedbackButton(look: .text("Check now")) {
                            await manager.refreshTeamConfig()
                            return manager.teamError == nil
                        }
                    }
                }
                if manager.joinedTeam {
                    HStack {
                        FeedbackButton(look: .text("Copy invite for a colleague", systemImage: "doc.on.doc")) {
                            await manager.copyInvite()
                            return true
                        }
                        Text("Share it on internal channels only.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Leave team", role: .destructive) { Task { await manager.leaveTeam() } }
                    }
                }
            }
        }
        if !manager.joinedTeam {
            SetupGroup(title: "Join a team", caption: "with the invite you were sent") {
                HStack(spacing: 8) {
                    TextField("acx1.… or assume-keycloaker://join?invite=…", text: $invite)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { _ = await join(invite) } }
                    FeedbackButton(look: .text("Paste & join", systemImage: "doc.on.clipboard"), prominent: true) {
                        await join(NSPasteboard.general.string(forType: .string) ?? "")
                    }
                    FeedbackButton(look: .text("Join")) { await join(invite) }
                        .disabled(invite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(message ?? "The invite unlocks your team's environments (stored encrypted) and keeps them up to date.")
                    .font(.caption).foregroundStyle(message == nil ? Color.secondary : Color.red)
                Divider()
                HStack {
                    Text("No invite? Load a config file instead.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import config file…") { manager.importConfig() }
                }
            }
        }
    }

    private func join(_ text: String) async -> Bool {
        message = await manager.joinTeam(text)
        guard message == nil else { return false }
        invite = ""
        await manager.runChecks()
        return true
    }
}

// MARK: Account & MFA

private struct AccountPane: View {
    let manager: ConnectionManager
    @State private var username = ""
    @State private var password = ""
    @State private var passwordMessage: String?
    @State private var secretText = ""
    @State private var existingItem = ""
    @State private var showHelp = false
    @State private var dropTargeted = false

    var body: some View {
        if manager.keycloakEnvs.isEmpty {
            Text("Your team's environments don't use Keycloak, so there's nothing to set up here.")
                .foregroundStyle(.secondary)
        } else {
            let id = manager.identity
            SetupGroup(title: "Keycloak sign-in", caption: manager.config.keycloakSettings.idpHost) {
                SettingsRow(status: id?.username == nil ? .error : .ok, title: "Username",
                            detail: id?.username.map { "signing in as \($0)" } ?? "your Keycloak login, e.g. first.last") {
                    TextField("first.last", text: $username)
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                        .task(id: id?.username) { if username.isEmpty { username = manager.storedUsername } }
                        .onSubmit { Task { await manager.saveUsername(username) } }
                    FeedbackButton(look: .text("Save")) {
                        await manager.saveUsername(username)
                        return manager.identity?.username != nil
                    }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || username == id?.username)
                }
                SettingsRow(status: id?.password == .missing ? .error : .ok, title: "Password",
                            detail: passwordMessage ?? passwordText(id?.password)) {
                    SecureField("password", text: $password)
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                        .onSubmit { Task { _ = await savePassword() } }
                    FeedbackButton(look: .text("Save")) { await savePassword() }.disabled(password.isEmpty)
                }
            }
            mfaGroup
        }
    }

    private var mfaGroup: some View {
        SetupGroup(title: "One-time codes (MFA)", caption: nil) {
            Picker("", selection: Binding(get: { manager.mfaMode }, set: { m in Task { await manager.setMFAMode(m) } })) {
                Text("Automatic: the app makes the codes").tag(ConnectionManager.MFAMode.automatic)
                Text("Ask me each time").tag(ConnectionManager.MFAMode.ask)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if manager.mfaMode == .ask {
                Text("When signing in, Assume Keycloaker asks for the 6-digit code from your authenticator (paste works; a code on the clipboard is filled in). Renewals show a notification you click.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if manager.identity?.unattended == true {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(secretSource).font(.system(size: 13, weight: .medium))
                        Text("Renewals run on their own. Compare the code with your authenticator:")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(grouped(manager.currentCode) ?? "––– –––")
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .task(id: Int(Date().timeIntervalSince1970 / 30)) { await manager.refreshCurrentCode() }
                    }
                    // Only the app's own item is ever deleted; an item named by the person is just let go.
                    Button(manager.identity?.mfa == .appTOTP ? "Remove" : "Stop using") { Task { await manager.removeOTP() } }
                }
                messageLine
            } else {
                loadSecret
            }
        }
        .sheet(isPresented: Binding(get: { !manager.otpChoices.isEmpty }, set: { if !$0 { manager.cancelOTPChoice() } })) {
            OTPChoiceSheet(manager: manager)
        }
    }

    private var loadSecret: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Load your authenticator's secret so the app can make the codes. It stays in your login keychain.")
                .font(.callout)
            HStack(spacing: 8) {
                FeedbackButton(look: .text("Paste", systemImage: "doc.on.clipboard"), prominent: true) {
                    await manager.loadOTPFromClipboard()
                    return manager.identity?.unattended == true || !manager.otpChoices.isEmpty
                }
                    .help("A QR screenshot (⌃⇧⌘4), an otpauth:// link or the secret itself")
                FeedbackButton(look: .text("Open QR image…", systemImage: "photo")) {
                    await manager.loadOTPFromImageFile()
                    return manager.identity?.unattended == true || !manager.otpChoices.isEmpty
                }
                FeedbackButton(look: .text("Scan screen", systemImage: "qrcode.viewfinder")) {
                    await manager.loadOTPFromScreen()
                    return manager.identity?.unattended == true || !manager.otpChoices.isEmpty
                }
                    .help("Finds the QR code currently shown on your screen (needs Screen Recording permission)")
            }
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(height: 54)
                .overlay(Text("…or drop a QR image here").font(.caption).foregroundStyle(.secondary))
                .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
                    loadDropped(providers)
                    return true
                }
            HStack(spacing: 8) {
                SecureField("or type the secret / otpauth:// link", text: $secretText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { _ = await saveText() } }
                FeedbackButton(look: .text("Save")) { await saveText() }.disabled(secretText.isEmpty)
            }
            HStack(spacing: 8) {
                TextField("or the name of a keychain item you already keep it in", text: $existingItem)
                    .textFieldStyle(.roundedBorder)
                FeedbackButton(look: .text("Use")) {
                    await manager.setExistingTOTPItem(existingItem)
                    return manager.otpMessage?.ok ?? false
                }
                    .disabled(existingItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            messageLine
            DisclosureGroup("Where do I find the QR code?", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    help("Set it up again in Keycloak (simplest)",
                         "Open your account page → Signing in → set up an authenticator app. Scan the QR with your phone and with Scan screen here at the same time, so both share the same secret. Keep just one authenticator registered.")
                    if manager.config.keycloakSettings.accountURL != nil {
                        Button("Open my Keycloak account page") { manager.openKeycloakAccount() }.controlSize(.small)
                    }
                    help("Google Authenticator", "⋯ → Transfer accounts → Export accounts. Take a screenshot of the QR, AirDrop it to this Mac and use Open QR image (pick your entry if there are several).")
                    help("A password manager", "If it shows the setup key or an otpauth:// link, copy it and click Paste.")
                    help("Microsoft Authenticator / apps without export", "They can't hand the secret over: set it up again in Keycloak as above, or choose Ask me each time.")
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var messageLine: some View {
        if let m = manager.otpMessage {
            Label(m.text, systemImage: m.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(m.ok ? Color.green : Color.orange)
        }
    }

    private var secretSource: String {
        switch manager.identity?.mfa {
        case .appTOTP: "Secret saved in your keychain"
        case .legacyTOTP(let item): "Using keychain item \(item)"
        default: "Secret saved"
        }
    }

    private func help(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func grouped(_ code: String?) -> String? {
        guard let code, code.count >= 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }

    private func savePassword() async -> Bool {
        passwordMessage = await manager.savePassword(password)
        if passwordMessage == nil { password = "" }
        return passwordMessage == nil
    }

    private func saveText() async -> Bool {
        await manager.loadOTP(fromText: secretText)
        let ok = manager.identity?.unattended == true
        if ok { secretText = "" }
        return ok
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data, let image = NSImage(data: data) else { return }
                Task { @MainActor in await manager.loadOTPFromImages([image]) }
            }
        }
    }

    private func passwordText(_ source: PasswordSource?) -> String {
        switch source {
        case .app: "saved in your keychain"
        case .saml2aws: "using the one saml2aws saved in your keychain"
        case .missing, nil: "not saved yet"
        }
    }
}

private struct OTPChoiceSheet: View {
    let manager: ConnectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which account is your Keycloak one?").font(.headline)
            Text("The code found holds several authenticator entries.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(manager.otpChoices.enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(entry.label)
                    Spacer()
                    Button("Use this") { Task { await manager.chooseOTP(entry) } }
                }
            }
            HStack { Spacer(); Button("Cancel") { manager.cancelOTPChoice() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: AWS profiles

private struct ProfilesPane: View {
    let manager: ConnectionManager

    var body: some View {
        SetupGroup(title: "~/.aws/config", caption: "the SSO profiles your team's environments use") {
            if manager.profileChecks.isEmpty {
                Text("Nothing to set up: no AWS SSO environments in the team config.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.profileChecks) { check in
                SettingsRow(status: status(check.status), title: "[\(check.section)]", detail: text(check.status)) { EmptyView() }
            }
            if manager.profileChecks.contains(where: { $0.status == .missing }) {
                HStack {
                    Text("Adds only what's missing, after a backup. Existing sections are never changed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    FeedbackButton(look: .text("Add missing"), prominent: true) {
                        manager.addMissingProfiles()
                        return !manager.profileChecks.contains { $0.status == .missing }
                    }
                }
            }
        }
    }

    private func status(_ s: ProfileStatus) -> RowStatus {
        switch s {
        case .ok: .ok
        case .missing: .error
        case .mismatch: .warn
        }
    }

    private func text(_ s: ProfileStatus) -> String {
        switch s {
        case .ok: "present"
        case .missing: "missing"
        case .mismatch(let keys): "differs from the team config: \(keys.joined(separator: ", ")) (left as is)"
        }
    }
}

// MARK: Network

private struct NetworkPane: View {
    let manager: ConnectionManager

    var body: some View {
        let cfg = manager.config
        if !cfg.checkPoint.isEnabled && !cfg.zscaler.isEnabled && !cfg.smartCard.isEnabled && cfg.reachability.isEmpty {
            Text("Your team config doesn't ask for any network checks.").foregroundStyle(.secondary)
        }
        if cfg.checkPoint.isEnabled || cfg.smartCard.isEnabled || cfg.zscaler.isEnabled {
            SetupGroup(title: "VPN & security", caption: "installed by IT; checked here") {
                if cfg.checkPoint.isEnabled {
                    let installed = FileManager.default.isExecutableFile(atPath: cfg.checkPoint.trac)
                    SettingsRow(status: installed ? row(manager.vpn.light) : .error, title: "Check Point VPN",
                                detail: installed ? "\(manager.vpn.title)\(manager.vpn.detail.map { " · \($0)" } ?? "")" : "not installed") {
                        if installed && manager.vpn.light != .green && !manager.needsCard {
                            Button("Connect") { manager.connectVPN() }
                        }
                    }
                }
                if cfg.smartCard.isEnabled {
                    SettingsRow(status: row(manager.card.light), title: "Smart card",
                                detail: "\(manager.card.title)\(manager.card.detail.map { " · \($0)" } ?? "")") { EmptyView() }
                }
                if cfg.zscaler.isEnabled {
                    let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.zscaler.zscaler") != nil
                    SettingsRow(status: installed ? row(manager.zscaler.light) : .error, title: "Zscaler",
                                detail: installed ? "\(manager.zscaler.title)\(manager.zscaler.detail.map { " · \($0)" } ?? "")" : "not installed") { EmptyView() }
                }
            }
        }
        if !cfg.reachability.isEmpty {
            SetupGroup(title: "Endpoints", caption: "TCP checks") {
                ForEach(cfg.reachability) { t in
                    let c = manager.probes[t.id] ?? Check()
                    SettingsRow(status: row(c.light), title: t.name, detail: "\(t.host):\(t.port) · \(c.title)\(c.detail.map { " · \($0)" } ?? "")") { EmptyView() }
                }
            }
        }
    }

    private func row(_ l: Light) -> RowStatus {
        switch l {
        case .green: .ok
        case .yellow: .warn
        case .red: .error
        case .gray: .off
        }
    }
}

// MARK: Tools & updates

private struct ToolsPane: View {
    let manager: ConnectionManager

    var body: some View {
        SetupGroup(title: "Command-line tools", caption: Doctor.brewPath == nil ? "Homebrew not found: install it from brew.sh" : "installed with Homebrew") {
            if !manager.setupChecked { ProgressView().controlSize(.small) }
            ForEach(manager.tools) { tool in
                let newer = manager.outdatedTools[Brew.shortName(tool.formula)]
                SettingsRow(status: tool.ok ? (newer == nil ? .ok : .warn) : (tool.required ? .error : .off),
                            title: tool.name + (tool.required ? "" : " (optional)"),
                            detail: tool.ok ? "\(tool.version ?? "?")\(newer.map { " → \($0) available" } ?? "") · \(tool.path ?? "")"
                                            : (tool.problem ?? "not installed: \(tool.purpose)")) {
                    if !tool.ok || newer != nil {
                        if manager.installing.contains(tool.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(tool.path == nil ? "Install" : "Upgrade") { manager.install(tool) }
                                .help("brew \(tool.path == nil ? "install" : "upgrade") \(tool.formula)")
                        }
                    }
                }
            }
        }
        SetupGroup(title: "Assume Keycloaker \(manager.appVersion)", caption: manager.brewManaged ? "updates through Homebrew" : nil) {
            if manager.brewManaged {
                SettingsRow(status: manager.updateAvailable ? .warn : .ok,
                            title: manager.updateAvailable ? "\(manager.latestVersion ?? "") available" : "Up to date",
                            detail: manager.lastUpdateCheck.map { "checked \(Fmt.clock($0))" } ?? "checks every few hours") {
                    if manager.checkingUpdates {
                        ProgressView().controlSize(.small)
                    } else if manager.updateAvailable {
                        Button("Update now") { manager.installUpdate() }.buttonStyle(.borderedProminent)
                    } else {
                        FeedbackButton(look: .text("Check now")) {
                            await manager.checkForUpdates(userInitiated: true)
                            return true
                        }
                    }
                }
                Picker("Check for updates", selection: Binding(get: { manager.updateHours }, set: { manager.setUpdateHours($0) })) {
                    Text("Every hour").tag(1.0)
                    Text("Every 6 hours").tag(6.0)
                    Text("Once a day").tag(24.0)
                    Text("Only when I ask").tag(0.0)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Toggle("Install updates automatically (the app restarts; sessions carry on)", isOn: Binding(
                    get: { manager.autoInstallUpdates }, set: { manager.setAutoInstallUpdates($0) }))
                    .toggleStyle(.checkbox)
                Text("Also checked a few seconds after the app starts. CLI tool updates are looked up once a day.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SettingsRow(status: .off, title: "Installed by hand",
                            detail: "install with Homebrew to get updates: brew install --cask \(manager.config.updateSettings.token)") {
                    FeedbackButton(look: .text("Copy command", systemImage: "doc.on.doc")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install --cask \(manager.config.updateSettings.token)", forType: .string)
                        return true
                    }
                }
            }
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    let manager: ConnectionManager

    var body: some View {
        SetupGroup(title: "Behaviour", caption: nil) {
            Toggle("Keep sessions alive (renew before they expire, reconnect after sleep)", isOn: Binding(
                get: { manager.autoRenew }, set: { manager.setAutoRenew($0) }))
            Toggle("Launch at login", isOn: Binding(get: { manager.launchAtLogin }, set: { manager.setLaunchAtLogin($0) }))
        }
        SetupGroup(title: "Terminals", caption: "optional") {
            SettingsRow(status: manager.shellHookEnabled ? .ok : .off, title: "Terminals follow the active environment",
                        detail: manager.shellHookEnabled ? "hook loaded from ~/.zshrc" : "sets AWS_PROFILE / AWS_REGION at each prompt (kubectl follows without it)") {
                if !manager.shellHookEnabled {
                    FeedbackButton(look: .text("Add to ~/.zshrc")) {
                        manager.enableShellHook()
                        return manager.shellHookEnabled
                    }
                }
            }
        }
        SetupGroup(title: "Files", caption: nil) {
            HStack {
                Button("Open activity log") { manager.openLog() }
                Button("Edit config.json…") { manager.editConfig() }
            }
        }
    }
}

// MARK: Rows

struct SettingsRow<Trailing: View>: View {
    let status: RowStatus
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.icon).foregroundStyle(status.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .controlSize(.small)
    }
}
