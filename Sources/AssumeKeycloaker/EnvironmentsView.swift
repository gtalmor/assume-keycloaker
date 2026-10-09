import KeycloakerCore
import SwiftUI

/// Setup → Environments: see where each environment comes from, add your own (or pick from this
/// Mac's kube contexts and AWS profiles), hide team ones, and, as the team's maintainer, edit and
/// publish the team config.
struct EnvironmentsView: View {
    let manager: ConnectionManager

    @State private var editing: Draft?
    @State private var suggestions: [EnvConfig] = []
    @State private var publishMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    teamList
                    personalList
                    maintainerSection
                }
                .padding(20)
            }
        }
        .sheet(item: $editing) { draft in
            EnvEditor(manager: manager, draft: draft) { editing = nil }
        }
        .task { suggestions = await manager.discoverEnvironments() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Environments").font(.title2.weight(.semibold))
                Text("\(manager.teamConfig.environments.count) from the team · \(manager.personal.environments.count) of your own")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("New environment…") { editing = Draft(env: blank, target: .personal, original: nil) }
                if manager.isMaintainer {
                    Button("New team environment…") { editing = Draft(env: blank, target: .team, original: nil) }
                }
                if !suggestions.isEmpty {
                    Divider()
                    Section("Found on this Mac") {
                        ForEach(suggestions, id: \.id) { s in
                            Button("\(s.cluster.isEmpty ? s.profile : s.cluster)  ·  \(s.kind == .sso ? "SSO" : "Keycloak") · \(s.region)") {
                                var env = s
                                env.id = EnvID.make(from: s.displayName, taken: Set(manager.config.environments.map(\.id)))
                                editing = Draft(env: env, target: manager.isMaintainer ? .team : .personal, original: nil)
                            }
                        }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
        }
    }

    private var blank: EnvConfig {
        EnvConfig(id: "", kind: manager.keycloakEnvs.isEmpty ? .sso : .keycloak, profile: "", region: "eu-west-1", cluster: "")
    }

    private var teamList: some View {
        SetupGroup(title: manager.isMaintainer ? "Team (you maintain these)" : "Team",
                   caption: manager.isMaintainer ? nil : "managed by your team; hide the ones you don't use") {
            if manager.teamConfig.environments.isEmpty {
                Text("None yet. Join a team in Setup, or add your own below.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.teamConfig.environments) { env in
                let hidden = manager.isHidden(env.id)
                EnvListRow(env: env, faded: hidden, overridden: manager.personal.environments.contains { $0.id == env.id }) {
                    if manager.isMaintainer {
                        Button("Edit") { editing = Draft(env: env, target: .team, original: env.id) }
                    }
                    Button(hidden ? "Show" : "Hide") { manager.setHidden(env.id, !hidden) }
                }
            }
        }
    }

    private var personalList: some View {
        SetupGroup(title: "Your own", caption: "only on this Mac; team updates never touch them") {
            if manager.personal.environments.isEmpty {
                Text("Add a cluster the team config doesn't cover, from Add ▸ Found on this Mac or from scratch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.personal.environments) { env in
                EnvListRow(env: env, faded: false, overridden: manager.teamEnvIDs.contains(env.id)) {
                    Button("Edit") { editing = Draft(env: env, target: .personal, original: env.id) }
                    Button("Delete", role: .destructive) { manager.deletePersonalEnv(env.id) }
                }
            }
        }
    }

    private var maintainerSection: some View {
        SetupGroup(title: "Team maintainer", caption: "for whoever owns the team config") {
            if let source = manager.teamSourceURL, manager.isMaintainer {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.path.replacingOccurrences(of: Paths.home.path, with: "~"))
                            .font(.system(size: 12, design: .monospaced))
                        Text(manager.hasUnpublishedChanges ? "Changes not published yet" : "Published")
                            .font(.caption).foregroundStyle(manager.hasUnpublishedChanges ? .orange : .secondary)
                    }
                    Spacer()
                    if manager.publishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Publish to team") { Task { publishMessage = await manager.publishTeam() } }
                            .disabled(!manager.hasUnpublishedChanges)
                            .help("Encrypts the config and updates the published file. Colleagues get it at their next check.")
                    }
                    Button("Stop") { manager.stopMaintaining() }
                }
                if let publishMessage {
                    Text(publishMessage).font(.caption).foregroundStyle(.red)
                }
            } else {
                HStack {
                    Text("If you maintain your team's config, point the app at its private source file to edit it here and publish it encrypted.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose team source…") { manager.chooseTeamSource() }
                }
            }
        }
    }
}

enum EditTarget: String { case personal, team }

struct Draft: Identifiable {
    var env: EnvConfig
    var target: EditTarget
    var original: String?
    var id: String { (original ?? "new") + target.rawValue }
}

