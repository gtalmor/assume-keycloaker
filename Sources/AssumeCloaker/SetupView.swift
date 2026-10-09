import AppKit
import CloakerCore
import SwiftUI

/// The "Setup & checks" window: everything a colleague needs, checked and fixable in one place.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let manager: ConnectionManager

    init(manager: ConnectionManager) { self.manager = manager }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(manager: manager) { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: host)
            w.title = "Assume Cloaker Setup"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 600, height: 760))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        Task { await manager.runChecks() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
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

struct SetupView: View {
    let manager: ConnectionManager
    let close: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var totpInput = ""
    @State private var passwordMessage: String?
    @State private var totpMessage: String?
    @State private var currentCode: String?
    @State private var busy = false
    @State private var inviteText = ""
    @State private var inviteMessage: String?
    @State private var existingItem = ""

    var body: some View {
        TabView {
            checks.tabItem { Text("Setup & checks") }
            EnvironmentsView(manager: manager).tabItem { Text("Environments") }
        }
        .padding(.top, 6)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            username = manager.storedUsername
            existingItem = manager.existingTOTPItem ?? ""
        }
        .onChange(of: manager.identity?.username) { _, new in if username.isEmpty { username = new ?? "" } }
    }

    private var checks: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    teamSection
                    toolsSection
                    updatesSection
                    if !manager.keycloakEnvs.isEmpty { keycloakSection }
                    if !manager.ssoEnvs.isEmpty { ssoSection }
                    networkSection
                    optionalSection
                }
                .padding(20)
            }
            Divider()
            HStack {
                if manager.setupProblems.isEmpty, manager.setupChecked {
                    Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if manager.setupChecked {
                    Text("\(manager.setupProblems.count) thing\(manager.setupProblems.count == 1 ? "" : "s") left to set up")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-run checks") { Task { await manager.runChecks() } }
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup & checks").font(.title2.weight(.semibold))
                Text(manager.config.environments.isEmpty
                     ? "Not set up yet"
                     : "Team config: **\(manager.config.name ?? "unnamed")** · \(manager.config.environments.count) environments · \(manager.configSourceText)")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if manager.joinedTeam {
                        Button("Invite a colleague") { Task { await manager.copyInvite() } }
                            .help("Copies the invite code. Share it on internal channels only.")
                        Button("Update now") { Task { await manager.refreshTeamConfig() } }
                        Button("Leave team") { Task { await manager.leaveTeam() } }
                    } else {
                        Button("Import config file…") { manager.importConfig() }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
                if let error = manager.teamError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let at = manager.teamUpdatedAt {
                    Text("Team config checked \(Fmt.clock(at))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var toolsSection: some View {
        SetupSection(title: "Command-line tools", caption: Doctor.brewPath == nil ? "Homebrew not found: install it from brew.sh" : "installed with Homebrew") {
            if !manager.setupChecked { ProgressView().controlSize(.small) }
            ForEach(manager.tools) { tool in
                let newer = manager.outdatedTools[Brew.shortName(tool.formula)]
                SetupRow(status: tool.ok ? .ok : (tool.required ? .error : .off),
                         title: tool.name + (tool.required ? "" : " (optional)"),
                         detail: tool.ok ? "\(tool.version ?? "?")\(newer.map { " → \($0) available" } ?? "") · \(tool.path ?? "")"
                                         : (tool.problem ?? "not installed: \(tool.purpose)")) {
                    if !tool.ok || newer != nil {
                        if manager.installing.contains(tool.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(tool.path == nil ? "Install" : "Upgrade") { manager.install(tool) }
                                .help("brew install \(tool.formula)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var teamSection: some View {
        if !manager.joinedTeam {
            SetupSection(title: "Join your team", caption: "paste the invite you were sent") {
                HStack(spacing: 8) {
                    TextField("acx1.… invite code or assume-cloaker:// link", text: $inviteText)
                        .textFieldStyle(.roundedBorder)
                    if manager.joiningTeam {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Join") {
                            Task {
                                inviteMessage = await manager.joinTeam(inviteText)
                                if inviteMessage == nil { inviteText = ""; await manager.runChecks() }
                            }
                        }
                        .disabled(inviteText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text(inviteMessage ?? "The invite unlocks your team's environments (they're stored encrypted) and keeps them up to date.")
                    .font(.caption).foregroundStyle(inviteMessage == nil ? Color.secondary : Color.red)
            }
        }
    }

    private var updatesSection: some View {
        let token = manager.config.updateSettings.token
        return SetupSection(title: "Updates", caption: "through Homebrew") {
            if manager.brewManaged {
                SetupRow(status: manager.updateAvailable ? .warn : .ok,
                         title: "Assume Cloaker \(manager.appVersion)",
                         detail: updateText) {
                    if manager.checkingUpdates {
                        ProgressView().controlSize(.small)
                    } else if manager.updateAvailable, let latest = manager.latestVersion {
                        Button("Update to \(latest)") { manager.installUpdate() }
                    } else {
                        Button("Check now") { Task { await manager.checkForUpdates(userInitiated: true) } }
                    }
                }
                Toggle("Install updates automatically (restarts the app; sessions carry on)", isOn: Binding(
                    get: { manager.autoInstallUpdates }, set: { manager.setAutoInstallUpdates($0) }))
                    .toggleStyle(.checkbox).font(.callout).padding(.leading, 28)
            } else {
                SetupRow(status: .off, title: "Assume Cloaker \(manager.appVersion)",
                         detail: "installed by hand; install with Homebrew to get updates") {
                    Button("Copy brew command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install --cask \(token)", forType: .string)
                    }
                    .help("brew install --cask \(token)")
                }
            }
        }
    }

    private var updateText: String {
        let checked = manager.lastUpdateCheck.map { "checked \(Fmt.clock($0))" } ?? "not checked yet"
        if manager.updateAvailable, let latest = manager.latestVersion { return "\(latest) available · \(checked)" }
        return "up to date · \(checked)"
    }

    private var keycloakSection: some View {
        let id = manager.identity
        return SetupSection(title: "Keycloak account", caption: manager.config.keycloakSettings.idpHost) {
            SetupRow(status: id?.username == nil ? .error : .ok, title: "Username",
                     detail: id?.username.map { "signing in as \($0)" } ?? "your Keycloak login, e.g. first.last") {
                TextField("first.last", text: $username).frame(width: 170).textFieldStyle(.roundedBorder)
                Button("Save") { Task { await manager.saveUsername(username) } }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || username == id?.username)
            }
            SetupRow(status: id?.password == .missing ? .error : .ok, title: "Password",
                     detail: passwordMessage ?? passwordText(id?.password)) {
                SecureField("password", text: $password).frame(width: 170).textFieldStyle(.roundedBorder)
                Button("Save") {
                    Task {
                        passwordMessage = await manager.savePassword(password)
                        if passwordMessage == nil { password = "" }
                    }
                }
                .disabled(password.isEmpty)
            }
            SetupRow(status: id?.unattended == true ? .ok : .warn, title: "MFA",
                     detail: totpMessage ?? mfaText(id?.mfa)) {
                if id?.unattended == true {
                    Button(currentCode.map { "Code: \($0)" } ?? "Show code") {
                        Task { currentCode = await manager.currentTOTPCode() }
                    }
                    .help("Compare with your authenticator app")
                }
            }
            HStack(spacing: 8) {
                SecureField("TOTP secret (base32) or otpauth:// link", text: $totpInput)
                    .textFieldStyle(.roundedBorder)
                Button("Save secret") {
                    Task {
                        totpMessage = await manager.saveTOTPSecret(totpInput)
                        if totpMessage == nil { totpInput = ""; currentCode = await manager.currentTOTPCode() }
                    }
                }
                .disabled(totpInput.isEmpty)
            }
            .padding(.leading, 28)
            HStack(spacing: 8) {
                TextField("or the name of a keychain item you already keep it in", text: $existingItem)
                    .textFieldStyle(.roundedBorder)
                Button("Use item") { Task { await manager.setExistingTOTPItem(existingItem) } }
                    .disabled(existingItem == (manager.existingTOTPItem ?? ""))
            }
            .padding(.leading, 28)
            Toggle("Ask me for the code instead (renewals then need a click)", isOn: Binding(
                get: { manager.prefersMFAPrompt },
                set: { on in Task { await manager.setMFAPrompt(on) } }))
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.leading, 28)
            Text("Stored in your login keychain only. The secret is the one behind the QR code Keycloak showed when you set up OTP.")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
        }
    }

    private var ssoSection: some View {
        SetupSection(title: "AWS SSO profiles", caption: "~/.aws/config") {
            if manager.profileChecks.isEmpty {
                Text("The config doesn't describe any SSO profiles (needs ssoSessions plus account/role per env).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.profileChecks) { check in
                SetupRow(status: status(check.status), title: "[\(check.section)]", detail: profileText(check.status)) {
                    EmptyView()
                }
            }
            if manager.profileChecks.contains(where: { $0.status == .missing }) {
                HStack {
                    Spacer()
                    Button("Add missing to ~/.aws/config") { manager.addMissingProfiles() }
                        .help("Appends only the missing sections, after a backup. Existing ones are not changed.")
                }
            }
        }
    }

    private var networkSection: some View {
        SetupSection(title: "VPN & security", caption: "installed by IT; checked, not installed here") {
            if manager.config.checkPoint.isEnabled {
                let installed = FileManager.default.isExecutableFile(atPath: manager.config.checkPoint.trac)
                SetupRow(status: installed ? (manager.vpn.light == .green ? .ok : .warn) : .error,
                         title: "Check Point Endpoint Security",
                         detail: installed ? "VPN \(manager.vpn.title.lowercased())\(manager.vpn.detail.map { " · \($0)" } ?? "")" : "not installed") {
                    if installed && manager.vpn.light != .green && !manager.needsCard {
                        Button("Connect") { manager.connectVPN() }
                    }
                }
            }
            if manager.config.smartCard.isEnabled {
                SetupRow(status: manager.cardInfo == nil ? .warn : (manager.card.light == .green ? .ok : .warn),
                         title: "ID card (PKI)",
                         detail: manager.cardInfo == nil ? "insert your card to check it (needs your card's driver / middleware)" : "\(manager.card.title) · \(manager.card.detail ?? "")") {
                    EmptyView()
                }
            }
            if manager.config.zscaler.isEnabled {
                let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.zscaler.zscaler") != nil
                SetupRow(status: installed ? (manager.zscaler.light == .green ? .ok : .warn) : .error,
                         title: "Zscaler Client Connector",
                         detail: installed ? "\(manager.zscaler.title)\(manager.zscaler.detail.map { " · \($0)" } ?? "")" : "not installed") {
                    EmptyView()
                }
            }
        }
    }

    private var optionalSection: some View {
        SetupSection(title: "Optional", caption: nil) {
            SetupRow(status: manager.shellHookEnabled ? .ok : .off, title: "Terminals follow the active env",
                     detail: manager.shellHookEnabled ? "hook loaded from ~/.zshrc" : "sets AWS_PROFILE / AWS_REGION at each prompt (kubectl follows without it)") {
                if !manager.shellHookEnabled {
                    Button("Add to ~/.zshrc") { manager.enableShellHook() }
                }
            }
            SetupRow(status: manager.launchAtLogin ? .ok : .off, title: "Launch at login",
                     detail: "start Assume Cloaker when you log in") {
                Toggle("", isOn: Binding(get: { manager.launchAtLogin }, set: { manager.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    // MARK: Text

    private func passwordText(_ source: PasswordSource?) -> String {
        switch source {
        case .app: "saved in your keychain by Assume Cloaker"
        case .saml2aws: "using the one saml2aws saved in your keychain"
        case .missing, nil: "not saved yet"
        }
    }

    private func mfaText(_ source: MFASource?) -> String {
        switch source {
        case .appTOTP: "TOTP secret in your keychain: renewals run unattended"
        case .legacyTOTP(let service): "TOTP secret from keychain item \(service): renewals run unattended"
        case .prompt, nil: "you'll be asked for the 6-digit code; save the secret below for unattended renewals"
        }
    }

    private func status(_ s: ProfileStatus) -> RowStatus {
        switch s {
        case .ok: .ok
        case .missing: .error
        case .mismatch: .warn
        }
    }

    private func profileText(_ s: ProfileStatus) -> String {
        switch s {
        case .ok: "present"
        case .missing: "missing"
        case .mismatch(let keys): "differs from the team config: \(keys.joined(separator: ", ")) (left as is)"
        }
    }
}

private struct SetupSection<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct SetupRow<Trailing: View>: View {
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
