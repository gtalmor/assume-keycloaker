import CryptoKit
import Foundation
import Testing
@testable import KeycloakerCore

// All data here is fictional (Example Corp, 111111111111…).

/// The example config shipped in the repo (examples/team.example.json).
func exampleConfig() throws -> AppConfig {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "examples/team.example.json")
    return try AppConfig.decode(Data(contentsOf: url))
}

func sha1Hex(_ s: String) -> String {
    Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Suite struct TOTPTests {
    // RFC 6238 appendix B, SHA1 seed "12345678901234567890".
    let rfc = TOTP(secret: Data("12345678901234567890".utf8), digits: 8)

    @Test(arguments: [
        (59.0, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"),
        (1234567890, "89005924"), (2000000000, "69279037"), (20000000000, "65353130"),
    ])
    func rfcVectors(time: Double, expected: String) {
        #expect(rfc.code(at: Date(timeIntervalSince1970: time)) == expected)
    }

    @Test func sixDigitsIsSuffixOfEight() {
        let six = TOTP(secret: Data("12345678901234567890".utf8))
        #expect(six.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func base32MatchesRawSecret() throws {
        // base32("12345678901234567890")
        let totp = try #require(TOTP(base32: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", digits: 8))
        #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(TOTP(base32: "gezd gnbv gy3t qojq gezd gnbv gy3t qojq") != nil)
        #expect(TOTP(base32: "not*base32") == nil)
    }

    @Test func matchesOathtool() throws {
        // `oathtool --base32 --totp -N @1700000000 JBSWY3DPEHPK3PXP` (dummy seed)
        let totp = try #require(TOTP(base32: "JBSWY3DPEHPK3PXP"))
        #expect(totp.code(at: Date(timeIntervalSince1970: 1_700_000_000)) == "324550")
    }

    @Test func dispenserNeverRepeatsACode() async throws {
        let totp = try #require(TOTP(base32: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", period: 1))
        let dispenser = TOTPDispenser(minRemaining: 0)
        let before = totp.counter(at: Date())
        let a = try await dispenser.nextCode(for: totp)
        let b = try await dispenser.nextCode(for: totp)
        // The second code had to wait for the next window.
        #expect(totp.counter(at: Date()) > before)
        #expect(a.count == 6 && b.count == 6)
    }
}

@Suite struct AWSFileTests {
    let credentials = """
    [saml]
    aws_access_key_id = AKIAEXAMPLE
    aws_secret_access_key = example
    aws_session_token = example
    x_principal_arn          = arn:aws:sts::111111111111:assumed-role/Developer/first.last
    x_security_token_expires = 2030-01-02T00:47:31+02:00
    region                   = eu-west-1
    """

    let config = """
    [profile corp-prod]
    sso_session = corp
    sso_role_name = Operator
    region = eu-west-1
    sso_account_id = 444444444444
    [sso-session corp]
    sso_start_url = https://d-0000000000.awsapps.com/start
    sso_region = eu-west-1
    [profile saml]
    region = eu-west-1
    """

    @Test func samlCredentials() throws {
        let creds = try #require(SAMLCredentials.read(profile: "saml", from: .parse(credentials)))
        #expect(creds.account == "111111111111")
        #expect(creds.role == "Developer")
        #expect(creds.expires == AWSDate.parse("2030-01-01T22:47:31Z"))
        #expect(SAMLCredentials.read(profile: "other", from: .parse(credentials)) == nil)
    }

    @Test func dates() {
        #expect(AWSDate.parse("2030-07-01T15:48:57Z") != nil)
        #expect(AWSDate.parse("2019-11-14T04:04:33UTC") == AWSDate.parse("2019-11-14T04:04:33Z"))
        #expect(AWSDate.parse("2030-07-01T15:48:57.123Z") != nil)
        #expect(AWSDate.parse("nope") == nil)
    }

    @Test func ssoProfileResolvesSessionAndCacheKey() throws {
        let info = try #require(SSOProfileInfo.resolve(profile: "corp-prod", config: .parse(config)))
        #expect(info.sessionName == "corp")
        #expect(info.accountID == "444444444444")
        #expect(info.startURL == "https://d-0000000000.awsapps.com/start")
        // The AWS CLI names ~/.aws/sso/cache files after sha1(sso-session name).
        #expect(info.cacheKey == sha1Hex("corp"))
    }

    @Test func ssoTokenCache() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"startUrl":"x","accessToken":"t","expiresAt":"2030-07-01T15:48:57Z","refreshToken":"r","registrationExpiresAt":"2030-09-09T00:03:13Z"}"#
        try Data(json.utf8).write(to: dir.appending(path: "\(sha1Hex("corp")).json"))
        let info = try #require(SSOProfileInfo.resolve(profile: "corp-prod", config: .parse(config)))
        let token = try #require(info.loadToken(cacheDir: dir))
        #expect(token.hasRefreshToken)
        #expect(token.renewable(now: AWSDate.parse("2030-08-01T00:00:00Z")!))
        #expect(!token.renewable(now: AWSDate.parse("2030-10-01T00:00:00Z")!))
    }

    @Test func kubeconfig() {
        let text = """
        apiVersion: v1
        clusters: []
        current-context: arn:aws:eks:eu-west-1:111111111111:cluster/dev
        kind: Config
        """
        #expect(Kubeconfig.currentContext(in: text) == "arn:aws:eks:eu-west-1:111111111111:cluster/dev")
        #expect(Kubeconfig.currentContext(in: "current-context: \"kind-x\"") == "kind-x")
        #expect(Kubeconfig.currentContext(in: "current-context: ") == nil)
        let eks = Kubeconfig.parseEKS("arn:aws:eks:us-east-1:333333333333:cluster/sandbox-eks")
        #expect(eks == .init(region: "us-east-1", account: "333333333333", cluster: "sandbox-eks"))
        #expect(Kubeconfig.parseEKS("kind-local") == nil)
    }
}

