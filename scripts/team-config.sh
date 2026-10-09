#!/bin/zsh
# The team config, published encrypted. Only people holding the invite can read it.
#
#   scripts/team-config.sh publish   encrypt private/team.json, push it to $TAP_REPO as teams/<id>.acx,
#                                    print the invite (share it on internal channels only)
#   scripts/team-config.sh invite    print the invite again
#   scripts/team-config.sh rotate    new key + location; then `publish` and share the new invite.
#                                    Old invites stop receiving updates.
#   scripts/team-config.sh check     decrypt what's published and compare with private/team.json
#
# Everything secret stays in private/ (git-ignored): team.json, team.key, team.id.
set -euo pipefail
cd "${0:A:h}/.."

TAP_REPO="${TAP_REPO:-gtalmor/homebrew-tap}"
SRC="${TEAM_SOURCE:-private/team.json}"
KEY=private/team.key
ID_FILE=private/team.id
BIN="build/Assume Cloaker.app/Contents/MacOS/AssumeCloaker"

umask 077
mkdir -p private
[[ -x "$BIN" ]] || ./scripts/build-app.sh >/dev/null
[[ -f "$KEY" ]] || "$BIN" team keygen > "$KEY"
[[ -f "$ID_FILE" ]] || openssl rand -hex 16 > "$ID_FILE"
ID=$(<"$ID_FILE")
URL="https://raw.githubusercontent.com/$TAP_REPO/main/teams/$ID.acx"

case "${1:-}" in
  publish)
    "$BIN" team seal "$SRC" "private/$ID.acx" --key-file "$KEY"
    TMP=$(mktemp -d)
    gh repo clone "$TAP_REPO" "$TMP/tap" -- --depth 1 --quiet
    git -C "$TMP/tap" rm -q --ignore-unmatch 'teams/*.acx'
    mkdir -p "$TMP/tap/teams"
    cp "private/$ID.acx" "$TMP/tap/teams/$ID.acx"
    git -C "$TMP/tap" add teams
    git -C "$TMP/tap" commit -q -m "Update team config" || echo "(no change)"
    git -C "$TMP/tap" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q
    echo "Published. Invite (share internally only):"
    "$BIN" team invite "$URL" --key-file "$KEY"
    ;;
  invite)
    "$BIN" team invite "$URL" --key-file "$KEY"
    ;;
  rotate)
    mv "$KEY" "$KEY.old"; "$BIN" team keygen > "$KEY"
    openssl rand -hex 16 > "$ID_FILE"
    echo "New key and location. Run: scripts/team-config.sh publish, then share the new invite."
    ;;
  check)
    curl -fsSL "$URL" -o "private/published.acx"
    "$BIN" team open private/published.acx --key-file "$KEY" | diff -q - "$SRC" && echo "Published config matches $SRC"
    ;;
  *)
    sed -n '2,12p' "$0"; exit 1
    ;;
esac
