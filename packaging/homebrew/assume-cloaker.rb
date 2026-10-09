# Template for a Homebrew tap (e.g. gtalmor/homebrew-tap/Casks/assume-cloaker.rb).
# Fill in version/sha256 from `scripts/package.sh` and upload the zip as a release asset.
cask "assume-cloaker" do
  version "0.1.0"
  sha256 "REPLACE_WITH_dist/AssumeCloaker-#{version}.zip.sha256"

  url "https://github.com/gtalmor/assume-cloaker/releases/download/v#{version}/AssumeCloaker-#{version}.zip"
  name "Assume Cloaker"
  desc "Menu bar app that keeps Keycloak (saml2aws) and AWS SSO sessions alive"
  homepage "https://github.com/gtalmor/assume-cloaker"

  depends_on macos: :sequoia
  # The CLIs the app drives; Homebrew installs them alongside.
  depends_on formula: ["awscli", "saml2aws", "kubernetes-cli"]

  app "Assume Cloaker.app"

  postflight_steps do
    # Ad-hoc signed, not notarized: drop the download quarantine so it opens.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Assume Cloaker.app"]
  end

  uninstall quit: "com.gtalmor.AssumeCloaker"

  zap trash: [
    "~/.config/assume-cloaker",
    "~/Library/Logs/AssumeCloaker",
    "~/Library/Preferences/com.gtalmor.AssumeCloaker.plist",
  ]
end