@Suite struct NetworkParserTests {
    @Test func checkPointIdle() {
        let text = """

        Trac connections:

        Conn Username_Example West Gateway:
        \tgw: 192.0.2.10
        \tstatus: Idle
        \tactive site: false

        Conn Smartcard_Example East Gateway:
        \tgw: 198.51.100.20
        \tstatus: Idle
        \tactive site: true
        \tgateway list:
        \t (Idle)\tGW-EAST-01
        """
        let s = CheckPointStatus.parse(text)
        #expect(s.sites.count == 2)
        #expect(!s.isConnected)
        #expect(s.activeSite?.name == "Smartcard_Example East Gateway")
        #expect(s.activeSite?.gateway == "198.51.100.20")
    }

    @Test func checkPointConnected() {
        let s = CheckPointStatus.parse("Conn East:\n\tstatus: Connected\n\tactive site: true\nConn B:\n\tstatus: Disconnected\n")
        #expect(s.isConnected)
        #expect(s.connectedSite?.name == "East")
        #expect(CheckPointStatus.parse("Conn A:\n\tstatus: Connecting\n").connectingSite?.name == "A")
        #expect(!CheckPointStatus.parse("Conn A:\n\tstatus: Connecting\n").isConnected)
    }

    @Test func cardTokens() {
        #expect(SmartCard.isCardToken("com.vendor.CardToken.PKCS11:0123456789ABCDEF", prefix: nil))
        #expect(!SmartCard.isCardToken("com.apple.setoken", prefix: nil))
        #expect(!SmartCard.isCardToken("com.apple.setoken:aks", prefix: nil))
        #expect(SmartCard.isCardToken("com.vendor.x", prefix: "com.vendor."))
        #expect(!SmartCard.isCardToken("com.other.x", prefix: "com.vendor."))
    }

    @Test func zscaler() {
        let routed = "<p>You are accessing the Internet via Zscaler Cloud: <b>Example City I</b> in the zscloud.net cloud.</p>"
        #expect(ZscalerRouting.parse(html: routed) == .routed(cloud: "Example City I"))
        let direct = "The request received from you didn't come from a Zscaler IP therefore you are not going through the Zscaler proxy service."
        #expect(ZscalerRouting.parse(html: direct) == .notRouted)
        #expect(ZscalerRouting.parse(html: "<html>captive portal</html>") == .unknown)
    }
}

