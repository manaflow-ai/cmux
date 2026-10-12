# cmux Cloud devbox agent sign-in mode (/etc/cmux/agent-auth.sh). POSIX sh:
# sourced by the claude launcher (/etc/cmux/claude) at every launch and by
# the in-VM `cr use` command to report the mode.
#
# Each agent on a machine runs in one of two modes:
#   team  the team's CodeRouter accounts, through the machine's TLS edge
#         (zero setup; the launcher adds the model-plane env)
#   own   the user's own sign-in to the agent (Claude Code: /login); the
#         launcher adds no CodeRouter env, so nothing outranks that login
#
# CMUX_<AGENT>_AUTH=team|own in the environment pins one launch (automation,
# image verification). Otherwise the choice lives in
# ~/.config/cmux/agent-auth/<agent> ("team" or "own"), written by `cr use`.
# Without one, an own sign-in on the machine counts as
# choosing own; otherwise team when the team has a usable account, else own,
# so Claude Code shows its normal sign-in instead of a CodeRouter refusal.
#
# Only claude reads this today; the file layout and the resolve function are
# keyed by agent so codex can adopt the same switch.

# The file holding <agent>'s explicit choice.
cmux_agent_auth_file() {
  printf '%s/.config/cmux/agent-auth/%s' "${HOME:-/root}" "$1"
}

# Prints <agent>'s explicit choice (team or own), or nothing.
cmux_agent_auth_choice() {
  cmux_aa_file=$(cmux_agent_auth_file "$1")
  [ -f "$cmux_aa_file" ] || return 0
  cmux_aa_value=$(head -n 1 "$cmux_aa_file" 2>/dev/null | tr -d '[:space:]')
  case "$cmux_aa_value" in team|own) printf '%s' "$cmux_aa_value" ;; esac
}

# 0 when Claude Code has its own sign-in on this machine: a /login session in
# its credentials file, or a long-lived token from `claude setup-token`.
cmux_claude_has_own_login() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN-}" ] && return 0
  cmux_aa_credentials="${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}/.credentials.json"
  [ -f "$cmux_aa_credentials" ] && grep -q '"claudeAiOauth"' "$cmux_aa_credentials" 2>/dev/null
}

# The team's CodeRouter Claude accounts as this machine sees them:
# 0 at least one active account, 1 the answer lists none, 2 no answer
# (no model plane, edge unreachable, unreadable reply).
cmux_claude_team_upstream() {
  cmux_aa_origin="${CMUX_CODEROUTER_URL-}"
  case "$cmux_aa_origin" in https://*) ;; *) return 2 ;; esac
  cmux_aa_key="${CMUX_CLAUDE_TEAM_API_KEY:-${ANTHROPIC_API_KEY:-${OPENAI_API_KEY-}}}"
  [ -n "$cmux_aa_key" ] || return 2
  command -v curl >/dev/null 2>&1 || return 2
  set -- -fsS --connect-timeout 2 --max-time 5 -H "authorization: Bearer $cmux_aa_key" -H 'accept: application/json'
  if [ -f /usr/local/share/ca-certificates/freestyle-tls.crt ]; then
    set -- "$@" --cacert /usr/local/share/ca-certificates/freestyle-tls.crt
  fi
  cmux_aa_body=$(curl "$@" "${cmux_aa_origin%/}/api/coderouter/claude-upstream" 2>/dev/null) || return 2
  printf '%s' "$cmux_aa_body" | python3 -c '
import json, sys
try:
    accounts = json.load(sys.stdin)["accounts"]
    assert isinstance(accounts, list)
except Exception:
    sys.exit(2)
sys.exit(0 if any(isinstance(a, dict) and a.get("state") == "active" for a in accounts) else 1)
' 2>/dev/null
}

# Sets cmux_agent_auth_mode (team|own) and cmux_agent_auth_reason:
#   env             CMUX_<AGENT>_AUTH pins this launch
#   chosen          `cr use` recorded the mode
#   login           no choice; the agent has its own sign-in here
#   team-account    no choice or sign-in; the team has a usable account
#   no-team-account no choice or sign-in; the team has none
#   team-unknown    no choice or sign-in; the account check got no answer,
#                   so the long-standing default (team) applies
cmux_agent_auth_resolve() {
  eval "cmux_agent_auth_mode=\${CMUX_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_AUTH-}"
  case "$cmux_agent_auth_mode" in
    team|own) cmux_agent_auth_reason=env; return 0 ;;
  esac
  cmux_agent_auth_mode=$(cmux_agent_auth_choice "$1")
  if [ -n "$cmux_agent_auth_mode" ]; then
    cmux_agent_auth_reason=chosen
    return 0
  fi
  case "$1" in
    claude)
      if cmux_claude_has_own_login; then
        cmux_agent_auth_mode=own
        cmux_agent_auth_reason=login
        return 0
      fi
      if cmux_claude_team_upstream; then cmux_aa_rc=0; else cmux_aa_rc=$?; fi
      ;;
    *) cmux_aa_rc=2 ;;
  esac
  case "$cmux_aa_rc" in
    0) cmux_agent_auth_mode=team; cmux_agent_auth_reason=team-account ;;
    1) cmux_agent_auth_mode=own; cmux_agent_auth_reason=no-team-account ;;
    *) cmux_agent_auth_mode=team; cmux_agent_auth_reason=team-unknown ;;
  esac
}

# Shapes the environment of a claude launch for its mode. team: the
# model-plane pair agent-config.sh set aside, unless the user exported their
# own ANTHROPIC_BASE_URL/ANTHROPIC_API_KEY (those always win). own: no
# CodeRouter env at all, including the usage headers, which name the cmux
# workspace and terminal and mean nothing to any other endpoint.
cmux_claude_apply_auth_mode() {
  cmux_agent_auth_resolve claude
  if [ "$cmux_agent_auth_mode" = team ]; then
    if [ -z "${ANTHROPIC_BASE_URL-}" ] && [ -z "${ANTHROPIC_API_KEY-}" ] && [ -n "${CMUX_CLAUDE_TEAM_BASE_URL-}" ]; then
      ANTHROPIC_BASE_URL=$CMUX_CLAUDE_TEAM_BASE_URL
      ANTHROPIC_API_KEY=${CMUX_CLAUDE_TEAM_API_KEY-}
      export ANTHROPIC_BASE_URL ANTHROPIC_API_KEY
    fi
    return 0
  fi
  # A shell from an older agent-config.sh still exports the pair; drop it
  # only when it is the model plane's, never a user-set endpoint or key.
  if [ -n "${ANTHROPIC_BASE_URL-}" ] && { [ "$ANTHROPIC_BASE_URL" = "${CMUX_CLAUDE_TEAM_BASE_URL-}" ] || [ "$ANTHROPIC_BASE_URL" = "${CMUX_CODEROUTER_URL-}" ]; }; then
    unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY
  fi
  if [ -n "${ANTHROPIC_CUSTOM_HEADERS-}" ] && ! printf '%s\n' "$ANTHROPIC_CUSTOM_HEADERS" | grep -qv '^x-cmux-'; then
    unset ANTHROPIC_CUSTOM_HEADERS
  fi
}
