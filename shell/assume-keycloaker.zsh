# Assume Keycloaker shell integration (optional).
#
#   source ~/.config/assume-keycloaker/assume-keycloaker.zsh
#
# - At every prompt, picks up the environment chosen in the menu bar app (or published by another
#   terminal): AWS_PROFILE, AWS_REGION, KEYCLOAKER_ENV. kubectl already follows via the kubeconfig context.
# - keycloaker_env: what this terminal points at.  keycloaker_pin / keycloaker_unpin: stop / resume following.
# - If you have your own login functions, wrap them so terminal logins reach the app and other
#   terminals (and drop static credentials exported by `eval "$(saml2aws script)"`):
#
#     assume_keycloaker_wrap my_keycloak_login keycloak
#     assume_keycloaker_wrap my_sso_login sso

typeset -g KEYCLOAKER_ENV_FILE="${KEYCLOAKER_ENV_FILE:-$HOME/.config/assume-keycloaker/current.env}"
typeset -g _KEYCLOAKER_STAMP=""
typeset -g _KEYCLOAKER_STATIC_CREDS="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION SAML2AWS_PROFILE"

zmodload -F zsh/stat b:zstat 2>/dev/null

_keycloaker_sync() {
  [[ -n "$KEYCLOAKER_PIN" || ! -r "$KEYCLOAKER_ENV_FILE" ]] && return 0
  local -a st
  zstat -A st +mtime -- "$KEYCLOAKER_ENV_FILE" 2>/dev/null || return 0
  [[ "$st[1]" == "$_KEYCLOAKER_STAMP" ]] && return 0
  local before="$KEYCLOAKER_ENV"
  _KEYCLOAKER_STAMP="$st[1]"
  source "$KEYCLOAKER_ENV_FILE"
  if [[ -n "$before" && "$before" != "$KEYCLOAKER_ENV" ]]; then
    print -P "%F{8}⇢ env: ${KEYCLOAKER_ENV} (AWS_PROFILE=${AWS_PROFILE})%f"
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _keycloaker_sync

# _keycloaker_publish <id> <kind> <profile> <region>
_keycloaker_publish() {
  local id="$1" kind="$2" profile="$3" region="$4" tmp="${KEYCLOAKER_ENV_FILE}.$$"
  mkdir -p "${KEYCLOAKER_ENV_FILE:h}"
  {
    print -r -- "# Written by a terminal ($kind login). Sourced by assume-keycloaker.zsh."
    print -r -- "unset $_KEYCLOAKER_STATIC_CREDS"
    print -r -- "export KEYCLOAKER_ENV=${(q)id}"
    print -r -- "export KEYCLOAKER_ENV_KIND=${(q)kind}"
    print -r -- "export AWS_PROFILE=${(q)profile}"
    print -r -- "export AWS_REGION=${(q)region}"
  } >| "$tmp" && mv -f "$tmp" "$KEYCLOAKER_ENV_FILE" || return
  source "$KEYCLOAKER_ENV_FILE"
  local -a st
  zstat -A st +mtime -- "$KEYCLOAKER_ENV_FILE" 2>/dev/null && _KEYCLOAKER_STAMP="$st[1]"
}

# Publishes whatever EKS context kubectl now points at.
_keycloaker_publish_from_kube() {
  local kind="$1" profile="$2" ctx
  ctx=$(kubectl config current-context 2>/dev/null) || return 0
  [[ "$ctx" == arn:aws:eks:* ]] || return 0
  local -a p=("${(@s/:/)ctx}")   # arn aws eks <region> <account> cluster/<name>
  _keycloaker_publish "${p[6]#cluster/}" "$kind" "$profile" "${p[4]}"
}

# assume_keycloaker_wrap <function> <keycloak|sso>: after the function succeeds, publish the env it
# switched to (from the kube context) and drop static credentials so app renewals apply here too.
assume_keycloaker_wrap() {
  local fn="$1" kind="$2"
  (( $+functions[$fn] )) || { print -u2 "assume_keycloaker_wrap: no function $fn"; return 1; }
  (( $+functions[_keycloaker_orig_$fn] )) && return 0
  functions[_keycloaker_orig_$fn]=$functions[$fn]
  functions[$fn]="_keycloaker_orig_$fn \"\$@\" || return
    [[ $kind == keycloak ]] && unset \${=_KEYCLOAKER_STATIC_CREDS}
    _keycloaker_publish_from_kube $kind \"\${AWS_PROFILE}\""
}

keycloaker_env() {
  local ctx exp
  ctx=$(kubectl config current-context 2>/dev/null)
  print -r -- "env:      ${KEYCLOAKER_ENV:-?}${KEYCLOAKER_PIN:+ (pinned)}"
  print -r -- "profile:  ${AWS_PROFILE:-?}   region: ${AWS_REGION:-?}"
  print -r -- "kubectl:  ${ctx:-none}"
  exp=$(awk -v p="[${AWS_PROFILE}]" '$0==p{f=1;next} /^\[/{f=0} f && $1=="x_security_token_expires"{print $3}' \
        ~/.aws/credentials 2>/dev/null)
  [[ -n "$exp" ]] && print -r -- "expires:  $exp"
  [[ -n "$AWS_ACCESS_KEY_ID" ]] && print -r -- "warning:  static AWS_ACCESS_KEY_ID in this shell overrides the profile (keycloaker_unpin clears it)"
  return 0
}

keycloaker_pin() {
  export KEYCLOAKER_PIN=1
  print -r -- "This terminal stays on ${KEYCLOAKER_ENV:-$AWS_PROFILE}. keycloaker_unpin to follow Assume Keycloaker again."
}

keycloaker_unpin() {
  unset KEYCLOAKER_PIN
  _KEYCLOAKER_STAMP=""
  _keycloaker_sync
  print -r -- "Following Assume Keycloaker (${KEYCLOAKER_ENV:-?})."
}
