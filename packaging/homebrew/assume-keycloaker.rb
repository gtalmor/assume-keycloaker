# Template for a Homebrew tap (e.g. gtalmor/homebrew-tap/Casks/assume-keycloaker.rb).
# Fill in version/sha256 from `scripts/package.sh` and upload the zip as a release asset.
cask "assume-keycloaker" do
  version "0.1.0"
  sha256 "REPLACE_WITH_dist/AssumeKeycloaker-#{version}.zip.sha256"

  url "https://github.com/gtalmor/assume-keycloaker/releases/download/v#{version}/AssumeKeycloaker-#{version}.zip"
  name "Assume Keycloaker"
  desc "Menu bar app that keeps Keycloak (saml2aws) and AWS SSO sessions alive"
  homepage "https://github.com/gtalmor/assume-keycloaker"

  depends_on macos: :sequoia
  # The CLIs the app drives; Homebrew installs them alongside.
  depends_on formula: ["awscli", "saml2aws", "kubernetes-cli"]

  app "Assume Keycloaker.app"

  postflight_steps do
    # Ad-hoc signed, not notarized: drop the download quarantine so it opens.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Assume Keycloaker.app"]
  end

  uninstall quit: "com.gtalmor.AssumeKeycloaker"

  zap trash: [
    "~/.config/assume-cloaker",
    "~/Library/Logs/AssumeCloaker",
    "~/Library/Preferences/com.gtalmor.AssumeCloaker.plist",
    "~/.config/assume-keycloaker",
    "~/Library/Logs/AssumeKeycloaker",
    "~/Library/Preferences/com.gtalmor.AssumeKeycloaker.plist",
  ]
end
