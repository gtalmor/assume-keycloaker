# Assume Cloaker shell integration (optional).
#
#   source ~/.config/assume-cloaker/assume-cloaker.zsh
#
# - At every prompt, picks up the environment chosen in the menu bar app (or published by another
#   terminal): AWS_PROFILE, AWS_REGION, CLOAKER_ENV. kubectl already follows via the kubeconfig context.
# - cloak_env: what this terminal points at.  cloak_pin / cloak_unpin: stop / resume following.
# - If you have your own login functions, wrap them so terminal logins reach the app and other
#   terminals (and drop static credentials exported by `eval "$(saml2aws script)"`):
#
#     assume_cloaker_wrap my_keycloak_login keycloak
#     assume_cloaker_wrap my_sso_login sso

typeset -g CLOAKER_ENV_FILE="${CLOAKER_ENV_FILE:-$HOME/.config/assume-cloaker/current.env}"
typeset -g _CLOAKER_STAMP=""
typeset -g _CLOAKER_STATIC_CREDS="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION SAML2AWS_PROFILE"

zmodload -F zsh/stat b:zstat 2>/dev/null

_cloaker_sync() {
  [[ -n "$CLOAKER_PIN" || ! -r "$CLOAKER_ENV_FILE" ]] && return 0
  local -a st
  zstat -A st +mtime -- "$CLOAKER_ENV_FILE" 2>/dev/null || return 0
  [[ "$st[1]" == "$_CLOAKER_STAMP" ]] && return 0
  local before="$CLOAKER_ENV"
  _CLOAKER_STAMP="$st[1]"
  source "$CLOAKER_ENV_FILE"
  if [[ -n "$before" && "$before" != "$CLOAKER_ENV" ]]; then
    print -P "%F{8}⇢ env: ${CLOAKER_ENV} (AWS_PROFILE=${AWS_PROFILE})%f"
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _cloaker_sync

# _cloaker_publish <id> <kind> <profile> <region>
_cloaker_publish() {
  local id="$1" kind="$2" profile="$3" region="$4" tmp="${CLOAKER_ENV_FILE}.$$"
  mkdir -p "${CLOAKER_ENV_FILE:h}"
  {
    print -r -- "# Written by a terminal ($kind login). Sourced by assume-cloaker.zsh."
    print -r -- "unset $_CLOAKER_STATIC_CREDS"
    print -r -- "export CLOAKER_ENV=${(q)id}"
    print -r -- "export CLOAKER_ENV_KIND=${(q)kind}"
    print -r -- "export AWS_PROFILE=${(q)profile}"
    print -r -- "export AWS_REGION=${(q)region}"
  } >| "$tmp" && mv -f "$tmp" "$CLOAKER_ENV_FILE" || return
  source "$CLOAKER_ENV_FILE"
  local -a st
  zstat -A st +mtime -- "$CLOAKER_ENV_FILE" 2>/dev/null && _CLOAKER_STAMP="$st[1]"
}

# Publishes whatever EKS context kubectl now points at.
_cloaker_publish_from_kube() {
  local kind="$1" profile="$2" ctx
  ctx=$(kubectl config current-context 2>/dev/null) || return 0
  [[ "$ctx" == arn:aws:eks:* ]] || return 0
  local -a p=("${(@s/:/)ctx}")   # arn aws eks <region> <account> cluster/<name>
  _cloaker_publish "${p[6]#cluster/}" "$kind" "$profile" "${p[4]}"
}

# assume_cloaker_wrap <function> <keycloak|sso>: after the function succeeds, publish the env it
# switched to (from the kube context) and drop static credentials so app renewals apply here too.
assume_cloaker_wrap() {
  local fn="$1" kind="$2"
  (( $+functions[$fn] )) || { print -u2 "assume_cloaker_wrap: no function $fn"; return 1; }
  (( $+functions[_cloaker_orig_$fn] )) && return 0
  functions[_cloaker_orig_$fn]=$functions[$fn]
  functions[$fn]="_cloaker_orig_$fn \"\$@\" || return
    [[ $kind == keycloak ]] && unset \${=_CLOAKER_STATIC_CREDS}
    _cloaker_publish_from_kube $kind \"\${AWS_PROFILE}\""
}

cloak_env() {
  local ctx exp
  ctx=$(kubectl config current-context 2>/dev/null)
  print -r -- "env:      ${CLOAKER_ENV:-?}${CLOAKER_PIN:+ (pinned)}"
  print -r -- "profile:  ${AWS_PROFILE:-?}   region: ${AWS_REGION:-?}"
  print -r -- "kubectl:  ${ctx:-none}"
  exp=$(awk -v p="[${AWS_PROFILE}]" '$0==p{f=1;next} /^\[/{f=0} f && $1=="x_security_token_expires"{print $3}' \
        ~/.aws/credentials 2>/dev/null)
  [[ -n "$exp" ]] && print -r -- "expires:  $exp"
  [[ -n "$AWS_ACCESS_KEY_ID" ]] && print -r -- "warning:  static AWS_ACCESS_KEY_ID in this shell overrides the profile (cloak_unpin clears it)"
  return 0
}

cloak_pin() {
  export CLOAKER_PIN=1
  print -r -- "This terminal stays on ${CLOAKER_ENV:-$AWS_PROFILE}. cloak_unpin to follow Assume Cloaker again."
}

cloak_unpin() {
  unset CLOAKER_PIN
  _CLOAKER_STAMP=""
  _cloaker_sync
  print -r -- "Following Assume Cloaker (${CLOAKER_ENV:-?})."
}
