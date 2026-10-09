# Assume Keycloaker

A macOS menu bar app that keeps your AWS sessions alive like a VPN client: Keycloak sign-ins through
`saml2aws` and AWS IAM Identity Center (SSO). It shows at a glance whether you can actually work
(session time left, VPN, smart card, Zscaler, private endpoints), switches kubectl between your EKS
clusters, and can run [kube-logger](https://github.com/gtalmor/Kube-Logger) for you.

The app is generic. What your team uses (accounts, clusters, identity provider, which checks matter)
comes from a **team config** that is shared encrypted, so nothing about your organisation is public.

## Install

```bash
brew install --cask gtalmor/tap/assume-keycloaker
```

Homebrew also installs the AWS CLI, `saml2aws` and `kubectl`. Open the app; **Settings** opens by itself:

1. **Join your team**: paste the invite you were sent (`acx1.…`, or click an `assume-keycloaker://join?…`
   link). The app downloads your team's encrypted config, keeps the key in your keychain and picks up
   changes automatically.
2. **Tools**: versions of `saml2aws`, AWS CLI v2, `kubectl`; missing or outdated ones install / upgrade with
   one click.
3. **Keycloak account** (if your team uses it): username, password, and MFA. Save your TOTP secret (base32,
   or the `otpauth://` link behind the QR code) for unattended renewals, point at a keychain item you
   already keep it in, or choose "ask me for the code". Everything goes to your login keychain.
4. **AWS SSO profiles**: adds the missing `[sso-session …]` / `[profile …]` sections to `~/.aws/config`
   (after a backup; existing sections are never changed).
5. **VPN & security**: Check Point, smart card and Zscaler are checked when the team config enables them.

No `~/.saml2aws`, shell functions or `.zshrc` changes are needed: saml2aws runs from `SAML2AWS_*`
variables (the password and MFA code never appear on a command line) and the app writes the kubeconfig.

## Using it

- **Click an environment** to connect and make it active: kubectl context (and proxy-url), the shared
  profile's region, and terminals that follow (optional hook). Production environments ask first.
  Right-click the menu bar icon for a quick switcher.
- **Kept alive** (pin): renewed 15 min before expiry, reconnected after sleep or when the network / VPN
  comes back. Without a TOTP secret you get a "click to renew" notification instead.
- **Logs**: with kube-logger enabled, **Start logs** runs `kube-logger-agent` in the background and opens
  your viewer; **Stop** ends it. It keeps streaming while the app restarts for an update.
- **VPN**: **Connect** asks Check Point to connect (it prompts for your card PIN itself). It's disabled while
  the smart card is out; inserting the card with the VPN down offers to connect.

| Light | Meaning |
|---|---|
| Green | Session valid and its requirements (VPN / private endpoint, Zscaler) met |
| Orange | Renewing, expiring soon with auto-renew off, or a check is inconclusive |
| Red | Expired / failed, or a requirement is down |
| Gray | Nothing active / not connected |

## Environments

Settings → **Environments** lists where each environment comes from:

- **Team**: from the team config. Hide the ones you don't use.
- **Your own**: add clusters the team config doesn't cover, from scratch or from **Add ▸ Found on this
  Mac** (your kube contexts and AWS SSO profiles), with **List clusters** to pick the EKS cluster.
  They live in `~/.config/assume-keycloaker/personal.json`, so team updates never touch them.

### Maintaining a team config

The team config is a JSON file (see [`examples/team.example.json`](examples/team.example.json)); keep the
real one private. The maintainer:

```bash
mkdir -p private && cp examples/team.example.json private/team.json   # then edit it
scripts/team-config.sh publish      # encrypt + publish, prints the invite to share internally
```

`publish` encrypts the file (AES-256-GCM) and puts the result at a random path in the tap repo; the key
stays in `private/` and travels only inside invites. `scripts/team-config.sh rotate` makes a new key and
location (old invites stop getting updates). In the app, Environments → **Team maintainer → Choose team
source…** lets you edit team environments there and **Publish to team** with one click (uses `gh`).

| Key | |
|---|---|
| `name` | shown in Setup |
| `keycloak.url`, `provider`, `mfa` | saml2aws IdP settings (`KeyCloak`, `Auto`) |
| `keycloak.syncProfileRegion` | point the shared profile's `region` at the env holding it (default on) |
| `keycloak.totpKeychainService` | a team-wide keychain item name for TOTP seeds, if you have that convention |
| `ssoSessions[]` | `name`, `startURL`, `region` → `[sso-session …]` |
| `environments[]` | `id`, `name`, `kind` (`keycloak`/`sso`), `profile`, `region`, `cluster`, `account`, `role`, `ssoSession`, `mfa`, `sessionDurationSeconds`, `proxyURL`, `production`, `note`, `requires` |
| `network.checkPoint` | `enabled`, `label`, `site`, `tracPath` |
| `network.zscaler`, `network.smartCard` | `enabled` (+ `connectVPNOnInsert`, `tokenPrefix`) |
| `network.reachability[]` | `name`, `host`, `port`, `countsAs: "vpn"` |
| `kubeLogger.enabled` | show the Logs button |
| `updates` | `cask`, `tap`, `checkHours`, `autoInstall` |
| `refreshLeadMinutes`, `warnMinutes`, `confirmProductionSwitch` | 15, 30, true |

Integrations (Check Point, Zscaler, smart card, kube-logger) are off unless the config turns them on.

## Updates

A few seconds after it starts, and then every hour (Settings → Tools & updates: hourly, 6-hourly, daily or
only when asked), the app refreshes its Homebrew tap and compares the cask with itself. A newer version
installs automatically (on by default) or shows an **Update** button: the app quits, runs
`brew upgrade --cask assume-keycloaker` and reopens; sessions carry on. The team config is re-checked hourly.
Once a day a full `brew update` also flags newer versions of the CLIs.

## Shell integration (optional)

Setup → "Add to ~/.zshrc" sources `~/.config/assume-keycloaker/assume-keycloaker.zsh`: every prompt picks up
`AWS_PROFILE`, `AWS_REGION` and `KEYCLOAKER_ENV` of the active environment. `keycloaker_env` shows what a
terminal points at; `keycloaker_pin` / `keycloaker_unpin` stop / resume following. If you have your own login
functions, `assume_keycloaker_wrap my_login keycloak` publishes their result to the app.

## Files

| Path | |
|---|---|
| `~/.config/assume-keycloaker/config.json` | the team config (from the invite) |
| `~/.config/assume-keycloaker/personal.json` | your own / hidden environments |
| `~/.config/assume-keycloaker/current.env` | active env, sourced by the shell hook |
| `~/Library/Logs/AssumeKeycloaker/` | activity, update and kube-logger logs (no secrets) |
| login keychain: `Assume Keycloaker: …` | Keycloak password / TOTP secret, team config key |

## Development

```bash
swift test                      # core: TOTP, parsers, setup, updates, invites, environments
./scripts/build-app.sh --install
scripts/leak-check.sh           # nothing from private/ in the repo or the built app
scripts/release.sh 0.2.0        # dry run; --publish to release + update the cask
```

`scripts/release.sh` runs the leak check first. Its deny list comes from `private/team.json` (accounts,
hosts, URLs, cluster and profile names) plus `private/leak-words.txt`, both git-ignored.

`Sources/KeycloakerCore` holds the logic (config, parsers, TOTP, keychain, checks, invites, connectors);
`Sources/AssumeKeycloaker` is the menu bar item, panel, Setup window and the `ConnectionManager`.