@Suite struct ConfigAndShellTests {
    @Test func exampleConfigDecodes() throws {
        let cfg = try exampleConfig()
        let dev = try #require(cfg.env("dev"))
        #expect(dev.roleARN == "arn:aws:iam::111111111111:role/Developer")
        #expect(dev.usesMFA && dev.sessionDuration == 28800)
        #expect(dev.contextName(account: nil) == "arn:aws:eks:eu-west-1:111111111111:cluster/dev")
        #expect(cfg.env("prod")?.isProduction == true)
        #expect(cfg.env("sandbox")?.contextName(account: "333333333333") == "arn:aws:eks:eu-west-1:333333333333:cluster/sandbox-eks")
        #expect(cfg.refreshLead == 15 * 60)
        #expect(cfg.reachability.first?.countsAs == .vpn)
        #expect(cfg.keycloakSettings.idpHost == "sso.example.com")
        #expect(cfg.ssoSession("corp")?.startURL == "https://d-0000000000.awsapps.com/start")
        #expect(!cfg.checkPoint.isEnabled && !cfg.zscaler.isEnabled && !cfg.smartCard.isEnabled)
        #expect(!cfg.kubeLoggerEnabled)
    }

    @Test func integrationsAreOffUnlessConfigured() throws {
        let bare = try AppConfig.decode(Data(#"{"environments":[]}"#.utf8))
        #expect(!bare.checkPoint.isEnabled && !bare.zscaler.isEnabled && !bare.smartCard.isEnabled)
        #expect(bare.keycloakSettings.totpKeychainService == nil)
    }

    @Test func shellStateRoundTrip() throws {
        let env = try #require(try exampleConfig().env("sandbox"))
        let text = ShellState.render(env: env)
        #expect(text.contains("export AWS_PROFILE=corp-sandbox"))
        #expect(text.contains("export AWS_REGION=eu-west-1"))
        #expect(text.contains("unset AWS_ACCESS_KEY_ID"))
        #expect(ShellState.envID(in: text) == "sandbox")
        #expect(ShellState.shellQuote("a b'c") == "'a b'\\''c'")
    }

    @Test func k9sScriptRunsOnTheContext() async throws {
        let env = try #require(try exampleConfig().env("sandbox"))
        let context = "arn:aws:eks:eu-west-1:111122223333:cluster/it's"
        let text = ShellState.k9sScript(env: env, context: context, k9s: "/bin/echo", searchPath: "/usr/bin:/bin")
        #expect(text.hasPrefix("#!/bin/zsh\n"))
        #expect(text.contains("export AWS_PROFILE=corp-sandbox"))
        #expect(text.contains("unset AWS_ACCESS_KEY_ID"))
        let run = try await ProcessRunner().run("/bin/zsh", ["-c", text + "\n"], quiet: true)
        #expect(run.stdout == "--context \(context)\n")
    }

    @Test func processRunnerCapturesOutputAndTimesOut() async throws {
        let runner = ProcessRunner()
        let ok = try await runner.run("/bin/echo", ["hello"], quiet: true)
        #expect(ok.succeeded && ok.stdout == "hello\n")
        let slow = try await runner.run("/bin/sleep", ["5"], timeout: 0.5, quiet: true)
        #expect(slow.timedOut && !slow.succeeded)
        await #expect(throws: ToolError.self) { try await runner.run("definitely-not-a-tool", []) }
    }
}

@Suite struct SetupTests {
    @Test func totpSecretInput() {
        #expect(parseTOTPSecret("JBSWY3DPEHPK3PXP") == "JBSWY3DPEHPK3PXP")
        #expect(parseTOTPSecret(" jbsw y3dp ehpk 3pxp ") == "JBSWY3DPEHPK3PXP")
        #expect(parseTOTPSecret("otpauth://totp/Example:first.last?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=6")
            == "JBSWY3DPEHPK3PXP")
        #expect(parseTOTPSecret("otpauth://totp/x?issuer=y") == nil)
        #expect(parseTOTPSecret("not a secret!") == nil)
    }

    @Test func versions() {
        #expect(Doctor.parseVersion("aws-cli/2.23.10 Python/3.12.8 Darwin/27.2.0 source/arm64") == "2.23.10")
        #expect(Doctor.parseVersion("Client Version: v1.30.2\nKustomize Version: v5.0.4") == "1.30.2")
        #expect(Doctor.parseVersion("2.36.16") == "2.36.16")
        #expect(Doctor.isAtLeast("2.23.10", [2, 9]))
        #expect(!Doctor.isAtLeast("2.8.1", [2, 9]))
        #expect(!Doctor.isAtLeast("1.99", [2, 9]))
        #expect(Doctor.isAtLeast("2.36", [2, 36]))
    }

    @Test func awsProfilesAddsOnlyMissingSections() throws {
        let cfg = try exampleConfig()
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config")
        // One profile present with a different role, the rest missing.
        let existing = "[profile saml]\nregion = eu-west-1\n[profile corp-prod]\nsso_session = corp\nsso_role_name = Other\nsso_account_id = 444444444444\nregion = eu-west-1\n"
        FileManager.default.createFile(atPath: file.path, contents: Data(existing.utf8), attributes: [.posixPermissions: 0o600])

        let before = AWSProfiles.check(config: cfg, ini: INIFile.load(file))
        #expect(before.first { $0.section == "profile corp-prod" }?.status == .mismatch(["sso_role_name"]))
        #expect(before.filter { $0.status == .missing }.count == 2)  // sso-session + sandbox profile

        #expect(try AWSProfiles.addMissing(config: cfg, file: file) == 2)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix(existing))  // existing content untouched
        #expect(text.contains("[sso-session corp]\nsso_start_url = https://d-0000000000.awsapps.com/start"))
        #expect(text.contains("[profile corp-sandbox]\nsso_session = corp\nsso_account_id = 333333333333\nsso_role_name = Engineer"))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(AWSProfiles.check(config: cfg, ini: INIFile.load(file)).filter { $0.status == .missing }.isEmpty)
        #expect(try AWSProfiles.addMissing(config: cfg, file: file) == 0)  // idempotent
    }
}

@Suite struct UpdateTests {
    @Test func versionOrdering() {
        #expect(Version.isNewer("0.2.0", than: "0.1.0"))
        #expect(Version.isNewer("0.10.0", than: "0.9.3"))
        #expect(Version.isNewer("1.0", than: "0.99.99"))
        #expect(!Version.isNewer("0.1.0", than: "0.1"))
        #expect(!Version.isNewer("0.1.0", than: "0.1.0"))
        #expect(!Version.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func caskInfoJSON() {
        // Shape of `brew info --cask --json=v2 <token>`.
        let json = #"{"formulae":[],"casks":[{"token":"assume-keycloaker","version":"0.2.0","installed":"0.1.0","outdated":true}]}"#
        #expect(Brew.parseCaskVersion(json) == "0.2.0")
        #expect(Brew.parseCaskVersion(#"{"casks":[{"version":"1.2.3,45"}]}"#) == "1.2.3")
        #expect(Brew.parseCaskVersion("Error: No available cask") == nil)
    }