private struct EnvListRow<Actions: View>: View {
    let env: EnvConfig
    let faded: Bool
    let overridden: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: env.kind == .sso ? "person.badge.key" : "key.horizontal")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(env.displayName).font(.system(size: 13, weight: .medium))
                    if env.isProduction { Badge(text: "PROD", color: .red) }
                    if overridden { Badge(text: "overridden", color: .orange) }
                }
                Text([env.kind == .sso ? "AWS SSO" : "Keycloak", env.profile, env.account, env.region,
                      env.cluster.isEmpty ? "no cluster" : env.cluster].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            actions().controlSize(.small)
        }
        .opacity(faded ? 0.45 : 1)
    }
}

private struct EnvEditor: View {
    let manager: ConnectionManager
    @State var draft: Draft
    let done: () -> Void

    @State private var clusters: [String] = []
    @State private var clusterError: String?
    @State private var listing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "New environment" : "Edit \(draft.env.displayName)")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: Binding(get: { draft.env.name ?? "" }, set: { draft.env.name = $0.isEmpty ? nil : $0 }))
                TextField("ID", text: $draft.env.id, prompt: Text("made from the name"))
                Picker("Sign-in", selection: $draft.env.kind) {
                    Text("Keycloak (saml2aws)").tag(EnvKind.keycloak)
                    Text("AWS SSO").tag(EnvKind.sso)
                }
                TextField("AWS profile", text: $draft.env.profile)
                TextField("Region", text: $draft.env.region)
                HStack {
                    TextField("EKS cluster", text: $draft.env.cluster)
                    if listing {
                        ProgressView().controlSize(.small)
                    } else if !clusters.isEmpty {
                        Menu("Pick") { ForEach(clusters, id: \.self) { c in Button(c) { draft.env.cluster = c } } }
                            .fixedSize()
                    } else {
                        Button("List clusters") { Task { await list() } }
                            .disabled(draft.env.profile.isEmpty || draft.env.region.isEmpty)
                            .help("aws eks list-clusters with this profile (needs a live session)")
                    }
                }
                if let clusterError { Text(clusterError).font(.caption).foregroundStyle(.red) }
                TextField("AWS account", text: optional(\.account))
                TextField(draft.env.kind == .sso ? "Permission set (sso_role_name)" : "IAM role name", text: optional(\.role))
                if draft.env.kind == .sso {
                    TextField("SSO session", text: optional(\.ssoSession))
                } else {
                    Toggle("Needs MFA", isOn: Binding(get: { draft.env.usesMFA }, set: { draft.env.mfa = $0 }))
                    Stepper("Session: \(draft.env.sessionDuration / 3600) h",
                            value: Binding(get: { draft.env.sessionDuration / 3600 },
                                           set: { draft.env.sessionDurationSeconds = $0 * 3600 }), in: 1...12)
                }
                TextField("Kube proxy URL", text: optional(\.proxyURL), prompt: Text("optional, e.g. http://proxy:3128"))
                Toggle("Production (confirm before switching)", isOn: Binding(get: { draft.env.isProduction },
                                                                              set: { draft.env.production = $0 ? true : nil }))
                if manager.isMaintainer {
                    Picker("Save to", selection: $draft.target) {
                        Text("My environments").tag(EditTarget.personal)
                        Text("Team config (publish afterwards)").tag(EditTarget.team)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var problem: String? {
        let e = draft.env
        if (e.name ?? "").isEmpty && e.id.isEmpty { return "Give it a name" }
        if e.profile.isEmpty { return "AWS profile is required" }
        if e.cluster.isEmpty { return "EKS cluster is required" }
        if e.kind == .keycloak && (e.account ?? "").isEmpty { return "Keycloak needs the account and role" }
        return nil
    }

    private func optional(_ key: WritableKeyPath<EnvConfig, String?>) -> Binding<String> {
        Binding(get: { draft.env[keyPath: key] ?? "" },
                set: { draft.env[keyPath: key] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    private func list() async {
        listing = true
        defer { listing = false }
        switch await manager.listClusters(profile: draft.env.profile, region: draft.env.region) {
        case .success(let names):
            clusters = names
            clusterError = names.isEmpty ? "No clusters in \(draft.env.region) for this profile" : nil
        case .failure(let error):
            clusterError = error.localizedDescription
        }
    }

    private func save() {
        var env = draft.env
        if env.id.isEmpty {
            let taken = Set(manager.config.environments.map(\.id)).subtracting([draft.original].compactMap { $0 })
            env.id = EnvID.make(from: env.name ?? env.cluster, taken: taken)
        }
        switch draft.target {
        case .personal: manager.savePersonalEnv(env, replacing: draft.original)
        case .team: manager.saveTeamEnv(env, replacing: draft.original)
        }
        done()
    }
}

/// Section container shared with the Setup tab.
struct SetupGroup<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
