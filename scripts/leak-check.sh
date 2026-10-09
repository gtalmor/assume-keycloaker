#!/bin/zsh
# Fails if anything team-specific shows up in the public repo or the built app.
# The deny list comes from private/ (never committed): every account id, host, URL, cluster, profile
# and name in private/team.json, plus extra words in private/leak-words.txt (one per line).
set -euo pipefail
cd "${0:A:h}/.."

TERMS=$(mktemp)
trap 'rm -f "$TERMS"' EXIT
if [[ -f private/team.json ]]; then
  python3 -I - private/team.json >> "$TERMS" <<'PY'
import json, re, sys
from urllib.parse import urlparse
d = json.load(open(sys.argv[1]))
out = set()
def walk(v, key=""):
    if isinstance(v, dict):
        for k, x in v.items(): walk(x, k)
    elif isinstance(v, list):
        for x in v: walk(x, key)
    elif isinstance(v, str):
        if re.fullmatch(r"\d{12}", v): out.add(v)                          # account ids
        elif v.startswith(("http://", "https://")):
            out.add(v); out.add(urlparse(v).hostname or "")                 # URLs and their hosts
        elif key in ("host", "profile", "cluster", "name", "label", "startURL", "ssoSession") and len(v) >= 4:
            out.add(v)                                                      # names specific to the team
walk(d)
# Generic values (vendor URLs, common names) that the public app may contain.
generic = {"saml", "demo", "Developer", "KeyCloak", "Keycloak", "Auto", "development", "staging", "production",
           "https://ip.zscaler.com", "ip.zscaler.com", "assume-keycloaker"}
for t in sorted(out - generic):
    if t: print(t)
PY
fi
[[ -f private/leak-words.txt ]] && grep -v -E '^\s*(#|$)' private/leak-words.txt >> "$TERMS"
[[ -s "$TERMS" ]] || { echo "leak-check: no private/team.json or private/leak-words.txt, nothing to check against"; exit 0; }

FILES=$(mktemp)
trap 'rm -f "$TERMS" "$FILES"' EXIT
if git rev-parse --git-dir >/dev/null 2>&1; then
  git ls-files --cached --others --exclude-standard > "$FILES"
else
  find . -type f -not -path './private/*' -not -path './.build/*' -not -path './build/*' -not -path './dist/*' \
    -not -path './.git/*' -not -name '.DS_Store' | sed 's|^\./||' > "$FILES"
fi

found=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if hits=$(grep -a -n -i -F -f "$TERMS" -- "$f" 2>/dev/null); then
    echo "$hits" | head -3 | sed "s|^|LEAK $f:|"; found=1
  fi
done < "$FILES"

# The built app (binary strings + resources), if there is one.
APP="build/Assume Keycloaker.app"
if [[ -d "$APP" ]]; then
  while IFS= read -r f; do
    if strings -a "$f" 2>/dev/null | grep -i -F -q -f "$TERMS"; then
      echo "LEAK in built app: ${f#build/}: $(strings -a "$f" | grep -i -F -o -f "$TERMS" | sort -u | head -3 | tr '\n' ' ')"; found=1
    fi
  done < <(find "$APP" -type f)
fi

if (( found )); then echo "leak-check: FAILED (remove the lines above or move them to private/)"; exit 1; fi
echo "leak-check: clean ($(wc -l < "$TERMS" | tr -d ' ') terms, $(wc -l < "$FILES" | tr -d ' ') files${APP:+ + app})"