    @Test func outdatedJSON() {
        // Shape of `brew outdated --formula --json=v2`.
        let json = #"{"formulae":[{"name":"awscli","installed_versions":["2.23.10"],"current_version":"2.37.4","pinned":false,"pinned_version":null},{"name":"git","installed_versions":["2.40"],"current_version":"2.51","pinned":false,"pinned_version":null}],"casks":[]}"#
        #expect(Brew.parseOutdated(json, names: ["awscli", "saml2aws"]) == ["awscli": "2.37.4"])
        #expect(Brew.shortName("someone/tap/some-tool") == "some-tool")
        #expect(UpdateSettings(tap: "someone/tap").token == "someone/tap/assume-keycloaker")
        #expect(UpdateSettings().token == "assume-keycloaker")
    }

    @Test func caskroomVersion() throws {
        let prefix = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        for v in ["0.9.0", "0.10.0", ".metadata"] {
            try FileManager.default.createDirectory(at: prefix.appending(path: "Caskroom/assume-keycloaker/\(v)"),
                                                    withIntermediateDirectories: true)
        }
        let brew = prefix.appending(path: "bin/brew").path
        #expect(Brew.installedCaskVersion("assume-keycloaker", brew: brew) == "0.10.0")
        #expect(Brew.installedCaskVersion("not-installed", brew: brew) == nil)
    }
}

@Suite struct TeamInviteTests {
    let url = URL(string: "https://example.com/teams/abc123.acx")!

    @Test func codeRoundTripsThroughChatText() throws {
        let invite = TeamInvite(url: url, key: TeamInvite.generateKey())
        #expect(invite.key.count == 32)
        #expect(TeamInvite.parse(invite.code) == invite)
        #expect(TeamInvite.parse(invite.link) == invite)
        #expect(TeamInvite.parse("Hi! Here's the invite: \(invite.code) (internal only)") == invite)
    }

    @Test func rejectsBadInvites() {
        let key = Base64URL.encode(TeamInvite.generateKey())
        let http = "acx1." + Base64URL.encode(Data("http://example.com/x".utf8)) + "." + key
        #expect(TeamInvite.parse(http) == nil)  // https only
        let short = "acx1." + Base64URL.encode(Data(url.absoluteString.utf8)) + "." + Base64URL.encode(Data(repeating: 1, count: 16))
        #expect(TeamInvite.parse(short) == nil)  // 256-bit keys only
        #expect(TeamInvite.parse("hello") == nil)
    }

    @Test func sealOpenAndWrongKey() throws {
        let plain = Data(#"{"environments":[]}"#.utf8)
        let key = TeamInvite.generateKey()
        let sealed = try SealedTeamConfig.seal(plain, key: key)
        #expect(String(decoding: sealed, as: UTF8.self).hasPrefix("assume-keycloaker team config v1\n"))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("environments"))
        #expect(try SealedTeamConfig.open(sealed, key: key) == plain)
        #expect(throws: ToolError.self) { try SealedTeamConfig.open(sealed, key: TeamInvite.generateKey()) }
        var tampered = sealed
        tampered[tampered.count - 6] ^= 0x01
        #expect(throws: ToolError.self) { try SealedTeamConfig.open(tampered, key: key) }
    }
}

@Suite struct EnvironmentManagementTests {
    @Test func personalOverlay() throws {
        let team = try exampleConfig()
        let mine = EnvConfig(id: "lab", name: "my lab", kind: .sso, profile: "corp-lab", region: "eu-west-1", cluster: "lab")
        let override = EnvConfig(id: "dev", name: "dev (mine)", kind: .keycloak, profile: "saml", region: "eu-west-1",
                                 cluster: "dev", account: "111111111111", role: "Admin")
        let merged = team.merging(PersonalConfig(environments: [mine, override], hidden: ["prod"]))
        #expect(merged.env("prod") == nil)                  // hidden
        #expect(merged.env("lab")?.displayName == "my lab") // added
        #expect(merged.env("dev")?.role == "Admin")         // personal wins on id clash
        #expect(merged.environments.filter { $0.id == "dev" }.count == 1)
        #expect(merged.env("staging") != nil)
    }

    @Test func ids() {
        #expect(EnvID.make(from: "My Cluster (EU)", taken: []) == "my-cluster-eu")
        #expect(EnvID.make(from: "dev", taken: ["dev", "dev-2"]) == "dev-3")
        #expect(EnvID.make(from: "!!!", taken: []) == "env")
    }

    @Test func discoveryFromKubeconfig() throws {
        let kube: [String: Any] = [
            "contexts": [
                ["name": "arn:aws:eks:eu-west-1:333333333333:cluster/sandbox-eks",
                 "context": ["user": "arn:aws:eks:eu-west-1:333333333333:cluster/sandbox-eks"]],
                ["name": "arn:aws:eks:us-east-1:222222222222:cluster/staging",
                 "context": ["user": "u2"]],
                ["name": "kind-local", "context": ["user": "kind"]],
            ],
            "users": [
                ["name": "arn:aws:eks:eu-west-1:333333333333:cluster/sandbox-eks",
                 "user": ["exec": ["env": [["name": "AWS_PROFILE", "value": "corp-sandbox"]]]]],
                ["name": "u2", "user": ["exec": ["args": ["eks", "get-token", "--profile", "saml"]]]],
            ],
        ]
        let aws = INIFile.parse("[profile corp-sandbox]\nsso_session = corp\nsso_role_name = Engineer\n[profile saml]\nregion = us-east-1\n")
        let found = Discovery.parseKubeconfig(kube, awsConfig: aws)
        #expect(found.count == 2)  // kind-local is not EKS
        let sandbox = try #require(found.first { $0.cluster == "sandbox-eks" })
        #expect(sandbox.kind == .sso && sandbox.profile == "corp-sandbox" && sandbox.role == "Engineer")
        let staging = try #require(found.first { $0.cluster == "staging" })
        #expect(staging.kind == .keycloak && staging.profile == "saml" && staging.account == "222222222222")
        #expect(Discovery.ssoProfiles(aws).map(\.profile) == ["corp-sandbox"])
    }

    @Test func personalFileRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/personal.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let p = PersonalConfig(environments: [EnvConfig(id: "x", kind: .sso, profile: "p", region: "r", cluster: "c")],
                               hidden: ["y"])
        try p.save(file)
        #expect(PersonalConfig.load(file) == p)
        #expect(PersonalConfig.load(file.appendingPathExtension("missing")) == PersonalConfig())
    }
}

@Suite struct OTPImportTests {
    @Test func base32RoundTrip() {
        let data = Data("12345678901234567890".utf8)
        #expect(Base32.encode(data) == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        #expect(Base32.decode(Base32.encode(Data([1, 2, 3, 4, 5, 6, 7]))) == Data([1, 2, 3, 4, 5, 6, 7]))
    }

    @Test func otpauthURI() throws {
        let e = try #require(OTPAuth.parseAll("otpauth://totp/Example%20SSO:first.last?secret=JBSWY3DPEHPK3PXP&digits=8&algorithm=SHA256&period=60").first)
        #expect(e.issuer == "Example SSO" && e.account == "first.last")
        #expect(e.digits == 8 && e.algorithm == .sha256 && e.period == 60)
        // The canonical URI the app stores keeps every parameter.
        let back = try #require(OTPAuth.parseAll(e.uri).first)
        #expect(back == e)
        #expect(TOTP(stored: e.uri)?.digits == 8)
        #expect(TOTP(stored: "JBSWY3DPEHPK3PXP")?.code(at: Date(timeIntervalSince1970: 1_700_000_000)) == "324550")
    }

    @Test func rfcSHA256AndSHA512() {
        // RFC 6238 appendix B: SHA256 / SHA512 seeds, T = 59, 8 digits.
        let s256 = TOTP(secret: Data("12345678901234567890123456789012".utf8), digits: 8, algorithm: .sha256)
        #expect(s256.code(at: Date(timeIntervalSince1970: 59)) == "46119246")
        let s512 = TOTP(secret: Data("1234567890123456789012345678901234567890123456789012345678901234".utf8), digits: 8, algorithm: .sha512)
        #expect(s512.code(at: Date(timeIntervalSince1970: 59)) == "90693936")
    }

    @Test func googleAuthenticatorExport() throws {
        // MigrationPayload with two entries (fictional), built by hand:
        //  1: secret "12345678901234567890", name "first.last", issuer "Example", SHA1, 6 digits, TOTP
        //  2: an HOTP entry, which is skipped
        func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { [UInt8(n << 3 | 2), UInt8(bytes.count)] + bytes }
        func varint(_ n: Int, _ v: UInt8) -> [UInt8] { [UInt8(n << 3), v] }
        let totp = field(1, Array("12345678901234567890".utf8)) + field(2, Array("first.last".utf8))
            + field(3, Array("Example".utf8)) + varint(4, 1) + varint(5, 1) + varint(6, 2)
        let hotp = field(1, Array("abcdefghij".utf8)) + field(2, Array("counter".utf8)) + varint(6, 1)
        let payload = Data(field(1, totp) + field(1, hotp) + varint(2, 1))
        let link = "otpauth-migration://offline?data=" + payload.base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let entries = OTPAuth.parseAll(link)
        #expect(entries.count == 1)
        #expect(entries.first?.issuer == "Example" && entries.first?.account == "first.last")
        #expect(entries.first?.totp.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func rejectsJunk() {
        #expect(OTPAuth.parseAll("hello").isEmpty)
        #expect(OTPAuth.parseAll("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP").isEmpty)
        #expect(OTPAuth.parseAll("123456").isEmpty)  // a code, not a secret
    }
}

@Suite struct RenameCompatibilityTests {
    @Test func opensTeamConfigSealedBeforeTheRename() throws {
        // Seal exactly like 0.1.x did: old header, which is also the authenticated data.
        let key = TeamInvite.generateKey()
        let plain = Data(#"{"environments":[]}"#.utf8)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), authenticating: Data(Legacy.sealedHeader.utf8))
        let old = Data((Legacy.sealedHeader + box.combined!.base64EncodedString() + "\n").utf8)
        #expect(try SealedTeamConfig.open(old, key: key) == plain)
        // New files use the new header.
        let new = try SealedTeamConfig.seal(plain, key: key)
        #expect(String(decoding: new, as: UTF8.self).hasPrefix("assume-keycloaker team config v1\n"))
    }

    @Test func oldNamesStillWork() {
        #expect(UpdateSettings(cask: "assume-cloaker").caskName == "assume-keycloaker")
        #expect(UpdateSettings().caskName == "assume-keycloaker")
        #expect(ShellState.envID(in: "export CLOAKER_ENV=dev\nexport AWS_PROFILE=saml\n") == "dev")
        let key = Base64URL.encode(TeamInvite.generateKey())
        let url = Base64URL.encode(Data("https://example.com/t.acx".utf8))
        #expect(TeamInvite.parse("assume-cloaker://join?invite=acx1.\(url).\(key)") != nil)
    }
}
