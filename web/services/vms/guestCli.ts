// The in-VM `cmux` CLI: a POSIX shim over the machine's own cmux-tui binary.
//
// Every cmux Cloud machine runs the cmux-tui daemon (session "cloud"). This
// adapter keeps the shared cmux command family while mapping local resource
// commands to cmux-tui and cloud/agent commands to the machine's TLS edge.
// `cmux vm …` talks to OTHER machines through cmux-remote links the Mac
// granted with `cmux vm link <src> <dst>` (peer route files in ~/.cmux/peers).
// The adapter is provider-agnostic: it needs only the daemon binary, route
// files, and the standard CodeRouter environment; no provider SDK or Stack
// credential is copied into the guest.
//
// Beyond the transport verbs it carries the agent primitives that must mean
// the same thing on the Mac and inside a machine: `layout export|apply` (a
// workspace as the declarative document `cmux new-workspace --layout` and
// `cmux layout open` accept), `env set|ls|rm` (the machine env every cmux
// shell and agent sources), and the Mac's terminal verbs (`send`, `send-key`,
// `read-screen`, `terminal send|read|wait|close`) — locally and toward
// linked peers (`cmux vm <verb> <peer> …`). The Mac's `cmux vm layout|env …`
// run these same functions over `vm exec`, so there is one implementation.
// `env receive` and `file receive` are the receiving ends of the link-typed
// handshakes (`cmux vm env set`, `cmux vm push --secret` / peer `vm push`);
// `vm agent … --wait --output` turns a peer's durable agent terminal into a
// blocking call with the agent's exit code and stream.
//
// Reflection (`cmux whoami`, `cmux reflect`, peer discovery) reads the control
// plane's `/api/vm/reflection/*` through the model-plane alias: the edge injects
// the machine's VM-bound route token, so the machine learns who it is without
// holding any credential — exe.dev's Reflection integration is the model.
//
// Installed by the driver at create/heal (see freestyle.ts bootstrap), so it
// reaches machines created from any existing snapshot. This driver-installed
// adapter is the sole source; image bakes keep their promoted CLI until healing.

import { GUEST_CMUX_MESSAGE_SHELL } from "./guestCliMessages";
import { GUEST_CMUX_TOPOLOGY_SHELL } from "./guestTopologyCli";

export const GUEST_CMUX_SHIM_PATH = "/usr/local/bin/cmux";

export const GUEST_CMUX_SHIM = `#!/bin/sh
# cmux — in-VM CLI. One grammar, the same as on a Mac:
#   cmux <verb> …               THIS machine's session (cmux-tui, session "cloud")
#   cmux vm <verb> <machine> …  ANOTHER machine of the same owner, over a peer link
#   cmux vm ls                  the owner's machines, this one marked *
#   cmux self [<path>]          who am I (reflection; aliases whoami, reflect)
set -eu

${GUEST_CMUX_MESSAGE_SHELL}

# The daemon binary lives under the daemon's home, which depends on the image
# layout (root daemon: /root; layout-aware bakes: the cmux user's home or the
# persistent-volume backing path, with /usr/local/bin/cmux-tui symlinked to it).
# Try the stable symlink first, then every known home.
cmux_tui_default() {
  for candidate in /usr/local/bin/cmux-tui /root/.cmux/bin/cmux-tui "\${HOME:-/root}/.cmux/bin/cmux-tui" \\
    /home/cmux/.cmux/bin/cmux-tui /cmux/home/.cmux/bin/cmux-tui; do
    if [ -x "\$candidate" ]; then printf '%s' "\$candidate"; return 0; fi
  done
  command -v cmux-tui 2>/dev/null || printf '%s' /root/.cmux/bin/cmux-tui
}
CMUX_TUI_BIN="\${CMUX_TUI_BIN:-\$(cmux_tui_default)}"
CMUX_GUEST_HOME="\${CMUX_GUEST_HOME:-\${HOME:-/root}/.cmux}"
PEERS_DIR="\$CMUX_GUEST_HOME/peers"
LINKS_DIR="\$CMUX_GUEST_HOME/peer-links"
LOCAL_SESSION="\${CMUX_TUI_SESSION:-cloud}"
# Session names are user input when the shim is reused outside the baked image.
# Keep them in the JSON/status output safe and deterministic.
case "\$LOCAL_SESSION" in
  ''|*[!A-Za-z0-9._-]*) LOCAL_SESSION=cloud ;;
esac

die() { printf '%s\\n' "cmux: \$1" >&2; exit "\${2:-1}"; }
die_message() {
  cmux_error_status="\$1"; shift
  printf 'cmux: ' >&2
  cmux_message "\$@" >&2
  exit "\$cmux_error_status"
}
# A warning never changes the exit code; \`layout apply\` also collects them for
# its JSON summary (cmux_la_scratch is set only while an apply is running).
warn() {
  printf '%s\\n' "cmux: warning: \$1" >&2
  if [ -n "\${cmux_la_scratch:-}" ] && [ -d "\$cmux_la_scratch" ]; then printf '%s\\n' "\$1" >> "\$cmux_la_scratch/warnings"; fi
  return 0
}

# Identity, discovery, and help come from the control plane or this file, so
# they answer while cmux-tui is still installing (the bootstrap shim's
# contract); every other verb needs the daemon.
case "\${1:-}:\${2:-}:\${3:-}" in
  vm:workspace:help|vm:workspace:--help|vm:workspace:-h|vm:pane:help|vm:pane:--help|vm:pane:-h|vm:tab:help|vm:tab:--help|vm:tab:-h)
    cmux_message topologyHelp; exit 0 ;;
  vm:terminal:help|vm:terminal:--help|vm:terminal:-h)
    cmux_message terminalHelp; exit 0 ;;
esac
case "\${1:-}:\${2:-}" in
  workspace:help|workspace:--help|workspace:-h|workspace:|pane:help|pane:--help|pane:-h|pane:|tab:help|tab:--help|tab:-h|tab:|terminal:help|terminal:--help|terminal:-h) ;;
  self:*|whoami:*|reflect:*|reflection:*|vm:ls|vm:list|vm:peers|vm:links|vm:help|vm:--help|vm:-h|vm:|:*|help:*|--help:*|-h:*|--version:*|-V:*) ;;
  *) [ -x "\$CMUX_TUI_BIN" ] || die_message 1 missingDaemon "\$CMUX_TUI_BIN" ;;
esac

# One routing target for every verb: this machine's session, or — after
# use_peer — a linked peer's headless-link socket. tui() prepends it, so the
# same functions (terminal, layout, env, workspace) serve both without a copy.
TARGET_FLAG=--session
TARGET_VALUE="\$LOCAL_SESSION"
TARGET_LABEL=local
tui() { "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" "\$@"; }
use_peer() {
  cmux_peer_sock="\$(ensure_link "\$1")"
  TARGET_FLAG=--socket
  TARGET_VALUE="\$cmux_peer_sock"
  TARGET_LABEL="\$1"
}

guest_usage() {
  cmux_message help
}

load_model_env() {
  if [ -f "\$HOME/.config/cmux/model-plane.env" ]; then
    . "\$HOME/.config/cmux/model-plane.env"
  elif [ -f /etc/cmux/model-plane.env ]; then
    . /etc/cmux/model-plane.env
  fi
  # A route token is an edge-held capability, never a guest credential. Refuse
  # a manually copied token instead of making it look like the supported path.
  for cmux_value in "\${OPENAI_API_KEY:-}" "\${ANTHROPIC_API_KEY:-}" "\${CMUX_CODEROUTER_URL:-}"; do
    case "\$cmux_value" in
      *crt_*) die_message 2 routeToken ;;
    esac
  done
}

load_agent_config() {
  load_model_env
  if [ -f /etc/cmux/agent-config.sh ]; then
    . /etc/cmux/agent-config.sh
  fi
  # The machine env (\`cmux env set\`) reaches agents started through this shim
  # even when the calling shell predates the ~/.profile hook.
  if [ -f "\$HOME/.config/cmux/env" ]; then
    . "\$HOME/.config/cmux/env"
  fi
}

cmux_curl() {
  command -v curl >/dev/null 2>&1 || return 127
  if [ -f /usr/local/share/ca-certificates/freestyle-tls.crt ]; then
    curl --cacert /usr/local/share/ca-certificates/freestyle-tls.crt "\$@"
  else
    curl "\$@"
  fi
}

require_coderouter() {
  load_model_env
  cmux_coderouter_url="\${CMUX_CODEROUTER_URL:-}"
  [ -n "\$cmux_coderouter_url" ] || die_message 2 missingCodeRouter
  case "\$cmux_coderouter_url" in
    https://*) ;;
    *) die_message 2 insecureCodeRouter ;;
  esac
  case "\$cmux_coderouter_url" in
    *[!A-Za-z0-9:/._-]*)
      die_message 2 invalidCodeRouter ;;
  esac
  cmux_coderouter_key="\${OPENAI_API_KEY:-cmux-vm-edge-placeholder}"
}

# ---------------------------------------------------------------------------
# Reflection: what this machine is and what it can reach, answered by the
# control plane over the model-plane alias. The edge injects the machine's
# VM-bound route token on the way (the guest never holds it), so every answer
# is about THIS machine and nothing else. exe.dev's Reflection integration is
# the model: \`cmux whoami\`, \`cmux reflect [path]\`, and peer discovery for
# \`cmux vm …\` all read it.
# ---------------------------------------------------------------------------
# reflection_fetch <path> <out-file>: writes the body to <out-file>; sets
# cmux_rf_status (HTTP code, 000 = unreachable) and cmux_rf_base. Returns 0 on
# 2xx, 1 on any other answer, 2 when no model-plane alias is configured. Never
# exits: callers decide how loud to be. Runs in the caller's shell so the
# status survives (no subshell).
reflection_fetch() {
  cmux_rf_status=000
  cmux_rf_base=""
  load_model_env
  cmux_rf_url="\${CMUX_CODEROUTER_URL:-}"
  [ -n "\$cmux_rf_url" ] || return 2
  case "\$cmux_rf_url" in https://*) ;; *) return 2 ;; esac
  cmux_rf_base="\${cmux_rf_url%/}/api/vm/reflection"
  cmux_rf_path="\${1:-/}"
  case "\$cmux_rf_path" in /*) ;; *) cmux_rf_path="/\$cmux_rf_path" ;; esac
  # The canonical form carries no trailing slash (Next redirects '/x/' to '/x',
  # and a redirect is not an answer): the index is the bare base URL.
  while [ "\${cmux_rf_path%/}" != "\$cmux_rf_path" ]; do cmux_rf_path="\${cmux_rf_path%/}"; done
  reflection_fetch_url "\$cmux_rf_base\$cmux_rf_path" "\$2"
}

# reflection_fetch_url <url> <out-file>: one GET through the edge. The status
# rides stdout as the last line (curl --write-out), the way the image's
# bootstrap shim reads it, so both shims see the same edge the same way.
reflection_fetch_url() {
  cmux_rf_out="\$2"
  : > "\$cmux_rf_out"
  cmux_rf_raw="\$(cmux_curl -sSL --connect-timeout 5 --max-time 20 \\
    -H "authorization: Bearer \${OPENAI_API_KEY:-cmux-vm-edge-placeholder}" -H 'accept: application/json' \\
    --write-out '\\n%{http_code}' "\$1" 2>/dev/null)" || :
  cmux_rf_status="\$(printf '%s' "\$cmux_rf_raw" | tail -n 1)"
  case "\$cmux_rf_status" in ''|*[!0-9]*) cmux_rf_status=000; return 1 ;; esac
  printf '%s' "\$cmux_rf_raw" | sed '\$d' > "\$cmux_rf_out"
  case "\$cmux_rf_status" in 2[0-9][0-9]) return 0 ;; esac
  return 1
}

# One line saying why reflection did not answer: <base-url> <body-file>.
reflection_failure() {
  case "\$cmux_rf_status" in
    000) cmux_message reflectionUnreachable "\$1" ;;
    401|403) cmux_message reflectionNoIdentity "\$cmux_rf_status" ;;
    *) cmux_message reflectionError "\$cmux_rf_status" "\$(jq -r '.message // .error // empty' "\$2" 2>/dev/null || true)" ;;
  esac
}

# Print a JSON body followed by exactly one newline.
reflection_print() {
  cat "\$1"
  if [ -n "\$(tail -c 1 "\$1" 2>/dev/null)" ]; then printf '\\n'; fi
}

# self_fetch <out-file>: the identity index. Reflection's "/" is the whole
# picture (owner, plan, the owner's machines with routes); a control plane that
# answers 404 there still serves GET /api/vm/self (machine, team, machines), so
# \`cmux self\` and \`cmux vm ls\` read the same either way. Returns as
# reflection_fetch; cmux_sf_source is reflection or self.
self_fetch() {
  cmux_sf_source=reflection
  reflection_fetch / "\$1" && return 0
  cmux_sf_rc=\$?
  [ "\$cmux_sf_rc" -ne 2 ] || return 2
  [ "\$cmux_rf_status" = 404 ] || return 1
  cmux_sf_source=self
  cmux_rf_base="\${CMUX_CODEROUTER_URL%/}/api/vm/self"
  reflection_fetch_url "\$cmux_rf_base" "\$1"
}

# self_machines <index-file>: make sure the index carries machines[] (the
# owner's machines, this one flagged self). A reflection server from before the
# superset has none; its /peers plus the index itself give the same list.
self_machines() {
  if jq -e '(.machines | type) == "array"' "\$1" >/dev/null 2>&1; then return 0; fi
  [ "\$cmux_sf_source" = reflection ] || return 0
  cmux_sm_peers="\$(mktemp "\${TMPDIR:-/tmp}/cmux-peers.XXXXXX")"
  if reflection_fetch /peers "\$cmux_sm_peers"; then
    jq --slurpfile peers "\$cmux_sm_peers" '. + {machines: (
        [{id: (.provider_vm_id // .vm_id), vmId: .vm_id, name: (.display_name // .name), displayName: .display_name, slug: .name,
          status: .status, createdAt: .created_at, self: true, route: null, reachable: false}]
        + [(\$peers[0].peers // [])[] | {id: (.provider_vm_id // .vm_id), vmId: .vm_id, name: (.display_name // .name), displayName: .display_name,
          slug: .name, status: .status, self: false, route: .route, reachable: (.reachable // (.route != null)), network: .network}])}' \\
      "\$1" > "\$1.machines" 2>/dev/null && mv "\$1.machines" "\$1" || rm -f "\$1.machines"
  fi
  rm -f "\$cmux_sm_peers"
  return 0
}

# The human index: the lines main's \`cmux self\` prints, from either source.
self_human() {
  jq -r --arg self "\$(cmux_message thisMachine)" --arg team "\$(cmux_message labelTeam)" \\
    --arg machines "\$(cmux_message labelMachines)" --arg owner "\$(cmux_message labelOwner)" --arg plan "\$(cmux_message labelPlan)" '
    (.machine.name // .display_name // .name // "?") as \$name
    | (.machine.id // .provider_vm_id // .vm_id // "?") as \$id
    | (.machine.status // .status // "unknown") as \$status
    | (.team.id // .team_id // null) as \$team_id
    | (if (.machines | type) == "array" then "\\t\\(.machines | length) \\(\$machines)" else "" end) as \$count
    | (.owner.email // .owner.user_id // null) as \$owner_id
    | (.plan_id // null) as \$plan_id
    | ["\\(\$name)\\t\\(\$id)\\t\\(\$status)\\t\\(\$self)"]
      + (if \$team_id != null then ["\\(\$team)\\t\\(\$team_id)\\(\$count)"] else [] end)
      + (if \$owner_id != null then ["\\(\$owner)\\t\\(\$owner_id)"] else [] end)
      + (if \$plan_id != null then ["\\(\$plan)\\t\\(\$plan_id)"] else [] end)
    | .[]' "\$1"
}

# cmux self [<path>] [--json]: who am I, as the control plane knows it (the
# edge asserts the identity; nothing here is a credential). <path> is any
# reflection path: peers, integrations, owner, machine. whoami and reflect are
# aliases of this verb.
guest_self() {
  cmux_self_json=0
  cmux_self_path=""
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) cmux_self_json=1 ;;
      --help|-h) cmux_message selfHelp; return 0 ;;
      -*) die "self: unknown option \$cmux_arg" 2 ;;
      *) [ -z "\$cmux_self_path" ] || die "self: one path at most (cmux self peers)" 2; cmux_self_path="\$cmux_arg" ;;
    esac
  done
  case "\$cmux_self_path" in *[!A-Za-z0-9/_.-]*) die "self: path must look like peers or /peers" 2 ;; esac
  while [ "\${cmux_self_path%/}" != "\$cmux_self_path" ]; do cmux_self_path="\${cmux_self_path%/}"; done
  cmux_self_path="\${cmux_self_path#/}"
  cmux_self_out="\$(mktemp "\${TMPDIR:-/tmp}/cmux-self.XXXXXX")"
  if [ -z "\$cmux_self_path" ]; then
    self_fetch "\$cmux_self_out" && cmux_self_rc=0 || cmux_self_rc=\$?
  else
    reflection_fetch "\$cmux_self_path" "\$cmux_self_out" && cmux_self_rc=0 || cmux_self_rc=\$?
  fi
  if [ "\$cmux_self_rc" -eq 2 ]; then rm -f "\$cmux_self_out"; die_message 2 missingCodeRouter; fi
  if [ "\$cmux_self_rc" -ne 0 ]; then
    cmux_self_why="\$(reflection_failure "\$cmux_rf_base" "\$cmux_self_out")"
    rm -f "\$cmux_self_out"
    die "\$cmux_self_why" 1
  fi
  if [ "\$cmux_self_json" -eq 1 ] || [ -n "\$cmux_self_path" ]; then
    reflection_print "\$cmux_self_out"
  elif ! self_human "\$cmux_self_out" 2>/dev/null; then
    rm -f "\$cmux_self_out"
    die_message 1 reflectionInvalid
  fi
  rm -f "\$cmux_self_out"
}

# cmux vm ls [--json]: the owner's machines from the same index, this one
# marked *. Reachability is the control plane's word (a private-network route
# exists); linked/connected is this machine's own peer-link state.
guest_vm_ls() {
  cmux_ls_json=0
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) cmux_ls_json=1 ;;
      --help|-h) peer_usage; return 0 ;;
      *) die "usage: cmux vm ls [--json]" 2 ;;
    esac
  done
  cmux_ls_out="\$(mktemp "\${TMPDIR:-/tmp}/cmux-ls.XXXXXX")"
  self_fetch "\$cmux_ls_out" && cmux_ls_rc=0 || cmux_ls_rc=\$?
  if [ "\$cmux_ls_rc" -eq 2 ]; then rm -f "\$cmux_ls_out"; die_message 2 missingCodeRouter; fi
  if [ "\$cmux_ls_rc" -ne 0 ]; then
    cmux_ls_why="\$(reflection_failure "\$cmux_rf_base" "\$cmux_ls_out")"
    rm -f "\$cmux_ls_out"
    die "\$cmux_ls_why" 1
  fi
  self_machines "\$cmux_ls_out"
  if ! jq -e '(.machines | type) == "array"' "\$cmux_ls_out" >/dev/null 2>&1; then
    rm -f "\$cmux_ls_out"
    die_message 1 reflectionInvalid
  fi
  if [ "\$cmux_ls_json" -eq 1 ]; then
    jq -c '{machines: .machines}' "\$cmux_ls_out"
    rm -f "\$cmux_ls_out"
    return 0
  fi
  cmux_ls_tab="\$(printf '\\t')"
  # "-" stands for an empty field: a tab is IFS whitespace, so empty fields would not survive read.
  jq -r --arg self "\$(cmux_message thisMachine)" '.machines[]
    | [ (if .self then "*" else "-" end), (.name // "?"), (.id // .provider_vm_id // "?"), (.status // "unknown"),
        (if .self then \$self elif .reachable == true then "reachable" elif .reachable == false then "unreachable" else "-" end),
        (.displayName // "-"), (.slug // "-"), (.vmId // "-") ]
    | @tsv' "\$cmux_ls_out" | while IFS="\$cmux_ls_tab" read -r cmux_ls_mark cmux_ls_name cmux_ls_id cmux_ls_status cmux_ls_reach cmux_ls_display cmux_ls_slug cmux_ls_vmid; do
    cmux_ls_link=""
    if [ "\$cmux_ls_mark" != "*" ]; then
      cmux_ls_mark=" "
      for cmux_ls_key in "\$cmux_ls_name" "\$cmux_ls_display" "\$cmux_ls_slug" "\$cmux_ls_vmid" "\$cmux_ls_id"; do
        [ "\$cmux_ls_key" != "-" ] || continue
        [ -f "\$PEERS_DIR/\$cmux_ls_key.json" ] || continue
        cmux_ls_link=linked
        if [ -f "\$LINKS_DIR/\$cmux_ls_key.pid" ] && kill -0 "\$(cat "\$LINKS_DIR/\$cmux_ls_key.pid")" 2>/dev/null; then cmux_ls_link=connected; fi
        break
      done
    fi
    printf '%s %s\\t%s\\t%s' "\$cmux_ls_mark" "\$cmux_ls_name" "\$cmux_ls_id" "\$cmux_ls_status"
    [ "\$cmux_ls_reach" = "-" ] || printf '\\t%s' "\$cmux_ls_reach"
    [ -z "\$cmux_ls_link" ] || printf '\\t%s' "\$cmux_ls_link"
    printf '\\n'
  done
  rm -f "\$cmux_ls_out"
}

# When ~/.cmux/peers/<peer>.json is missing, ask reflection for the owner's
# other machines: a match on name, display name, cloud id, or provider id gives
# the private-network route, which is all the daemon's trusted-carrier listener
# needs on current images. Writes the peer file (0600) and returns 0; returns 1
# with cmux_rd_reason set otherwise (no Mac step is invented here).
reflection_discover_peer() {
  cmux_rd_peer="\$1"
  cmux_rd_reason=""
  cmux_rd_out="\$(mktemp "\${TMPDIR:-/tmp}/cmux-peers.XXXXXX")"
  if reflection_fetch /peers "\$cmux_rd_out"; then :; else
    cmux_rd_rc=\$?
    if [ "\$cmux_rd_rc" -eq 2 ]; then
      cmux_rd_reason="\$(cmux_message reflectionUnconfigured)"
    else
      cmux_rd_reason="\$(reflection_failure "\$cmux_rf_base" "\$cmux_rd_out")"
    fi
    rm -f "\$cmux_rd_out"
    return 1
  fi
  cmux_rd_match="\$(jq -c --arg p "\$cmux_rd_peer" '[.peers // [] | .[] | select(.name == \$p or .display_name == \$p or .vm_id == \$p or .provider_vm_id == \$p)] | .[0] // empty' "\$cmux_rd_out" 2>/dev/null || true)"
  if [ -z "\$cmux_rd_match" ]; then
    cmux_rd_names="\$(jq -r '[.peers // [] | .[] | .name] | join(", ")' "\$cmux_rd_out" 2>/dev/null || true)"
    [ -n "\$cmux_rd_names" ] || cmux_rd_names="\$(cmux_message noPeers)"
    cmux_rd_reason="\$(cmux_message peerUnknown "\$cmux_rd_names")"
    rm -f "\$cmux_rd_out"
    return 1
  fi
  rm -f "\$cmux_rd_out"
  cmux_rd_route="\$(printf '%s' "\$cmux_rd_match" | jq -r '.route // empty')"
  if [ -z "\$cmux_rd_route" ]; then
    cmux_rd_reason="\$(cmux_message peerUnreachable "\$cmux_rd_peer")"
    return 1
  fi
  mkdir -p "\$PEERS_DIR"
  ( umask 077; printf '%s' "\$cmux_rd_match" | jq '{route: .route, name: .name, vm_id: .vm_id, provider_vm_id: .provider_vm_id, source: "reflection"}' > "\$(peer_file "\$cmux_rd_peer")" )
  return 0
}

guest_auth_status() {
  cmux_auth_json=0
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) cmux_auth_json=1 ;;
      --help|-h) guest_usage; return 0 ;;
      *) die_message 2 authOption "\$cmux_arg" ;;
    esac
  done
  load_model_env
  cmux_daemon_running=0
  if "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" server status >/dev/null 2>&1; then
    cmux_daemon_running=1
  fi
  cmux_model_configured=0
  cmux_tls_reachable=0
  cmux_route_auth=not_configured
  cmux_edge_status=000
  if [ -n "\${CMUX_CODEROUTER_URL:-}" ]; then
    cmux_model_configured=1
    case "\$CMUX_CODEROUTER_URL" in
      https://*)
        if cmux_edge_status="\$(cmux_curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 \\
          -H "authorization: Bearer \${OPENAI_API_KEY:-cmux-vm-edge-placeholder}" \\
          "\${CMUX_CODEROUTER_URL%/}/api/coderouter/vm-usage/self" 2>/dev/null)"; then :; else :; fi
        case "\$cmux_edge_status" in
          200) cmux_tls_reachable=1; cmux_route_auth=accepted ;;
          401|403) cmux_tls_reachable=1; cmux_route_auth=rejected ;;
          000|'') cmux_edge_status=000; cmux_route_auth=unreachable ;;
          *[!0-9]*) cmux_edge_status=000; cmux_route_auth=unreachable ;;
          *) cmux_tls_reachable=1; cmux_route_auth=unknown ;;
        esac
        ;;
      *) cmux_route_auth=insecure_url ;;
    esac
  fi
  cmux_authenticated=0
  cmux_daemon_authenticated=0
  if [ "\$cmux_daemon_running" -eq 1 ]; then
    cmux_daemon_authenticated=1
    [ "\$cmux_model_configured" -eq 1 ] && [ "\$cmux_route_auth" = accepted ] && cmux_authenticated=1
  fi
  cmux_daemon_bool=false
  cmux_daemon_auth_bool=false
  cmux_model_bool=false
  cmux_tls_bool=false
  # Identity: what the control plane says this machine IS (reflection). It
  # needs the same edge-injected route token the CodeRouter check needs, so a
  # missing alias or a rejected route explains an absent identity too.
  cmux_identity_json=null
  cmux_identity_line=""
  if [ "\$cmux_model_configured" -eq 1 ]; then
    cmux_id_out="\$(mktemp "\${TMPDIR:-/tmp}/cmux-identity.XXXXXX")"
    if reflection_fetch / "\$cmux_id_out"; then
      cmux_id_json="\$(jq -c '{vm_id: (.vm_id // null), name: (.name // null)} | select(.vm_id != null)' "\$cmux_id_out" 2>/dev/null || true)"
      if [ -n "\$cmux_id_json" ]; then
        cmux_identity_json="\$cmux_id_json"
        cmux_identity_line="\$(cmux_message identityLine "\$(printf '%s' "\$cmux_id_json" | jq -r '.name // "?"')" "\$(printf '%s' "\$cmux_id_json" | jq -r '.vm_id')")"
      else
        cmux_identity_line="\$(cmux_message identityUnavailable "\$(cmux_message reflectionInvalid)")"
      fi
    else
      cmux_identity_line="\$(cmux_message identityUnavailable "\$(reflection_failure "\$cmux_rf_base" "\$cmux_id_out")")"
    fi
    rm -f "\$cmux_id_out"
  else
    cmux_identity_line="\$(cmux_message identityUnavailable "\$(cmux_message reflectionUnconfigured)")"
  fi
  cmux_authenticated_bool=false
  [ "\$cmux_daemon_running" -eq 1 ] && cmux_daemon_bool=true
  [ "\$cmux_daemon_authenticated" -eq 1 ] && cmux_daemon_auth_bool=true
  [ "\$cmux_model_configured" -eq 1 ] && cmux_model_bool=true
  [ "\$cmux_tls_reachable" -eq 1 ] && cmux_tls_bool=true
  [ "\$cmux_authenticated" -eq 1 ] && cmux_authenticated_bool=true
  if [ "\$cmux_auth_json" -eq 1 ]; then
    printf '{"authenticated":%s,"daemon":{"running":%s,"authenticated":%s,"session":"%s"},"tls":{"reachable":%s},"coderouter":{"configured":%s,"route_authenticated":"%s","http_status":"%s"},"identity":%s,"control_plane":"host-only"}\\n' \\
      "\$cmux_authenticated_bool" "\$cmux_daemon_bool" "\$cmux_daemon_auth_bool" "\$LOCAL_SESSION" \\
      "\$cmux_tls_bool" "\$cmux_model_bool" "\$cmux_route_auth" "\$cmux_edge_status" "\$cmux_identity_json"
  else
    if [ "\$cmux_daemon_running" -eq 1 ]; then
      cmux_message daemonRunning "\$LOCAL_SESSION"
    else
      cmux_message daemonUnavailable "\$LOCAL_SESSION"
    fi
    if [ "\$cmux_authenticated" -eq 1 ]; then
      cmux_message authReady
    else
      cmux_message authIncomplete
    fi
    if [ "\$cmux_model_configured" -eq 0 ]; then
      cmux_message codeRouterUnconfigured
    elif [ "\$cmux_route_auth" = accepted ]; then
      cmux_message codeRouterReady "\$cmux_edge_status"
    elif [ "\$cmux_route_auth" = rejected ]; then
      cmux_message codeRouterRejected "\$cmux_edge_status"
    elif [ "\$cmux_route_auth" = insecure_url ]; then
      cmux_message codeRouterInsecure
    elif [ "\$cmux_route_auth" = unknown ]; then
      cmux_message codeRouterIndeterminate "\$cmux_edge_status"
    else
      cmux_message codeRouterUnreachable
    fi
    printf '%s\\n' "\$cmux_identity_line"
    cmux_message hostTokens
  fi
  [ "\$cmux_daemon_running" -eq 1 ] || return 1
  [ "\$cmux_authenticated" -eq 1 ] || return 1
}

# The readout of GET /api/coderouter/vm-usage/self. One text default that a
# person and an agent both read (stable \`label  value\` lines, one row per day
# with usage, a bar per row, colour only on a terminal); \`--json\` returns the
# contract unchanged (vmUsageContract.ts); \`--tsv\` is the day table alone.
# Without jq the raw body is printed, so an older image never loses it.
# Exit codes: 0 shown, 1 edge did not answer, 2 bad option, 3 ledger unavailable.

# usage_epoch <iso8601>: seconds since the epoch, GNU date first (the guest),
# BSD date second (a Mac running the tests); empty when neither parses it.
usage_epoch() {
  date -u -d "\$1" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%S' "\${1%%.*}" +%s 2>/dev/null
}

# usage_asof_text <iso8601>: "as of 2 min ago, 23:24 UTC"; only the absolute
# time when the age cannot be computed. CMUX_NOW_EPOCH pins "now" for tests.
usage_asof_text() {
  cmux_ua_abs="\$(printf '%s' "\$1" | sed -e 's/T/ /' -e 's/:[0-9][0-9]\\(\\.[0-9]*\\)\\{0,1\\}Z\$/ UTC/')"
  cmux_ua_then="\$(usage_epoch "\$1" || true)"
  cmux_ua_now="\${CMUX_NOW_EPOCH:-\$(date -u +%s)}"
  if [ -n "\$cmux_ua_then" ] && [ "\$cmux_ua_now" -ge "\$cmux_ua_then" ] 2>/dev/null; then
    cmux_ua_age=\$(( (cmux_ua_now - cmux_ua_then) / 60 ))
    if [ "\$cmux_ua_age" -lt 60 ]; then cmux_ua_rel="\$(cmux_message usageAgoMinutes "\$cmux_ua_age")"
    elif [ "\$cmux_ua_age" -lt 1440 ]; then cmux_ua_rel="\$(cmux_message usageAgoHours "\$((cmux_ua_age / 60))")"
    else cmux_ua_rel="\$(cmux_message usageAgoDays "\$((cmux_ua_age / 1440))")"; fi
    cmux_message usageAsOf "\$(cmux_message usageAgo "\$cmux_ua_rel" "\$cmux_ua_abs")"
  else
    cmux_message usageAsOf "\$cmux_ua_abs"
  fi
}

# usage_tsv <file> <days>: day, tokens, api_equivalent_usd, zeros included.
usage_tsv() {
  printf 'day\\ttokens\\tapi_equivalent_usd\\n'
  jq -r --argjson days "\$2" '(.days // []) | .[-\$days:] | .[] | [.day, (.totalTokens // 0), (.apiEquivalentUsd // 0)] | @tsv' "\$1"
}

guest_coderouter_usage_render() {
  cmux_cu_file="\$1"
  cmux_cu_days="\$2"
  if ! jq -e . "\$cmux_cu_file" >/dev/null 2>&1; then cat "\$cmux_cu_file"; return 0; fi
  if jq -e '.kind == "unavailable"' "\$cmux_cu_file" >/dev/null 2>&1; then
    cmux_message usageUnavailable
    return 3
  fi
  # Anything that is not the ready contract (an error body, a future shape,
  # a non-numeric field) is passed through untouched rather than formatted.
  if ! jq -e '.kind == "ready" and (.totals | type) == "object" and (.periodDays | type) == "number" and (.asOf | type) == "string"
      and ([.totals.inputTokens, .totals.cachedInputTokens, .totals.outputTokens, .totals.totalTokens, .totals.apiEquivalentUsd] | all(type == "number"))
      and ((.days // []) | type) == "array"
      and ((.days // []) | all((.day | type) == "string" and (.totalTokens | type) == "number" and (.apiEquivalentUsd | type) == "number"))' \\
      "\$cmux_cu_file" >/dev/null 2>&1; then
    cat "\$cmux_cu_file"
    return 0
  fi
  if [ "\$cmux_cu_format" = tsv ]; then usage_tsv "\$cmux_cu_file" "\$cmux_cu_days"; return 0; fi
  eval "\$(jq -r '@sh "cmux_cu_period=\\(.periodDays // 30) cmux_cu_asof=\\(.asOf // "?") cmux_cu_name=\\(.displayName // .vmId // "?") cmux_cu_total=\\(.totals.totalTokens // 0)"' "\$cmux_cu_file")"
  # Workspace ids come from the ledger; their names live in this machine's
  # cmux-tui. Best effort: no daemon, or an old one, leaves the ids visible.
  # Ids are never shown: named (live) workspaces print by name, the rest fold
  # into one "closed workspaces" entry, and when the lookup itself fails the
  # workspace line is dropped rather than printed as ids.
  cmux_cu_names='{}'
  cmux_cu_names_ok=false
  if [ -x "\$CMUX_TUI_BIN" ]; then
    cmux_cu_names="\$("\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" workspace list --json 2>/dev/null \\
      | jq -c '[.workspaces[]? | select(.id != null and .name != null) | {key: .id, value: .name}] | from_entries' 2>/dev/null || true)"
    case "\$cmux_cu_names" in '{'*) cmux_cu_names_ok=true ;; *) cmux_cu_names='{}' ;; esac
  fi
  cmux_cu_bold=""; cmux_cu_dim=""; cmux_cu_reset=""
  if [ -t 1 ] && [ -z "\${NO_COLOR:-}" ]; then
    cmux_cu_bold="\$(printf '\\033[1m')"; cmux_cu_dim="\$(printf '\\033[2m')"; cmux_cu_reset="\$(printf '\\033[0m')"
  fi
  printf '%s%s%s\\n' "\$cmux_cu_bold" "\$(cmux_message usageTitle "\$cmux_cu_name" "\$cmux_cu_period" "\$(usage_asof_text "\$cmux_cu_asof")")" "\$cmux_cu_reset"
  jq -r --argjson days "\$cmux_cu_days" \\
    --arg bold "\$cmux_cu_bold" --arg dim "\$cmux_cu_dim" --arg reset "\$cmux_cu_reset" \\
    --arg machine "\$(cmux_message labelMachine)" --arg tokens "\$(cmux_message labelTokens)" \\
    --arg cost "\$(cmux_message labelCost)" --arg trend "\$(cmux_message labelTrend)" --arg day "\$(cmux_message labelDay)" \\
    --arg total "\$(cmux_message labelTotal)" --arg input "\$(cmux_message labelInput)" --arg cached "\$(cmux_message labelCached)" \\
    --arg output "\$(cmux_message labelOutput)" --arg api "\$(cmux_message labelApiEquivalent)" \\
    --arg costNote "\$(cmux_message usageCostNote)" --arg costUnpriced "\$(cmux_message usageCostUnpriced)" \\
    --arg trendTpl "\$(cmux_message usageTrend "%1" "%2")" --argjson names "\$cmux_cu_names" \\
    --arg workspace "\$(cmux_message labelWorkspace)" --arg agentLabel "\$(cmux_message labelAgent)" --arg model "\$(cmux_message labelModel)" \\
    --arg noWorkspace "\$(cmux_message usageNoWorkspace)" --arg closedWorkspaces "\$(cmux_message usageClosedWorkspaces)" \\
    --argjson namesOk "\$cmux_cu_names_ok" --arg moreTpl "\$(cmux_message usageMore "%1")" '
    def commas: tostring | (length - 1) as \$n
      | [range(0; length) as \$i | .[\$i:\$i+1] + (if (\$n - \$i) > 0 and ((\$n - \$i) % 3 == 0) then "," else "" end)] | join("");
    def whole: (. // 0) | floor | commas;
    def usd: (. // 0) as \$v | ((\$v * 100) | round) as \$c
      | if \$v > 0 and \$c == 0 then "<\$0.01"
        else "\$" + ((\$c / 100 | floor) | commas) + "." + ((\$c % 100) | tostring | if length < 2 then "0" + . else . end) end;
    def lpad(\$w): tostring | if length >= \$w then . else (" " * (\$w - length)) + . end;
    def rpad(\$w): tostring | if length >= \$w then . else . + (" " * (\$w - length)) end;
    def bar(\$max): if . <= 0 or \$max <= 0 then "" else ((. * 12 / \$max) | ceil | if . < 1 then 1 else . end) as \$n | ("█" * \$n) end;
    def share(\$all): if \$all > 0 then " (\\((. * 100 / \$all) | round)%)" else "" end;
    def section(\$label; \$items; \$lw; \$total): if (\$items | length) == 0 then empty else
        "\\(\$label | rpad(\$lw))  " + ([\$items[:5][] | "\\(.name) \\(.totals.totalTokens | whole)\\(.totals.totalTokens | share(\$total))"] | join("   "))
        + (if (\$items | length) > 5 then "   \\(\$dim)\\(\$moreTpl | sub("%1"; ((\$items | length) - 5 | tostring)))\\(\$reset)" else "" end) end;
    .totals as \$t
    | (.workspaces // []) as \$rawWs
    | (\$rawWs | map(select(.workspaceId != null and \$names[.workspaceId] != null) | {name: \$names[.workspaceId], totals})) as \$namedWs
    | (\$rawWs | map(select(.workspaceId != null and \$names[.workspaceId] == null))) as \$unnamedWs
    | (\$rawWs | map(select(.workspaceId == null) | {name: \$noWorkspace, totals})) as \$outsideWs
    | (if (\$unnamedWs | length) > 0 and (\$namesOk | not) then []
       else (\$namedWs + \$outsideWs
             + (if (\$unnamedWs | length) > 0 then [{name: \$closedWorkspaces, totals: {totalTokens: (\$unnamedWs | map(.totals.totalTokens) | add)}}] else [] end))
            | sort_by(-.totals.totalTokens) end) as \$ws
    | ((.agents // []) | map({name: .agent, totals})) as \$ag
    | ((.models // []) | map({name: .model, totals})) as \$md
    | (.days // []) as \$all
    | ([\$machine, \$tokens, \$cost] + (if (\$all | length) >= 8 then [\$trend] else [] end)
        + (if (\$ws | length) > 0 then [\$workspace] else [] end) + (if (\$ag | length) > 0 then [\$agentLabel] else [] end)
        + (if (\$md | length) > 0 then [\$model] else [] end) | map(length) | max) as \$lw
    | (\$all | .[-\$days:]) as \$window
    | (\$window | map(select((.totalTokens // 0) > 0))) as \$rows
    | (\$all | .[-7:] | map(.totalTokens // 0) | add // 0) as \$last7
    | (\$all | .[-14:-7] | map(.totalTokens // 0) | add // 0) as \$prior7
    | (\$rows | map(.totalTokens) | max // 0) as \$max
    | "\\(\$machine | rpad(\$lw))  \\(.displayName // .vmId // "?")\\(if .displayName != null then "  \\(\$dim)\\(.vmId)\\(\$reset)" else "" end)",
      "\\(\$tokens | rpad(\$lw))  \\(\$bold)\\(\$t.totalTokens | whole)\\(\$reset) \\(\$total) = \\(\$t.inputTokens | whole) \\(\$input) (\\(\$t.cachedInputTokens | whole) \\(\$cached)) + \\(\$t.outputTokens | whole) \\(\$output)",
      "\\(\$cost | rpad(\$lw))  \\(\$t.apiEquivalentUsd | usd) \\(\$api)  \\(\$dim)(\\(if \$t.totalTokens > 0 and \$t.apiEquivalentUsd == 0 then \$costUnpriced else \$costNote end))\\(\$reset)",
      (if (\$all | length) >= 8 then "\\(\$trend | rpad(\$lw))  \\(\$trendTpl | sub("%1"; (\$last7 | commas)) | sub("%2"; (\$prior7 | commas)))" else empty end),
      section(\$workspace; \$ws; \$lw; \$t.totalTokens), section(\$agentLabel; \$ag; \$lw; \$t.totalTokens), section(\$model; \$md; \$lw; \$t.totalTokens),
      (if (\$rows | length) > 0 then
        ([\$rows[].totalTokens | whole | length] + [(\$tokens | length)] | max) as \$tw
        | ([\$rows[].apiEquivalentUsd | usd | length] + [(\$cost | length)] | max) as \$cw
        | "",
          "\\(\$dim)\\(\$day | rpad(10))  \\(\$tokens | lpad(\$tw))  \\(\$cost | lpad(\$cw))\\(\$reset)",
          (\$rows[] | "\\(.day | rpad(10))  \\(.totalTokens | whole | lpad(\$tw))  \\(.apiEquivalentUsd | usd | lpad(\$cw))  \\(.totalTokens | bar(\$max))")
      else empty end),
      "@omitted \\((\$window | length) - (\$rows | length)) \\(\$window | length)"
  ' "\$cmux_cu_file" | while IFS= read -r cmux_cu_line; do
    case "\$cmux_cu_line" in
      "@omitted "*)
        set -- \$cmux_cu_line
        if [ "\$cmux_cu_total" -eq 0 ] 2>/dev/null; then
          printf '\\n'; cmux_message usageNone "\$cmux_cu_period"
        elif [ "\$2" -gt 0 ] 2>/dev/null; then
          printf '%s' "\$cmux_cu_dim"; cmux_message usageOmitted "\$2" "\$3"; printf '%s' "\$cmux_cu_reset"
        fi
        ;;
      *) printf '%s\\n' "\$cmux_cu_line" ;;
    esac
  done
  printf '\\n%s' "\$cmux_cu_dim"
  cmux_message usageJsonHint
  cmux_message usageTeamHint "https://cmux.com/dashboard/coderouter"
  printf '%s' "\$cmux_cu_reset"
}

guest_coderouter_usage() {
  cmux_cu_format=text
  cmux_cu_days=30
  [ "\${CMUX_OUTPUT:-}" != json ] || cmux_cu_format=json
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --json) cmux_cu_format=json ;;
      --tsv) cmux_cu_format=tsv ;;
      --days)
        shift
        case "\${1:-}" in
          ''|*[!0-9]*) die_message 2 usageDays "\${1:-}" ;;
        esac
        [ "\$1" -ge 1 ] && [ "\$1" -le 30 ] || die_message 2 usageDays "\$1"
        cmux_cu_days="\$1"
        ;;
      --days=*)
        cmux_cu_days="\${1#--days=}"
        case "\$cmux_cu_days" in ''|*[!0-9]*) die_message 2 usageDays "\$cmux_cu_days" ;; esac
        [ "\$cmux_cu_days" -ge 1 ] && [ "\$cmux_cu_days" -le 30 ] || die_message 2 usageDays "\$cmux_cu_days"
        ;;
      --help|-h) cmux_message usageHelp; return 0 ;;
      *) die_message 2 usageOption "\$1" ;;
    esac
    shift
  done
  require_coderouter
  cmux_response="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \\
    -H "authorization: Bearer \$cmux_coderouter_key" \\
    "\${cmux_coderouter_url%/}/api/coderouter/vm-usage/self" 2>&1)" || {
    printf '%s\\n' "\$cmux_response" >&2
    return 1
  }
  if [ "\$cmux_cu_format" = json ] || ! command -v jq >/dev/null 2>&1; then
    printf '%s\\n' "\$cmux_response"
    if [ "\$cmux_cu_format" = json ] && command -v jq >/dev/null 2>&1 \\
      && printf '%s' "\$cmux_response" | jq -e '.kind == "unavailable"' >/dev/null 2>&1; then return 3; fi
    return 0
  fi
  cmux_cu_out="\$(mktemp "\${TMPDIR:-/tmp}/cmux-usage.XXXXXX")"
  printf '%s\\n' "\$cmux_response" > "\$cmux_cu_out"
  cmux_cu_rc=0
  guest_coderouter_usage_render "\$cmux_cu_out" "\$cmux_cu_days" || cmux_cu_rc=\$?
  rm -f "\$cmux_cu_out"
  return "\$cmux_cu_rc"
}

guest_coderouter_models() {
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) ;;
      --help|-h) guest_usage; return 0 ;;
      *) die_message 2 modelsOption "\$cmux_arg" ;;
    esac
  done
  require_coderouter
  cmux_response="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \\
    -H "authorization: Bearer \$cmux_coderouter_key" -H "accept: application/json" \\
    "\${cmux_coderouter_url%/}/v1/models" 2>&1)" || {
    printf '%s\\n' "\$cmux_response" >&2
    return 1
  }
  printf '%s\\n' "\$cmux_response"
}

# Run the agent in this terminal; with --timeout, under timeout(1) (exit 1 and
# a message when the cap is hit, the agent's own code otherwise).
agent_exec() {
  if [ -n "\${cmux_ag_timeout:-}" ]; then
    cmux_ag_bin="\$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
    if [ -n "\$cmux_ag_bin" ]; then
      "\$cmux_ag_bin" -k 5 "\$cmux_ag_timeout" "\$@" && return 0
      cmux_ag_rc=\$?
      [ "\$cmux_ag_rc" -ne 124 ] || die "agent \$cmux_agent timed out after \${cmux_ag_timeout}s" 1
      exit "\$cmux_ag_rc"
    fi
    warn "no timeout(1) on this machine; running \$cmux_agent without a cap"
  fi
  exec "\$@"
}

guest_coderouter_agent() {
  cmux_agent="\${1:-}"
  [ -n "\$cmux_agent" ] || die_message 2 agentUsage
  if [ "\$cmux_agent" = "--agent" ]; then
    shift
    cmux_agent="\${1:-}"
    [ -n "\$cmux_agent" ] || die_message 2 agentUsage
  fi
  shift
  case "\$cmux_agent" in
    claude|codex|opencode|pi) ;;
    *) die_message 2 unsupportedAgent "\$cmux_agent" ;;
  esac
  # This form runs the agent right here, in the caller's terminal, so it is
  # already the wait and its output is already the output: --wait and --output
  # are accepted for parity with \`cmux vm agent <machine> …\`; --timeout caps it.
  cmux_ag_timeout=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --wait|--output) shift ;;
      --timeout) [ "\$#" -ge 2 ] || die "agent: --timeout needs seconds" 2; cmux_ag_timeout="\$2"; shift 2 ;;
      --timeout=*) cmux_ag_timeout="\${1#--timeout=}"; shift ;;
      *) break ;;
    esac
  done
  [ -z "\$cmux_ag_timeout" ] || timeout_ms "\$cmux_ag_timeout" "agent" >/dev/null
  load_agent_config
  # Match the host vm-agent contract: a bare sentence becomes the provider's
  # one-shot form, while flags/subcommands are passed through byte-for-byte.
  if [ "\$#" -eq 0 ]; then
    agent_exec "\$cmux_agent"
  fi
  if [ "\$1" = "--" ]; then
    shift
    [ "\$#" -gt 0 ] || die_message 2 agentUsage
    cmux_prompt="\$*"
    case "\$cmux_agent" in
      claude) set -- claude -p "\$cmux_prompt" ;;
      codex) set -- codex exec "\$cmux_prompt" ;;
      opencode) set -- opencode run "\$cmux_prompt" ;;
      pi) set -- pi -p "\$cmux_prompt" ;;
    esac
    agent_exec "\$@"
  fi
  cmux_first="\$1"
  case "\$cmux_first" in
    -*|mcp|config|doctor|update|install|auth|setup-token|plugin|agents|exec|e|login|logout|apply|resume|completion|debug|sandbox|cloud|app-server|features|run|serve|web|models|upgrade|agent|session|export|import|github|acp|list)
      agent_exec "\$cmux_agent" "\$@"
      ;;
    *)
      cmux_prompt="\$*"
      case "\$cmux_agent" in
        claude) set -- claude -p "\$cmux_prompt" ;;
        codex) set -- codex exec "\$cmux_prompt" ;;
        opencode) set -- opencode run "\$cmux_prompt" ;;
        pi) set -- pi -p "\$cmux_prompt" ;;
      esac
      agent_exec "\$@"
      ;;
  esac
}

guest_agent_command() {
  case "\${1:-}" in
    claude|codex|opencode|pi|--agent)
      guest_coderouter_agent "\$@"
      ;;
    list|report|hook)
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" agent "\$@"
      ;;
    help|--help|-h|"")
      guest_usage
      ;;
    *)
      die_message 2 agentCommand "\$1"
      ;;
  esac
}

guest_coderouter_command() {
  cmux_coderouter_sub="\${1:-help}"
  [ "\$#" -gt 0 ] && shift
  case "\$cmux_coderouter_sub" in
    status|auth) guest_auth_status "\$@" ;;
    usage|machines) guest_coderouter_usage "\$@" ;;
    models) guest_coderouter_models "\$@" ;;
    agent|run) guest_coderouter_agent "\$@" ;;
    help|--help|-h) guest_usage ;;
    claude|accounts|login|logout)
      die_message 2 accountHostOnly "\$cmux_coderouter_sub"
      ;;
    *) die_message 2 unknownCodeRouter "\$cmux_coderouter_sub" ;;
  esac
}

host_only_command() {
  die_message 2 hostOwned "\$1"
}

local_alias() {
  case "\$1" in
    list-workspaces)
      shift
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" workspace list "\$@"
      ;;
    current-workspace)
      shift
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" workspace current show "\$@"
      ;;
    list-panes)
      shift
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" pane list "\$@"
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Machine env: ~/.config/cmux/env, sourced by every login/interactive shell on
# this machine (hook lines in ~/.profile and ~/.bashrc, installed here) and by
# agents started through this shim. \`cmux vm env …\` on the Mac drives these
# same verbs, so the Mac and the machine cannot disagree about the file.
# ---------------------------------------------------------------------------
env_file() { printf '%s/.config/cmux/env' "\${HOME:-/root}"; }
ENV_HOOK_LINE='[ -f "\$HOME/.config/cmux/env" ] && . "\$HOME/.config/cmux/env" # cmux-env-hook'

env_usage() {
  cmux_message envHelp
}

env_key_ok() {
  case "\$1" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# Single-quote a value for an \`export KEY='…'\` line (' becomes '\\'').
env_quote() { printf '%s\\n' "\$1" | sed "s/'/'\\\\\\\\''/g"; }

env_parse_dotenv_value() {
  awk '
    {
      value = $0
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      quote = substr(value, 1, 1)
      if (quote == sprintf("%c", 34) || quote == sprintf("%c", 39)) {
        escaped = 0
        for (offset = 2; offset <= length(value); offset++) {
          character = substr(value, offset, 1)
          if (character == quote && !escaped) {
            suffix = substr(value, offset + 1)
            sub(/^[[:space:]]+/, "", suffix)
            if (suffix == "" || substr(suffix, 1, 1) == "#") {
              print substr(value, 2, offset - 2)
              next
            }
          }
          escaped = character == sprintf("%c", 92) && !escaped
        }
      }
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
    }'
}

# stdin: dotenv text → stdout: KEY=VALUE lines (comments/blank lines dropped,
# a leading \`export \` removed, one pair of matching quotes stripped).
env_parse_dotenv() {
  cmux_cr="\$(printf '\\r')"
  while IFS= read -r cmux_line || [ -n "\$cmux_line" ]; do
    cmux_line="\${cmux_line%"\$cmux_cr"}"
    cmux_line="\$(printf '%s\\n' "\$cmux_line" | sed 's/^[[:space:]]*//')"
    case "\$cmux_line" in ''|'#'*) continue ;; esac
    case "\$cmux_line" in
      'export '*|'export	'*)
        cmux_line="\${cmux_line#export}"
        cmux_line="\$(printf '%s\\n' "\$cmux_line" | sed 's/^[[:space:]]*//')"
        ;;
    esac
    case "\$cmux_line" in *=*) ;; *) die "env: malformed line (expected KEY=VALUE): \$cmux_line" 2 ;; esac
    cmux_key="\${cmux_line%%=*}"
    cmux_key="\$(printf '%s\\n' "\$cmux_key" | sed 's/[[:space:]]*\$//')"
    cmux_val="\$(printf '%s\\n' "\${cmux_line#*=}" | env_parse_dotenv_value)"
    printf '%s=%s\\n' "\$cmux_key" "\$cmux_val"
  done
  return 0
}

# stdout: KEY=VALUE lines decoded from the managed file (nothing when absent).
env_decoded_lines() {
  [ -f "\$1" ] || return 0
  grep '^export [A-Za-z_][A-Za-z0-9_]*=' "\$1" 2>/dev/null | while IFS= read -r cmux_line; do
    cmux_rest="\${cmux_line#export }"
    cmux_key="\${cmux_rest%%=*}"
    cmux_q="\${cmux_rest#*=}"
    cmux_q="\${cmux_q#\\'}"
    cmux_q="\${cmux_q%\\'}"
    cmux_val="\$(printf '%s\\n' "\$cmux_q" | sed "s/'\\\\\\\\''/'/g")"
    printf '%s=%s\\n' "\$cmux_key" "\$cmux_val"
  done
  return 0
}

# stdin: the complete new file body → written atomically with mode 0600.
env_write() {
  cmux_env_path="\$(env_file)"
  mkdir -p "\${cmux_env_path%/*}"
  (
    umask 077
    cat > "\$cmux_env_path.tmp"
  )
  chmod 600 "\$cmux_env_path.tmp"
  mv -f "\$cmux_env_path.tmp" "\$cmux_env_path"
}

env_hook_into() {
  if [ -f "\$1" ] && grep -q 'cmux-env-hook' "\$1" 2>/dev/null; then return 0; fi
  printf '\\n%s\\n' "\$ENV_HOOK_LINE" >> "\$1"
  return 0
}

# ~/.profile (login shells, incl. \`bash -l\` from the Mac and dash -l) and
# ~/.bashrc (interactive shells). ~/.bash_profile shadows ~/.profile for bash
# login shells, so it gets the line too — but only when it already exists.
env_install_hook() {
  env_hook_into "\${HOME:-/root}/.profile"
  env_hook_into "\${HOME:-/root}/.bashrc"
  if [ -f "\${HOME:-/root}/.bash_profile" ]; then env_hook_into "\${HOME:-/root}/.bash_profile"; fi
  return 0
}

# Rewrite the managed file from KEY=VALUE lines on stdin (replacing those keys,
# keeping every other key), sorted by key.
env_merge_and_write() {
  cmux_env_path="\$(env_file)"
  cmux_env_tmp="\$(mktemp "\${TMPDIR:-/tmp}/cmux-env.XXXXXX")"
  cmux_env_new="\$(mktemp "\${TMPDIR:-/tmp}/cmux-env.XXXXXX")"
  cat > "\$cmux_env_new"
  : > "\$cmux_env_tmp"
  while IFS= read -r cmux_pair || [ -n "\$cmux_pair" ]; do
    [ -n "\$cmux_pair" ] || continue
    cmux_key="\${cmux_pair%%=*}"
    cmux_val="\${cmux_pair#*=}"
    env_key_ok "\$cmux_key" || { rm -f "\$cmux_env_tmp" "\$cmux_env_new"; die "env: invalid key '\$cmux_key' (letters, digits and _ only, not starting with a digit)" 2; }
    # Later assignments of the same key win.
    grep -v "^export \$cmux_key=" "\$cmux_env_tmp" > "\$cmux_env_tmp.next" || true
    mv -f "\$cmux_env_tmp.next" "\$cmux_env_tmp"
    printf "export %s='%s'\\n" "\$cmux_key" "\$(env_quote "\$cmux_val")" >> "\$cmux_env_tmp"
  done < "\$cmux_env_new"
  if [ -f "\$cmux_env_path" ]; then
    grep '^export [A-Za-z_][A-Za-z0-9_]*=' "\$cmux_env_path" 2>/dev/null | while IFS= read -r cmux_line; do
      cmux_key="\${cmux_line#export }"
      cmux_key="\${cmux_key%%=*}"
      grep -q "^export \$cmux_key=" "\$cmux_env_tmp" || printf '%s\\n' "\$cmux_line" >> "\$cmux_env_tmp"
    done
  fi
  {
    printf '%s\\n' "# managed by cmux env; KEY='value' lines; edit with cmux env set/rm"
    LC_ALL=C sort -t = -k 1,1 "\$cmux_env_tmp"
  } | env_write
  rm -f "\$cmux_env_tmp" "\$cmux_env_new"
  env_install_hook
}

# Collect literal KEY=VALUE lines into file \$1 from the remaining arguments:
# KEY=VALUE words, --from-file <.env> (dotenv), or \`-\` (dotenv on stdin).
env_collect_input() {
  cmux_ec_file="\$1"
  shift
  : > "\$cmux_ec_file"
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --from-file)
        [ "\$#" -ge 2 ] || die "env set: --from-file needs a path" 2
        [ -f "\$2" ] || die "env set: no such file \$2" 2
        env_parse_dotenv < "\$2" >> "\$cmux_ec_file"
        shift 2
        ;;
      --from-file=*)
        [ -f "\${1#--from-file=}" ] || die "env set: no such file \${1#--from-file=}" 2
        env_parse_dotenv < "\${1#--from-file=}" >> "\$cmux_ec_file"
        shift
        ;;
      -)
        env_parse_dotenv >> "\$cmux_ec_file"
        shift
        ;;
      --json) shift ;;
      -*) die "env set: unknown option \$1" 2 ;;
      *)
        case "\$1" in
          *=*)
            [ "\$(printf '%s' "\$1" | tr -d '\\r\\n')" = "\$1" ] || die_message 2 envSingleLineValue
            printf '%s\\n' "\$1" >> "\$cmux_ec_file"
            ;;
          *) die "env set: expected KEY=VALUE, got '\$1'" 2 ;;
        esac
        shift
        ;;
    esac
  done
  [ -s "\$cmux_ec_file" ] || die "env set: nothing to set (pass KEY=VALUE, --from-file <path>, or - for stdin)" 2
  # Keys are checked here, before anything is written, so a bad line never half-applies.
  while IFS= read -r cmux_ec_pair || [ -n "\$cmux_ec_pair" ]; do
    [ -n "\$cmux_ec_pair" ] || continue
    env_key_ok "\${cmux_ec_pair%%=*}" || die "env: invalid key '\${cmux_ec_pair%%=*}' (letters, digits and _ only, not starting with a digit)" 2
  done < "\$cmux_ec_file"
}

guest_env_set() {
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in --help|-h) env_usage; return 0 ;; esac
  done
  cmux_env_input="\$(mktemp "\${TMPDIR:-/tmp}/cmux-env.XXXXXX")"
  env_collect_input "\$cmux_env_input" "\$@"
  env_merge_and_write < "\$cmux_env_input"
  cmux_env_count="\$(grep -c . "\$cmux_env_input" || true)"
  rm -f "\$cmux_env_input"
  printf 'OK set %s variable%s in %s (new cmux shells and agents see them)\\n' "\$cmux_env_count" "\$([ "\$cmux_env_count" = 1 ] || printf s)" "\$(env_file)"
}

# The receiving end of \`cmux vm env set\` (Mac → machine, or peer → peer):
# values never ride the provider exec API or any argv. The sender starts
# \`cmux env receive\` in a terminal over the Noise-encrypted cmux-tui link,
# waits for CMUX-ENV-READY (echo is off by then, so nothing lands on the
# screen), types base64 lines and a CMUX-ENV-END line, and reads back one
# CMUX-ENV-OK keys=<n> path=<file> or CMUX-ENV-ERR <reason> line.
env_receive_cleanup() {
  if [ -n "\${cmux_er_dir:-}" ]; then rm -rf "\$cmux_er_dir"; fi
  if [ -n "\${cmux_er_dog:-}" ]; then kill "\$cmux_er_dog" 2>/dev/null || true; fi
  if [ "\${cmux_er_tty:-0}" -eq 1 ]; then stty echo 2>/dev/null || true; fi
  return 0
}

guest_env_receive() {
  cmux_er_stdin=0
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --stdin) cmux_er_stdin=1 ;;
      --help|-h) env_usage; return 0 ;;
      *) die "env receive: unknown option \$cmux_arg" 2 ;;
    esac
  done
  umask 077
  cmux_er_tty=0
  if [ "\$cmux_er_stdin" -eq 0 ] && [ -t 0 ]; then
    if stty -echo 2>/dev/null; then cmux_er_tty=1; fi
  fi
  cmux_er_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/cmux-env-recv.XXXXXX")"
  # Watchdog: a sender that never finishes must not leave a receiver holding
  # the terminal forever.
  # (\$\$ inside the subshell is still the receiver's pid. It polls once a second
  # and stops by itself once the scratch dir is gone, so nothing lingers.)
  ( cmux_er_i=0; while [ -d "\$cmux_er_dir" ] && [ "\$cmux_er_i" -lt 120 ]; do sleep 1; cmux_er_i=\$((cmux_er_i + 1)); done; if [ -d "\$cmux_er_dir" ]; then kill -TERM \$\$ 2>/dev/null; fi ) </dev/null >/dev/null 2>&1 &
  cmux_er_dog=\$!
  trap 'env_receive_cleanup' EXIT
  trap 'printf "CMUX-ENV-ERR timeout\\n"; exit 1' TERM
  trap 'printf "CMUX-ENV-ERR interrupted\\n"; exit 1' INT HUP
  printf 'CMUX-ENV-READY\\n'
  cmux_er_bytes=0
  cmux_er_end=0
  cmux_er_cr="\$(printf '\\r')"
  while IFS= read -r cmux_er_line; do
    cmux_er_line="\${cmux_er_line%"\$cmux_er_cr"}"
    if [ "\$cmux_er_line" = CMUX-ENV-END ]; then cmux_er_end=1; break; fi
    [ -n "\$cmux_er_line" ] || continue
    cmux_er_bytes=\$((cmux_er_bytes + \${#cmux_er_line}))
    if [ "\$cmux_er_bytes" -gt 524288 ]; then printf 'CMUX-ENV-ERR too-large\\n'; exit 1; fi
    printf '%s\\n' "\$cmux_er_line" >> "\$cmux_er_dir/b64"
  done
  if [ "\$cmux_er_end" -ne 1 ]; then printf 'CMUX-ENV-ERR eof\\n'; exit 1; fi
  if [ ! -s "\$cmux_er_dir/b64" ]; then printf 'CMUX-ENV-ERR empty\\n'; exit 1; fi
  if ! base64 -d < "\$cmux_er_dir/b64" > "\$cmux_er_dir/payload" 2>/dev/null; then printf 'CMUX-ENV-ERR bad-base64\\n'; exit 1; fi
  # The payload is literal KEY=VALUE lines (the sender already parsed dotenv):
  # no trimming, no quote stripping. Validate every key before writing anything.
  cmux_er_n=0
  while IFS= read -r cmux_er_pair || [ -n "\$cmux_er_pair" ]; do
    [ -n "\$cmux_er_pair" ] || continue
    case "\$cmux_er_pair" in
      *=*) ;;
      *) printf 'CMUX-ENV-ERR invalid-key %s\\n' "\$cmux_er_pair"; exit 1 ;;
    esac
    if ! env_key_ok "\${cmux_er_pair%%=*}"; then printf 'CMUX-ENV-ERR invalid-key %s\\n' "\${cmux_er_pair%%=*}"; exit 1; fi
    cmux_er_n=\$((cmux_er_n + 1))
  done < "\$cmux_er_dir/payload"
  if [ "\$cmux_er_n" -eq 0 ]; then printf 'CMUX-ENV-ERR empty\\n'; exit 1; fi
  if ! env_merge_and_write < "\$cmux_er_dir/payload"; then printf 'CMUX-ENV-ERR write-failed\\n'; exit 1; fi
  printf 'CMUX-ENV-OK keys=%s path=%s\\n' "\$cmux_er_n" "\$(env_file)"
}

guest_env_ls() {
  cmux_env_show=0
  cmux_env_json=0
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --show|--values) cmux_env_show=1 ;;
      --json) cmux_env_json=1 ;;
      --help|-h) env_usage; return 0 ;;
      *) die "env ls: unknown option \$cmux_arg" 2 ;;
    esac
  done
  cmux_env_path="\$(env_file)"
  if [ "\$cmux_env_json" -eq 1 ]; then
    env_decoded_lines "\$cmux_env_path" | jq -Rn --arg path "\$cmux_env_path" --argjson show "\$cmux_env_show" '
      [inputs | capture("^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)\$")] as \$pairs
      | {path: \$path, keys: (\$pairs | map(.k))}
        + (if \$show == 1 then {values: ((\$pairs | map({(.k): .v}) | add) // {})} else {} end)'
    return 0
  fi
  if [ ! -f "\$cmux_env_path" ]; then
    printf 'no machine env yet (set one with: cmux env set KEY=VALUE)\\n'
    return 0
  fi
  if [ "\$cmux_env_show" -eq 1 ]; then
    env_decoded_lines "\$cmux_env_path"
  else
    env_decoded_lines "\$cmux_env_path" | sed 's/=.*//'
  fi
}

guest_env_rm() {
  [ "\$#" -gt 0 ] || die "usage: cmux env rm KEY [KEY2 ...]" 2
  cmux_env_path="\$(env_file)"
  for cmux_key in "\$@"; do
    env_key_ok "\$cmux_key" || die "env rm: invalid key '\$cmux_key'" 2
  done
  cmux_env_tmp="\$(mktemp "\${TMPDIR:-/tmp}/cmux-env.XXXXXX")"
  if [ -f "\$cmux_env_path" ]; then
    grep '^export [A-Za-z_][A-Za-z0-9_]*=' "\$cmux_env_path" > "\$cmux_env_tmp" 2>/dev/null || true
  fi
  for cmux_key in "\$@"; do
    grep -v "^export \$cmux_key=" "\$cmux_env_tmp" > "\$cmux_env_tmp.next" || true
    mv -f "\$cmux_env_tmp.next" "\$cmux_env_tmp"
  done
  {
    printf '%s\\n' "# managed by cmux env; KEY='value' lines; edit with cmux env set/rm"
    LC_ALL=C sort -t = -k 1,1 "\$cmux_env_tmp"
  } | env_write
  rm -f "\$cmux_env_tmp"
  env_install_hook
  printf 'OK removed %s from %s\\n' "\$*" "\$cmux_env_path"
}

guest_env_command() {
  cmux_env_sub="\${1:-help}"
  [ "\$#" -gt 0 ] && shift
  case "\$cmux_env_sub" in
    set) guest_env_set "\$@" ;;
    ls|list) guest_env_ls "\$@" ;;
    rm|unset|remove) guest_env_rm "\$@" ;;
    receive) guest_env_receive "\$@" ;;
    path) printf '%s\\n' "\$(env_file)" ;;
    help|--help|-h) env_usage ;;
    *) die "unknown env command '\$cmux_env_sub' (try: cmux env help)" 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# File drop: bytes that arrive typed over the encrypted link (the Mac's
# \`cmux vm push --secret\`, a peer's \`cmux vm push\`), never through a provider
# exec API, an argv, or a control plane. The handshake is \`cmux env receive\`'s
# with CMUX-FILE-* markers, so one sender implementation serves both.
# ---------------------------------------------------------------------------
file_usage() {
  cmux_message fileHelp
}

# Three or four octal digits (600, 0644, 755).
file_mode_ok() {
  case "\$1" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) return 0 ;;
  esac
  return 1
}

file_receive_cleanup() {
  if [ -n "\${cmux_fr_tmp:-}" ]; then rm -f "\$cmux_fr_tmp"; fi
  if [ -n "\${cmux_fr_dir:-}" ]; then rm -rf "\$cmux_fr_dir"; fi
  if [ -n "\${cmux_fr_dog:-}" ]; then kill "\$cmux_fr_dog" 2>/dev/null || true; fi
  if [ "\${cmux_fr_tty:-0}" -eq 1 ]; then stty echo 2>/dev/null || true; fi
  return 0
}

# cmux file receive <path> [--mode <octal>] [--stdin]: turn PTY echo off, print
# CMUX-FILE-READY, read base64 lines up to CMUX-FILE-END, decode in a scratch
# dir (bad input never touches the destination), then land the bytes through a
# temp file in the destination directory and one rename, so a reader never sees
# a partial file and a failed transfer leaves nothing behind. Answers with one
# CMUX-FILE-OK bytes=<n> path=<p> mode=<m> or CMUX-FILE-ERR <reason> line.
# Relative paths are under \$HOME; missing parents are created (0700); the file
# gets the requested mode (default 600); the payload is capped at 256 KiB.
guest_file_receive() {
  cmux_fr_stdin=0
  cmux_fr_mode=600
  cmux_fr_path=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --stdin) cmux_fr_stdin=1; shift ;;
      --mode) [ "\$#" -ge 2 ] || { printf 'CMUX-FILE-ERR bad-mode\\n'; exit 2; }; cmux_fr_mode="\$2"; shift 2 ;;
      --mode=*) cmux_fr_mode="\${1#--mode=}"; shift ;;
      --help|-h) file_usage; return 0 ;;
      -*) printf 'CMUX-FILE-ERR usage unknown option %s\\n' "\$1"; exit 2 ;;
      *) if [ -z "\$cmux_fr_path" ]; then cmux_fr_path="\$1"; else printf 'CMUX-FILE-ERR usage one path only\\n'; exit 2; fi; shift ;;
    esac
  done
  [ -n "\$cmux_fr_path" ] || { printf 'CMUX-FILE-ERR usage cmux file receive <path> [--mode <octal>]\\n'; exit 2; }
  file_mode_ok "\$cmux_fr_mode" || { printf 'CMUX-FILE-ERR bad-mode %s\\n' "\$cmux_fr_mode"; exit 2; }
  case "\$cmux_fr_path" in
    /*) ;;
    *) cmux_fr_path="\${HOME:-/root}/\$cmux_fr_path" ;;
  esac
  if [ -d "\$cmux_fr_path" ]; then printf 'CMUX-FILE-ERR is-directory %s\\n' "\$cmux_fr_path"; exit 1; fi
  umask 077
  cmux_fr_tty=0
  if [ "\$cmux_fr_stdin" -eq 0 ] && [ -t 0 ]; then
    if stty -echo 2>/dev/null; then cmux_fr_tty=1; fi
  fi
  cmux_fr_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/cmux-file-recv.XXXXXX")"
  cmux_fr_tmp=""
  # Watchdog, as in env receive: a sender that never finishes must not hold
  # this terminal forever.
  ( cmux_fr_i=0; while [ -d "\$cmux_fr_dir" ] && [ "\$cmux_fr_i" -lt 120 ]; do sleep 1; cmux_fr_i=\$((cmux_fr_i + 1)); done; if [ -d "\$cmux_fr_dir" ]; then kill -TERM \$\$ 2>/dev/null; fi ) </dev/null >/dev/null 2>&1 &
  cmux_fr_dog=\$!
  trap 'file_receive_cleanup' EXIT
  trap 'printf "CMUX-FILE-ERR timeout\\n"; exit 1' TERM
  trap 'printf "CMUX-FILE-ERR interrupted\\n"; exit 1' INT HUP
  printf 'CMUX-FILE-READY\\n'
  cmux_fr_chars=0
  cmux_fr_end=0
  cmux_fr_cr="\$(printf '\\r')"
  while IFS= read -r cmux_fr_line; do
    cmux_fr_line="\${cmux_fr_line%"\$cmux_fr_cr"}"
    if [ "\$cmux_fr_line" = CMUX-FILE-END ]; then cmux_fr_end=1; break; fi
    [ -n "\$cmux_fr_line" ] || continue
    cmux_fr_chars=\$((cmux_fr_chars + \${#cmux_fr_line}))
    # 349528 base64 characters decode to exactly 262144 bytes (256 KiB).
    if [ "\$cmux_fr_chars" -gt 349528 ]; then printf 'CMUX-FILE-ERR too-large\\n'; exit 1; fi
    printf '%s\\n' "\$cmux_fr_line" >> "\$cmux_fr_dir/b64"
  done
  if [ "\$cmux_fr_end" -ne 1 ]; then printf 'CMUX-FILE-ERR eof\\n'; exit 1; fi
  if [ ! -s "\$cmux_fr_dir/b64" ]; then printf 'CMUX-FILE-ERR empty\\n'; exit 1; fi
  if ! base64 -d < "\$cmux_fr_dir/b64" > "\$cmux_fr_dir/payload" 2>/dev/null; then printf 'CMUX-FILE-ERR bad-base64\\n'; exit 1; fi
  cmux_fr_bytes="\$(wc -c < "\$cmux_fr_dir/payload" | tr -d ' ')"
  if [ "\$cmux_fr_bytes" -eq 0 ]; then printf 'CMUX-FILE-ERR empty\\n'; exit 1; fi
  if [ "\$cmux_fr_bytes" -gt 262144 ]; then printf 'CMUX-FILE-ERR too-large\\n'; exit 1; fi
  cmux_fr_parent="\${cmux_fr_path%/*}"
  [ -n "\$cmux_fr_parent" ] || cmux_fr_parent=/
  if [ ! -d "\$cmux_fr_parent" ]; then
    mkdir -p "\$cmux_fr_parent" 2>/dev/null || { printf 'CMUX-FILE-ERR mkdir-failed %s\\n' "\$cmux_fr_parent"; exit 1; }
  fi
  cmux_fr_tmp="\$(mktemp "\$cmux_fr_parent/.cmux-file.XXXXXX" 2>/dev/null)" || { cmux_fr_tmp=""; printf 'CMUX-FILE-ERR write-failed %s\\n' "\$cmux_fr_parent"; exit 1; }
  if cat "\$cmux_fr_dir/payload" > "\$cmux_fr_tmp" 2>/dev/null && chmod "\$cmux_fr_mode" "\$cmux_fr_tmp" 2>/dev/null && mv -f "\$cmux_fr_tmp" "\$cmux_fr_path" 2>/dev/null; then :; else
    printf 'CMUX-FILE-ERR write-failed %s\\n' "\$cmux_fr_path"; exit 1
  fi
  cmux_fr_tmp=""
  printf 'CMUX-FILE-OK bytes=%s path=%s mode=%s\\n' "\$cmux_fr_bytes" "\$cmux_fr_path" "\$cmux_fr_mode"
}

guest_file_command() {
  cmux_file_sub="\${1:-help}"
  [ "\$#" -gt 0 ] && shift
  case "\$cmux_file_sub" in
    receive) guest_file_receive "\$@" ;;
    help|--help|-h) file_usage ;;
    *) die "unknown file command '\$cmux_file_sub' (try: cmux file help)" 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Terminal verbs in the Mac's spelling (\`cmux vm terminal send|read|wait|close\`
# and \`cmux send|send-key|read-screen\`), on the current target. Local calls
# default to the caller's own terminal (CMUX_TUI_TERMINAL_ID, set by the daemon).
# ---------------------------------------------------------------------------
terminal_usage() {
  cmux_message terminalHelp
}

# Milliseconds for a \`--timeout <seconds>\` (decimals allowed, > 0), or die.
timeout_ms() {
  cmux_ms="\$(awk -v s="\$1" 'BEGIN { if (s !~ /^[0-9]*\\.?[0-9]+\$/ || s + 0 <= 0) exit 1; printf "%d", s * 1000 }')" || die "\${2:-terminal wait}: --timeout takes seconds > 0, got '\$1'" 2
  [ "\$cmux_ms" -ge 1 ] || cmux_ms=1
  printf '%s' "\$cmux_ms"
}

terminal_verb() {
  cmux_tv_verb="\$1"
  cmux_tv_term="\$2"
  shift 2
  [ -n "\$cmux_tv_term" ] || die "terminal \$cmux_tv_verb: a terminal id is required (see cmux terminal list)" 2
  case "\$cmux_tv_verb" in
    rename|move)
      guest_topology_command terminal "\$cmux_tv_verb" "\$cmux_tv_term" "\$@"
      ;;
    send|write)
      cmux_tv_text=""
      cmux_tv_keys=""
      cmux_tv_literal=0
      while [ "\$#" -gt 0 ]; do
        if [ "\$cmux_tv_literal" -eq 1 ]; then cmux_tv_text="\${cmux_tv_text:+\$cmux_tv_text }\$1"; shift; continue; fi
        case "\$1" in
          --) cmux_tv_literal=1; shift ;;
          --keys) [ "\$#" -ge 2 ] || die "terminal send: --keys needs a value (e.g. --keys enter)" 2; cmux_tv_keys="\$2"; shift 2 ;;
          --keys=*) cmux_tv_keys="\${1#--keys=}"; shift ;;
          --json) shift ;;
          *) cmux_tv_text="\${cmux_tv_text:+\$cmux_tv_text }\$1"; shift ;;
        esac
      done
      if [ -z "\$cmux_tv_text" ] && [ -z "\$cmux_tv_keys" ]; then
        die "terminal send: give text and/or --keys (e.g. --keys enter)" 2
      fi
      if [ -n "\$cmux_tv_text" ]; then
        tui terminal "\$cmux_tv_term" write --text "\$cmux_tv_text"
      fi
      if [ -n "\$cmux_tv_keys" ]; then
        set --
        cmux_tv_ifs="\$IFS"
        IFS=,
        for cmux_tv_key in \$cmux_tv_keys; do
          IFS="\$cmux_tv_ifs"
          [ -n "\$cmux_tv_key" ] && set -- "\$@" "\$cmux_tv_key"
          IFS=,
        done
        IFS="\$cmux_tv_ifs"
        [ "\$#" -gt 0 ] || die "terminal send: --keys needs at least one key name" 2
        tui terminal "\$cmux_tv_term" keys "\$@"
      fi
      ;;
    read|screen)
      cmux_tv_json=""
      for cmux_arg in "\$@"; do
        case "\$cmux_arg" in
          --json) cmux_tv_json=--json ;;
          *) die "terminal read: unknown option \$cmux_arg" 2 ;;
        esac
      done
      # shellcheck disable=SC2086
      tui \$cmux_tv_json terminal "\$cmux_tv_term" screen read
      ;;
    wait)
      cmux_tv_pattern=""
      cmux_tv_timeout=30
      cmux_tv_json=0
      while [ "\$#" -gt 0 ]; do
        case "\$1" in
          --pattern) [ "\$#" -ge 2 ] || die "terminal wait: --pattern needs a regex" 2; cmux_tv_pattern="\$2"; shift 2 ;;
          --pattern=*) cmux_tv_pattern="\${1#--pattern=}"; shift ;;
          --timeout) [ "\$#" -ge 2 ] || die "terminal wait: --timeout needs seconds" 2; cmux_tv_timeout="\$2"; shift 2 ;;
          --timeout=*) cmux_tv_timeout="\${1#--timeout=}"; shift ;;
          --json) cmux_tv_json=1; shift ;;
          *) die "terminal wait: unknown option \$1" 2 ;;
        esac
      done
      [ -n "\$cmux_tv_pattern" ] || die "terminal wait: --pattern <regex> is required" 2
      cmux_tv_ms="\$(timeout_ms "\$cmux_tv_timeout")"
      if cmux_tv_out="\$(tui --json terminal "\$cmux_tv_term" screen wait --pattern "\$cmux_tv_pattern" --timeout-ms "\$cmux_tv_ms" 2>&1)"; then :; else
        die "terminal wait failed on \$cmux_tv_term: \$cmux_tv_out" 1
      fi
      cmux_tv_matched="\$(printf '%s\\n' "\$cmux_tv_out" | jq -r '(.value // .) | if .matched == true then "true" else "false" end' 2>/dev/null || printf false)"
      if [ "\$cmux_tv_json" -eq 1 ]; then printf '%s\\n' "\$cmux_tv_out"; fi
      if [ "\$cmux_tv_matched" = true ]; then
        [ "\$cmux_tv_json" -eq 1 ] || printf 'OK matched /%s/ on %s\\n' "\$cmux_tv_pattern" "\$cmux_tv_term"
      else
        die "timed out after \${cmux_tv_timeout}s waiting for /\$cmux_tv_pattern/ on \$cmux_tv_term" 1
      fi
      ;;
    wait-exit)
      cmux_tv_timeout=""
      cmux_tv_json=0
      while [ "\$#" -gt 0 ]; do
        case "\$1" in
          --timeout) [ "\$#" -ge 2 ] || die "terminal wait-exit: --timeout needs seconds" 2; cmux_tv_timeout="\$2"; shift 2 ;;
          --timeout=*) cmux_tv_timeout="\${1#--timeout=}"; shift ;;
          --json) cmux_tv_json=1; shift ;;
          *) die "terminal wait-exit: unknown option \$1" 2 ;;
        esac
      done
      set -- terminal "\$cmux_tv_term" process wait
      if [ -n "\$cmux_tv_timeout" ]; then
        cmux_tv_ms="\$(timeout_ms "\$cmux_tv_timeout")"
        set -- "\$@" --timeout-ms "\$cmux_tv_ms"
      fi
      if cmux_tv_out="\$(tui --json "\$@" 2>&1)"; then :; else
        die "terminal wait-exit failed on \$cmux_tv_term: \$cmux_tv_out" 1
      fi
      cmux_tv_state="\$(printf '%s\\n' "\$cmux_tv_out" | jq -r '(.value // .) | if .state == "exited" then ((.outcome // {}) | if .kind == "exit" then "exited code=\\(.code)" elif .kind == "signal" then "exited signal=\\(.signal)" else "exited unknown=\\(.reason // "?")" end) else "pending" end' 2>/dev/null || printf pending)"
      if [ "\$cmux_tv_json" -eq 1 ]; then printf '%s\\n' "\$cmux_tv_out"; else printf '%s\\n' "\$cmux_tv_state"; fi
      case "\$cmux_tv_state" in exited*) ;; *) exit 1 ;; esac
      ;;
    output)
      cmux_tv_after=""
      cmux_tv_max=""
      cmux_tv_json=0
      while [ "\$#" -gt 0 ]; do
        case "\$1" in
          --after) [ "\$#" -ge 2 ] || die "terminal output: --after needs a byte offset" 2; cmux_tv_after="\$2"; shift 2 ;;
          --after=*) cmux_tv_after="\${1#--after=}"; shift ;;
          --max-bytes) [ "\$#" -ge 2 ] || die "terminal output: --max-bytes needs a count" 2; cmux_tv_max="\$2"; shift 2 ;;
          --max-bytes=*) cmux_tv_max="\${1#--max-bytes=}"; shift ;;
          --json) cmux_tv_json=1; shift ;;
          *) die "terminal output: unknown option \$1" 2 ;;
        esac
      done
      case "\$cmux_tv_after" in *[!0-9]*) die "terminal output: --after takes a byte offset, got '\$cmux_tv_after'" 2 ;; esac
      case "\$cmux_tv_max" in *[!0-9]*) die "terminal output: --max-bytes takes 1..4194304, got '\$cmux_tv_max'" 2 ;; esac
      if [ -n "\$cmux_tv_max" ] && { [ "\$cmux_tv_max" -lt 1 ] || [ "\$cmux_tv_max" -gt 4194304 ]; }; then
        die "terminal output: --max-bytes takes 1..4194304, got '\$cmux_tv_max'" 2
      fi
      set -- terminal "\$cmux_tv_term" output read
      [ -z "\$cmux_tv_after" ] || set -- "\$@" --after "\$cmux_tv_after"
      [ -z "\$cmux_tv_max" ] || set -- "\$@" --max-bytes "\$cmux_tv_max"
      if cmux_tv_out="\$(tui --json "\$@" 2>&1)"; then :; else
        die "terminal output failed on \$cmux_tv_term: \$cmux_tv_out" 1
      fi
      if [ "\$cmux_tv_json" -eq 1 ]; then
        printf '%s\\n' "\$cmux_tv_out"
      else
        printf '%s\\n' "\$cmux_tv_out" | jq -j '(.value // .) | .text // ""'
      fi
      ;;
    close)
      tui terminal "\$cmux_tv_term" close
      ;;
    *)
      die "terminal: unknown verb '\$cmux_tv_verb' (send, read, wait, wait-exit, output, close)" 2
      ;;
  esac
}

# \`--terminal <id>\` from the front of "\$@" (the rest is printed back, one per
# line, for the caller to re-split) or the caller's own terminal.
caller_terminal() {
  cmux_ct="\${CMUX_TUI_TERMINAL_ID:-}"
  [ -n "\$cmux_ct" ] || die "no terminal: pass --terminal <term_id> (see cmux terminal list); CMUX_TUI_TERMINAL_ID is set inside daemon terminals" 2
  printf '%s' "\$cmux_ct"
}

local_terminal_alias() {
  cmux_lt_verb="\$1"
  shift
  cmux_lt_term=""
  cmux_lt_json=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --terminal) [ "\$#" -ge 2 ] || die "\$cmux_lt_verb: --terminal needs an id" 2; cmux_lt_term="\$2"; shift 2 ;;
      --terminal=*) cmux_lt_term="\${1#--terminal=}"; shift ;;
      --json) cmux_lt_json=--json; shift ;;
      --help|-h) terminal_usage; return 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ -n "\$cmux_lt_term" ] || cmux_lt_term="\$(caller_terminal)"
  case "\$cmux_lt_verb" in
    send)
      [ "\$#" -gt 0 ] || die "usage: cmux send [--terminal <id>] <text>" 2
      # shellcheck disable=SC2086
      exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" \$cmux_lt_json terminal "\$cmux_lt_term" write --text "\$*"
      ;;
    send-key)
      [ "\$#" -gt 0 ] || die "usage: cmux send-key [--terminal <id>] <key> [key...]  (enter, tab, escape, up, ctrl+c, ...)" 2
      # shellcheck disable=SC2086
      exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" \$cmux_lt_json terminal "\$cmux_lt_term" keys "\$@"
      ;;
    read-screen)
      [ "\$#" -eq 0 ] || die "usage: cmux read-screen [--terminal <id>] [--json]" 2
      # shellcheck disable=SC2086
      exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" \$cmux_lt_json terminal "\$cmux_lt_term" screen read
      ;;
  esac
}

# The pane a new split should start from when the caller names none: the
# pane showing the caller's terminal, else the focused pane of the focused
# workspace. Read from one snapshot so the answer is the daemon's, not a guess.
default_pane() {
  cmux_dp_snap="\$(tui --json session current snapshot 2>/dev/null)" || die "could not read the session snapshot (is the daemon running?)" 1
  cmux_dp="\$(printf '%s\\n' "\$cmux_dp_snap" | jq -r --arg term "\${CMUX_TUI_TERMINAL_ID:-}" '
    ((.tabs // []) | map(select(\$term != "" and .content_id == \$term)) | .[0].pane_id // "") as \$mine
    | if \$mine != null and \$mine != "" then \$mine else
        (((.workspaces // []) | map(select(.focused == true)) | .[0].id) // ((.workspaces // [])[0].id)) as \$ws
        | (((.screens // []) | map(select(.workspace_id == \$ws and .focused == true)) | .[0].id) // ((.screens // []) | map(select(.workspace_id == \$ws)) | .[0].id)) as \$screen
        | (((.panes // []) | map(select(.screen_id == \$screen and .focused == true)) | .[0].id) // ((.panes // []) | map(select(.screen_id == \$screen)) | .[0].id) // empty)
      end')"
  [ -n "\$cmux_dp" ] || die "no pane to split from; pass --pane <pane_id> (see cmux pane list)" 2
  printf '%s' "\$cmux_dp"
}

${GUEST_CMUX_TOPOLOGY_SHELL}
# ---------------------------------------------------------------------------
# Layouts as data. \`layout export\` turns a daemon workspace into the same
# declarative document the Mac accepts (\`cmux new-workspace --layout\`, cmux.json
# workspaces, \`cmux layout save/open\`); \`layout apply\` builds a workspace from
# one with the public resource verbs. The Mac's \`cmux vm layout …\` runs these.
# ---------------------------------------------------------------------------
layout_usage() {
  cmux_message layoutHelp
}

LAYOUT_RESOLVE_JQ='
  (.workspaces // []) as \$ws
  | (\$ws | map(select(.id == \$sel))) as \$byid
  | if (\$byid | length) == 1 then "ok\\t\\(\$byid[0].id)\\t\\(\$byid[0].name // "")"
    elif \$sel == "" or \$sel == "current" then
      (((\$ws | map(select(.focused == true))) | .[0]) // \$ws[0]) as \$w
      | if \$w == null then "none\\t\\t" else "ok\\t\\(\$w.id)\\t\\(\$w.name // "")" end
    else (\$ws | map(select(.name == \$sel))) as \$byname
      | if (\$byname | length) == 1 then "ok\\t\\(\$byname[0].id)\\t\\(\$byname[0].name // "")"
        elif (\$byname | length) > 1 then "ambiguous\\t\\(\$byname | map(.id) | join(" "))\\t"
        else "missing\\t\\t" end
    end'

# stdin: snapshot. Prints "<ws_id>\\t<name>" or dies (exit 2) naming the problem.
layout_resolve_workspace() {
  cmux_lr="\$(jq -r --arg sel "\$1" "\$LAYOUT_RESOLVE_JQ")"
  case "\$cmux_lr" in
    ok*) printf '%s\\n' "\$cmux_lr" | cut -f 2- ;;
    none*) die "layout: this session has no workspaces yet" 2 ;;
    ambiguous*) die "layout: several workspaces are named '\$1' (\$(printf '%s\\n' "\$cmux_lr" | cut -f 2)); use a ws_… id from \\\`cmux workspace list\\\`" 2 ;;
    *) die "layout: no workspace '\$1' (see cmux workspace list)" 2 ;;
  esac
}

layout_snapshot() {
  if cmux_ls_out="\$(tui --json session current snapshot 2>&1)"; then printf '%s\\n' "\$cmux_ls_out"; else
    die "layout: could not read the session snapshot: \$cmux_ls_out" 1
  fi
}

LAYOUT_EXPORT_JQ='
  def clamp: if . < 0.1 then 0.1 elif . > 0.9 then 0.9 else . end;
  def snap: \$snap[0];
  def term(\$id): ((snap.terminals // []) | map(select(.id == \$id)) | .[0]) // {};
  def browser(\$id): ((snap.browsers // []) | map(select(.id == \$id)) | .[0]) // {};
  def surfaces(\$pid):
    ([ (snap.tabs // [])[] | select(.pane_id == \$pid) ] | sort_by(.index // 0)
     | map(if .content_kind == "browser"
           then ({type: "browser"} + (if (.name // "") != "" then {name: .name} else {} end) + {url: (browser(.content_id).url // "")})
           else ({type: "terminal"} + (if (.name // "") != "" then {name: .name} else {} end)
                 + (if (term(.content_id).cwd // "") != "" then {cwd: term(.content_id).cwd} else {} end)) end))
    | if length == 0 then [{type: "terminal"}] else . end;
  def leaf(\$pid): {pane: {surfaces: surfaces(\$pid)}};
  def node:
    def stack_nodes:
      if length == 0 then leaf("") elif length == 1 then leaf(.[0])
      else {direction: "vertical", split: ((1 / length) | clamp), children: [leaf(.[0]), (.[1:] | stack_nodes)]} end;
    def viewport_nodes:
      if length == 0 then leaf("") elif length == 1 then (.[0].root | node)
      else (map(.width // 1) | add) as \$total
        | {direction: "horizontal", split: (((.[0].width // 1) / (if \$total > 0 then \$total else 1 end)) | clamp),
           children: [(.[0].root | node), (.[1:] | viewport_nodes)]} end;
    if .kind == "leaf" then leaf(.pane_id // "")
    elif .kind == "split" then {direction: (if .direction == "vertical" then "vertical" else "horizontal" end),
                                split: ((.ratio // 0.5) | clamp), children: [(.first | node), (.second | node)]}
    elif .kind == "stack" then ((.pane_ids // []) | stack_nodes)
    elif .kind == "viewport" then ((.columns // []) | viewport_nodes)
    else leaf("") end;
  def add_extra(\$extra):
    if (\$extra | length) == 0 then . elif has("pane") then .pane.surfaces += \$extra else .children[0] |= add_extra(\$extra) end;
  ((snap.screens // []) | map(select(.workspace_id == \$ws)) | sort_by([(if .focused then 0 else 1 end), (.index // 0)])) as \$screens
  | if (\$screens | length) == 0 then error("noscreens") else . end
  | \$screens[0] as \$main
  | ([ \$screens[1:][] as \$s | (snap.panes // [])[] | select(.screen_id == \$s.id) | .id ] | map(surfaces(.)) | add // []) as \$extra
  | if \$raw == 1 then \$main.layout
    else {name: \$wsname, cwd: \$home, layout: ((\$main.layout.root // {kind: "leaf", pane_id: ""}) | node | add_extra(\$extra))} end'

guest_layout_export() {
  cmux_le_sel=""
  cmux_le_raw=0
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --workspace) [ "\$#" -ge 2 ] || die "layout export: --workspace needs a value" 2; cmux_le_sel="\$2"; shift 2 ;;
      --workspace=*) cmux_le_sel="\${1#--workspace=}"; shift ;;
      --raw) cmux_le_raw=1; shift ;;
      --json) shift ;;
      --help|-h) layout_usage; return 0 ;;
      *) die "layout export: unknown option \$1" 2 ;;
    esac
  done
  cmux_le_snap="\$(mktemp "\${TMPDIR:-/tmp}/cmux-layout.XXXXXX")"
  layout_snapshot > "\$cmux_le_snap"
  cmux_le_ws="\$(layout_resolve_workspace "\$cmux_le_sel" < "\$cmux_le_snap")"
  cmux_le_id="\$(printf '%s\\n' "\$cmux_le_ws" | cut -f 1)"
  cmux_le_name="\$(printf '%s\\n' "\$cmux_le_ws" | cut -f 2-)"
  if cmux_le_out="\$(jq -n --slurpfile snap "\$cmux_le_snap" --arg ws "\$cmux_le_id" --arg wsname "\$cmux_le_name" --arg home "\${HOME:-/root}" --argjson raw "\$cmux_le_raw" "\$LAYOUT_EXPORT_JQ" 2>&1)"; then
    rm -f "\$cmux_le_snap"
    printf '%s\\n' "\$cmux_le_out"
  else
    rm -f "\$cmux_le_snap"
    case "\$cmux_le_out" in
      *noscreens*) die "layout export: workspace \$cmux_le_id has no layout yet (no screens); open a terminal in it first" 1 ;;
      *) die "layout export failed: \$cmux_le_out" 1 ;;
    esac
  fi
}

LAYOUT_NORMALIZE_JQ='
  def bad(\$p; \$m): "\\(\$p): \\(\$m)";
  def first_bad: map(select(. != "ok")) | .[0] // "ok";
  def vsurf(\$p):
    if type != "object" then bad(\$p; "surface must be an object")
    elif (has("type") | not) then bad(\$p + ".type"; "surface needs type (terminal, browser, or project)")
    elif ((.type | tostring) as \$t | (\$t == "terminal" or \$t == "browser" or \$t == "project") | not) then bad(\$p + ".type"; "must be terminal, browser, or project")
    elif .type == "browser" and (((.url // "") | tostring) == "") then bad(\$p + ".url"; "browser surface needs url")
    elif has("env") and (.env | type) != "object" then bad(\$p + ".env"; "must be an object of KEY: VALUE strings")
    elif has("command") and (.command | type) != "string" then bad(\$p + ".command"; "must be a string")
    elif has("cwd") and (.cwd | type) != "string" then bad(\$p + ".cwd"; "must be a string")
    else "ok" end;
  def vnode(\$p):
    if type != "object" then bad(\$p; "node must be an object")
    elif has("pane") and has("direction") then bad(\$p; "node must not have both pane and direction")
    elif has("pane") then
      (if (.pane | type) != "object" then bad(\$p + ".pane"; "must be an object")
       elif (.pane.surfaces | type) != "array" or (.pane.surfaces | length) == 0 then bad(\$p + ".pane.surfaces"; "needs at least one surface")
       else ([ .pane.surfaces | to_entries[] | . as \$e | (\$e.value | vsurf(\$p + ".pane.surfaces[\\(\$e.key)]")) ] | first_bad) end)
    elif has("direction") then
      (if ((.direction | tostring) as \$d | (\$d == "horizontal" or \$d == "vertical") | not) then bad(\$p + ".direction"; "must be horizontal or vertical")
       elif (.children | type) != "array" or (.children | length) != 2 then bad(\$p + ".children"; "split needs exactly 2 children")
       elif has("split") and (.split | type) != "number" then bad(\$p + ".split"; "must be a number between 0.1 and 0.9")
       else ([(.children[0] | vnode(\$p + ".children[0]")), (.children[1] | vnode(\$p + ".children[1]"))] | first_bad) end)
    else bad(\$p; "node needs pane or direction") end;
  (if type == "object" and has("workspace") and (.workspace | type) == "object" then {doc: (.workspace + {name: (.name // .workspace.name)}), prefix: "\$.workspace.layout"}
   elif type == "object" and has("layout") then {doc: ., prefix: "\$.layout"}
   elif type == "object" and (has("pane") or has("direction")) then {doc: {layout: .}, prefix: "\$"}
   else {doc: {}, prefix: "\$"} end) as \$n
  | if (\$n.doc.layout // null) == null then {error: "\$: no layout found (expected a layout node, {layout: …}, or {workspace: {layout: …}})"}
    else (\$n.doc.layout | vnode(\$n.prefix)) as \$v
      | if \$v != "ok" then {error: \$v}
        else {ok: {name: (\$n.doc.name // null), cwd: (\$n.doc.cwd // null), env: (\$n.doc.env // {}), layout: \$n.doc.layout}} end
    end'

# Plan: one JSON step per line, in the order the Mac builds a layout — a split
# is made before either half is filled, so nested splits land inside the right
# half. Slot 0 is the root pane (its first surface comes from \`workspace run\`);
# every split creates the next slot. cwd/env are resolved here, once.
LAYOUT_PLAN_JQ='
  def clamp: if . < 0.1 then 0.1 elif . > 0.9 then 0.9 else . end;
  def resolve(\$base): if . == null or . == "" then \$base elif startswith("/") then . elif . == "~" then \$home elif startswith("~/") then \$home + .[1:] else \$base + "/" + . end;
  .env as \$wsenv
  | def surface: (.cwd = ((.cwd // "") | resolve(\$base))) | (.env = (\$wsenv + (.env // {})));
  def first_leaf: if has("pane") then . else (.children[0] | first_leaf) end;
  def build(\$slot; \$next):
    if has("pane") then {steps: [{op: "leaf", slot: \$slot, surfaces: [.pane.surfaces[] | surface]}], next: \$next}
    else \$next as \$new
      | {op: "split", slot: \$slot, new: \$new, direction: .direction, ratio: ((.split // 0.5) | clamp),
         cwd: ((.children[1] | first_leaf | .pane.surfaces[0].cwd // "") | resolve(\$base))} as \$s
      | (.children[0] | build(\$slot; \$new + 1)) as \$a
      | (.children[1] | build(\$new; \$a.next)) as \$b
      | {steps: ([\$s] + \$a.steps + \$b.steps), next: \$b.next} end;
  (.layout | first_leaf | .pane.surfaces[0] | surface) as \$root
  | ({op: "root", surface: \$root, terminal: (\$root.type == "terminal")}, ((.layout | build(0; 1)).steps[]))'

layout_tui_json() {
  cmux_ltj_label="\$1"
  shift
  if [ -n "\${cmux_la_first_revision:-}" ]; then
    set -- --expected-revision "\$cmux_la_first_revision" "\$@"
    cmux_la_first_revision=""
  fi
  if cmux_out="\$(tui --json "\$@" 2>&1)"; then :; else die "layout apply: \$cmux_ltj_label failed: \$cmux_out" 1; fi
}

layout_slot_set() {
  printf '%s' "\$2" > "\$cmux_la_scratch/slot.\$1.pane"
  printf '%s' "\$3" > "\$cmux_la_scratch/slot.\$1.ph"
  printf '%s' "\$4" > "\$cmux_la_scratch/slot.\$1.done"
}
layout_slot_get() { cat "\$cmux_la_scratch/slot.\$1.\$2" 2>/dev/null || true; }

# Start a terminal surface: \$1 = pane id ("" = the workspace root via
# \`workspace run\`), \$2 = surface JSON. Sets cmux_new_pane/term/tab.
layout_spawn_terminal() {
  cmux_st_pane="\$1"
  cmux_st_surface="\$2"
  cmux_st_cwd="\$(printf '%s\\n' "\$cmux_st_surface" | jq -r '.cwd // empty')"
  cmux_st_name="\$(printf '%s\\n' "\$cmux_st_surface" | jq -r '.name // empty')"
  cmux_st_pairs="\$(printf '%s\\n' "\$cmux_st_surface" | jq -r '(.env // {}) | to_entries[] | "\\(.key)=\\(.value | tostring)"')"
  set --
  if [ -n "\$cmux_st_cwd" ]; then set -- "\$@" --cwd "\$cmux_st_cwd"; fi
  if [ -n "\$cmux_st_name" ]; then set -- "\$@" --name "\$cmux_st_name"; fi
  set -- "\$@" --
  if [ -n "\$cmux_st_pairs" ]; then
    set -- "\$@" env
    while IFS= read -r cmux_st_pair; do
      [ -n "\$cmux_st_pair" ] || continue
      env_key_ok "\${cmux_st_pair%%=*}" || die "layout apply: invalid env key '\${cmux_st_pair%%=*}' (letters, digits and _ only)" 2
      set -- "\$@" "\$cmux_st_pair"
    done <<EOF
\$cmux_st_pairs
EOF
  fi
  set -- "\$@" bash -l
  # \`--on-exit keep\`: a layout pane whose command exits keeps its tab and final
  # screen instead of vanishing from the layout the person asked for.
  if [ -z "\$cmux_st_pane" ]; then
    layout_tui_json "workspace \$cmux_la_ws run" workspace "\$cmux_la_ws" run --on-exit keep "\$@"
  else
    layout_tui_json "pane \$cmux_st_pane run" pane "\$cmux_st_pane" run --on-exit keep "\$@"
  fi
  cmux_new_pane="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .pane_id // empty')"
  cmux_new_term="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .terminal_id // empty')"
  cmux_new_tab="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .tab_id // empty')"
  [ -n "\$cmux_new_term" ] || die "layout apply: run returned no terminal id: \$cmux_out" 1
  [ -n "\$cmux_new_pane" ] || cmux_new_pane="\$cmux_st_pane"
  [ -n "\$cmux_new_pane" ] || die "layout apply: run returned no pane id: \$cmux_out" 1
}

# A browser tab in pane \$1 for surface \$2. Returns 1 (after a warning) when the
# daemon cannot open browsers here, so the caller keeps the pane's shell.
layout_create_browser() {
  cmux_cb_url="\$(printf '%s\\n' "\$2" | jq -r '.url // empty')"
  cmux_cb_name="\$(printf '%s\\n' "\$2" | jq -r '.name // empty')"
  set -- pane "\$1" tab create browser --url "\$cmux_cb_url"
  if [ -n "\$cmux_cb_name" ]; then set -- "\$@" --name "\$cmux_cb_name"; fi
  if cmux_out="\$(tui --json "\$@" 2>&1)"; then :; else
    warn "browser surface \$cmux_cb_url could not be opened in pane \$1 (the pane keeps its shell): \$cmux_out"
    return 1
  fi
  cmux_new_tab="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .tab_id // empty')"
  cmux_new_browser="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .browser_id // empty')"
  return 0
}

# Type a surface's \`command\` into a terminal that was just started: wait for a
# prompt (bounded; typing early is still safe — the PTY buffers it), then the
# text and Enter, exactly what the Mac does with sendInputWhenReady.
layout_type_command() {
  tui --json terminal "\$1" screen wait --pattern 'λ|\\\$ \$|# \$' --timeout-ms 8000 >/dev/null 2>&1 || true
  tui --json terminal "\$1" write --text "\$2" >/dev/null 2>&1 || warn "could not type into \$1"
  tui --json terminal "\$1" keys enter >/dev/null 2>&1 || warn "could not press enter in \$1"
}

layout_record() {
  # \$1 pane, \$2 surface json, \$3 terminal id, \$4 browser id, \$5 tab id
  jq -cn --arg pane "\$1" --argjson s "\$2" --arg term "\$3" --arg browser "\$4" --arg tab "\$5" '
    {pane_id: \$pane, surface: ({type: \$s.type}
      + (if (\$s.name // "") != "" then {name: \$s.name} else {} end)
      + (if \$term != "" then {terminal_id: \$term} else {} end)
      + (if \$browser != "" then {browser_id: \$browser} else {} end)
      + {tab_id: \$tab})}' >> "\$cmux_la_scratch/summary.jsonl"
}

layout_resolve_path() {
  case "\${2:-}" in
    '') printf '%s' "\$1" ;;
    /*) printf '%s' "\$2" ;;
    '~') printf '%s' "\${HOME:-/root}" ;;
    '~/'*) printf '%s%s' "\${HOME:-/root}" "\${2#\\~}" ;;
    *) printf '%s/%s' "\$1" "\$2" ;;
  esac
}

guest_layout_apply() {
  cmux_la_ws_sel=""
  cmux_la_name=""
  cmux_la_cwd=""
  cmux_la_json=0
  cmux_la_file=""
  cmux_la_reuse=0
  cmux_la_first_revision=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --workspace) [ "\$#" -ge 2 ] || die "layout apply: --workspace needs a value" 2; cmux_la_ws_sel="\$2"; shift 2 ;;
      --workspace=*) cmux_la_ws_sel="\${1#--workspace=}"; shift ;;
      --name) [ "\$#" -ge 2 ] || die "layout apply: --name needs a value" 2; cmux_la_name="\$2"; shift 2 ;;
      --name=*) cmux_la_name="\${1#--name=}"; shift ;;
      --cwd) [ "\$#" -ge 2 ] || die "layout apply: --cwd needs a value" 2; cmux_la_cwd="\$2"; shift 2 ;;
      --cwd=*) cmux_la_cwd="\${1#--cwd=}"; shift ;;
      --json) cmux_la_json=1; shift ;;
      --reuse) cmux_la_reuse=1; shift ;;
      --help|-h) layout_usage; return 0 ;;
      -) cmux_la_file=-; shift ;;
      -*) die "layout apply: unknown option \$1" 2 ;;
      *) [ -z "\$cmux_la_file" ] || die "layout apply: one document at a time" 2; cmux_la_file="\$1"; shift ;;
    esac
  done
  if [ -z "\$cmux_la_file" ]; then
    if [ -t 0 ]; then die "usage: cmux layout apply [--workspace <ws>|--name <n>] [--cwd <dir>] [--json] <file>|-   (or pipe the document in)" 2; fi
    cmux_la_file=-
  fi
  if [ -n "\$cmux_la_ws_sel" ] && [ -n "\$cmux_la_name" ]; then
    die "layout apply: --workspace (build in an existing empty workspace) and --name (create one) are two different targets; pass one" 2
  fi
  cmux_la_scratch="\$(mktemp -d "\${TMPDIR:-/tmp}/cmux-layout.XXXXXX")"
  trap 'rm -rf "\$cmux_la_scratch"' EXIT INT TERM
  : > "\$cmux_la_scratch/warnings"
  : > "\$cmux_la_scratch/summary.jsonl"
  if [ "\$cmux_la_file" = - ]; then
    cat > "\$cmux_la_scratch/doc.json"
  else
    [ -f "\$cmux_la_file" ] || die "layout apply: no such file \$cmux_la_file" 2
    cat "\$cmux_la_file" > "\$cmux_la_scratch/doc.json"
  fi
  if cmux_la_norm="\$(jq -c "\$LAYOUT_NORMALIZE_JQ" "\$cmux_la_scratch/doc.json" 2>&1)"; then :; else
    die "layout apply: the document is not valid JSON: \$cmux_la_norm" 2
  fi
  cmux_la_err="\$(printf '%s\\n' "\$cmux_la_norm" | jq -r '.error // empty')"
  [ -z "\$cmux_la_err" ] || die "layout apply: invalid layout document at \$cmux_la_err" 2
  printf '%s\\n' "\$cmux_la_norm" | jq -c '.ok' > "\$cmux_la_scratch/norm.json"

  cmux_la_home="\${HOME:-/root}"
  [ -n "\$cmux_la_cwd" ] || cmux_la_cwd="\$(jq -r '.cwd // empty' "\$cmux_la_scratch/norm.json")"
  cmux_la_base="\$(layout_resolve_path "\$cmux_la_home" "\$cmux_la_cwd")"
  [ -n "\$cmux_la_name" ] || cmux_la_name="\$(jq -r '.name // empty' "\$cmux_la_scratch/norm.json")"
  [ -n "\$cmux_la_name" ] || cmux_la_name=layout
  jq -c --arg base "\$cmux_la_base" --arg home "\$cmux_la_home" "\$LAYOUT_PLAN_JQ" "\$cmux_la_scratch/norm.json" > "\$cmux_la_scratch/plan.jsonl" \\
    || die "layout apply: could not plan the layout" 1

  if [ "\$cmux_la_reuse" = 1 ] && [ -z "\$cmux_la_ws_sel" ]; then
    cmux_la_created="\$(guest_workspace_get_or_create "\$cmux_la_name" 1)" || return \$?
    [ "\$(printf '%s\\n' "\$cmux_la_created" | jq -r .existing)" != true ] || die_message 1 workspacePreparationChanged
    cmux_la_ws_sel="\$(printf '%s\\n' "\$cmux_la_created" | jq -er '(.value // .) | .id // .workspace_id')" || die_message 1 workspaceReuseUnavailable
  fi

  # The target: an existing EMPTY workspace, or a new one.
  cmux_la_root_pane=""
  cmux_la_root_ph=""
  if [ -n "\$cmux_la_ws_sel" ]; then
    layout_snapshot > "\$cmux_la_scratch/snap.json"
    if [ "\$cmux_la_reuse" = 1 ]; then
      cmux_la_first_revision="\$(jq -er '(.cursor.revision // .session.revision) | select(type == "string" and test("^[0-9]+\$"))' "\$cmux_la_scratch/snap.json")" || die_message 1 workspaceReuseUnavailable
    fi
    cmux_la_resolved="\$(layout_resolve_workspace "\$cmux_la_ws_sel" < "\$cmux_la_scratch/snap.json")"
    cmux_la_ws="\$(printf '%s\\n' "\$cmux_la_resolved" | cut -f 1)"
    cmux_la_ws_name="\$(printf '%s\\n' "\$cmux_la_resolved" | cut -f 2-)"
    cmux_la_count="\$(jq -r --arg ws "\$cmux_la_ws" '
      [ (.screens // [])[] | select(.workspace_id == \$ws) | .id ] as \$screens
      | [ (.panes // [])[] | select(.screen_id as \$sid | \$screens | index(\$sid)) ] | length' "\$cmux_la_scratch/snap.json")"
    [ "\$cmux_la_count" = 0 ] || die "layout apply: workspace \$cmux_la_ws already has a layout (\$cmux_la_count pane\$([ "\$cmux_la_count" = 1 ] || printf s)); pass --name to build a new workspace instead, or empty it first (cmux workspace \$cmux_la_ws close)" 1
  else
    if cmux_out="\$(tui --json workspace create --empty --name "\$cmux_la_name" 2>&1)"; then :; else
      # Older daemons have no --empty; their starter terminal becomes the root placeholder.
      if cmux_out="\$(tui --json workspace create --name "\$cmux_la_name" 2>&1)"; then :; else
        die "layout apply: workspace create failed: \$cmux_out" 1
      fi
    fi
    cmux_la_ws="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .workspace_id // .id // empty')"
    [ -n "\$cmux_la_ws" ] || die "layout apply: workspace create returned no workspace id: \$cmux_out" 1
    cmux_la_root_pane="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .pane_id // empty')"
    cmux_la_root_ph="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .terminal_id // empty')"
    cmux_la_ws_name="\$cmux_la_name"
  fi

  cmux_la_focus=""
  cmux_la_first_pane=""
  # The plan is read on fd 3 so nothing a step runs can eat it from stdin.
  while IFS= read -r cmux_step <&3; do
    cmux_op="\$(printf '%s\\n' "\$cmux_step" | jq -r '.op')"
    case "\$cmux_op" in
      root)
        if [ -n "\$cmux_la_root_pane" ]; then
          layout_slot_set 0 "\$cmux_la_root_pane" "\$cmux_la_root_ph" ""
        elif [ "\$(printf '%s\\n' "\$cmux_step" | jq -r 'if .terminal then 1 else 0 end')" = 1 ]; then
          layout_spawn_terminal "" "\$(printf '%s\\n' "\$cmux_step" | jq -c '.surface')"
          layout_slot_set 0 "\$cmux_new_pane" "" "\$cmux_new_term \$cmux_new_tab"
        else
          layout_spawn_terminal "" '{"type":"terminal"}'
          layout_slot_set 0 "\$cmux_new_pane" "\$cmux_new_term" ""
        fi
        ;;
      split)
        cmux_sp_slot="\$(printf '%s\\n' "\$cmux_step" | jq -r '.slot')"
        cmux_sp_new="\$(printf '%s\\n' "\$cmux_step" | jq -r '.new')"
        cmux_sp_dir="\$(printf '%s\\n' "\$cmux_step" | jq -r 'if .direction == "vertical" then "--down" else "--right" end')"
        # The document stores the first child's share. A right/down pane split
        # asks the daemon for the NEW (second) pane's share instead.
        cmux_sp_ratio="\$(printf '%s\\n' "\$cmux_step" | jq -r '1 - .ratio')"
        cmux_sp_cwd="\$(printf '%s\\n' "\$cmux_step" | jq -r '.cwd // empty')"
        cmux_sp_pane="\$(layout_slot_get "\$cmux_sp_slot" pane)"
        [ -n "\$cmux_sp_pane" ] || die "layout apply: internal error: no pane for slot \$cmux_sp_slot" 1
        set -- pane "\$cmux_sp_pane" split "\$cmux_sp_dir" --ratio "\$cmux_sp_ratio"
        if [ -n "\$cmux_sp_cwd" ]; then set -- "\$@" --cwd "\$cmux_sp_cwd"; fi
        layout_tui_json "pane \$cmux_sp_pane split" "\$@"
        cmux_new_pane="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .pane_id // empty')"
        cmux_new_term="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .terminal_id // empty')"
        [ -n "\$cmux_new_pane" ] || die "layout apply: pane \$cmux_sp_pane split returned no pane id: \$cmux_out" 1
        layout_slot_set "\$cmux_sp_new" "\$cmux_new_pane" "\$cmux_new_term" ""
        ;;
      leaf)
        cmux_lf_slot="\$(printf '%s\\n' "\$cmux_step" | jq -r '.slot')"
        cmux_lf_pane="\$(layout_slot_get "\$cmux_lf_slot" pane)"
        cmux_lf_ph="\$(layout_slot_get "\$cmux_lf_slot" ph)"
        cmux_lf_done="\$(layout_slot_get "\$cmux_lf_slot" done)"
        [ -n "\$cmux_lf_pane" ] || die "layout apply: internal error: no pane for slot \$cmux_lf_slot" 1
        [ -n "\$cmux_la_first_pane" ] || cmux_la_first_pane="\$cmux_lf_pane"
        cmux_lf_count="\$(printf '%s\\n' "\$cmux_step" | jq -r '.surfaces | length')"
        cmux_lf_i=0
        while [ "\$cmux_lf_i" -lt "\$cmux_lf_count" ]; do
          cmux_lf_surface="\$(printf '%s\\n' "\$cmux_step" | jq -c ".surfaces[\$cmux_lf_i]")"
          cmux_lf_type="\$(printf '%s\\n' "\$cmux_lf_surface" | jq -r '.type')"
          cmux_lf_cmd="\$(printf '%s\\n' "\$cmux_lf_surface" | jq -r '.command // empty')"
          cmux_lf_focus="\$(printf '%s\\n' "\$cmux_lf_surface" | jq -r 'if .focus == true then 1 else 0 end')"
          if [ "\$cmux_lf_i" -eq 0 ] && [ -n "\$cmux_lf_done" ]; then
            # The root's first terminal already exists (made by \`workspace run\`).
            cmux_lf_term="\${cmux_lf_done%% *}"
            cmux_lf_tab="\${cmux_lf_done#* }"
            layout_record "\$cmux_lf_pane" "\$cmux_lf_surface" "\$cmux_lf_term" "" "\$cmux_lf_tab"
            if [ -n "\$cmux_lf_cmd" ]; then layout_type_command "\$cmux_lf_term" "\$cmux_lf_cmd"; fi
          else
            case "\$cmux_lf_type" in
              terminal)
                layout_spawn_terminal "\$cmux_lf_pane" "\$cmux_lf_surface"
                layout_record "\$cmux_lf_pane" "\$cmux_lf_surface" "\$cmux_new_term" "" "\$cmux_new_tab"
                if [ "\$cmux_lf_i" -eq 0 ] && [ -n "\$cmux_lf_ph" ]; then
                  tui --json terminal "\$cmux_lf_ph" close >/dev/null 2>&1 || warn "could not close placeholder terminal \$cmux_lf_ph"
                  cmux_lf_ph=""
                fi
                if [ -n "\$cmux_lf_cmd" ]; then layout_type_command "\$cmux_new_term" "\$cmux_lf_cmd"; fi
                ;;
              browser)
                if layout_create_browser "\$cmux_lf_pane" "\$cmux_lf_surface"; then
                  layout_record "\$cmux_lf_pane" "\$cmux_lf_surface" "" "\$cmux_new_browser" "\$cmux_new_tab"
                  if [ "\$cmux_lf_i" -eq 0 ] && [ -n "\$cmux_lf_ph" ]; then
                    tui --json terminal "\$cmux_lf_ph" close >/dev/null 2>&1 || warn "could not close placeholder terminal \$cmux_lf_ph"
                    cmux_lf_ph=""
                  fi
                fi
                ;;
              *)
                warn "project surfaces are Mac-only; skipped one at pane \$cmux_lf_pane"
                ;;
            esac
          fi
          if [ "\$cmux_lf_focus" = 1 ]; then cmux_la_focus="\$cmux_lf_pane"; fi
          cmux_lf_i=\$((cmux_lf_i + 1))
        done
        ;;
    esac
  done 3< "\$cmux_la_scratch/plan.jsonl"

  [ -n "\$cmux_la_focus" ] || cmux_la_focus="\$cmux_la_first_pane"
  if [ -n "\$cmux_la_focus" ]; then
    tui --json pane "\$cmux_la_focus" focus >/dev/null 2>&1 || warn "could not focus pane \$cmux_la_focus"
  fi
  cmux_la_summary="\$(jq -s --arg ws "\$cmux_la_ws" --arg name "\$cmux_la_ws_name" --rawfile w "\$cmux_la_scratch/warnings" '
    reduce .[] as \$e ([];
      if any(.[]; .pane_id == \$e.pane_id) then map(if .pane_id == \$e.pane_id then .surfaces += [\$e.surface] else . end)
      else . + [{pane_id: \$e.pane_id, surfaces: [\$e.surface]}] end)
    | {workspace_id: \$ws, workspace_name: \$name, panes: ., warnings: (\$w | split("\\n") | map(select(. != "")))}' "\$cmux_la_scratch/summary.jsonl")"
  if [ "\$cmux_la_json" -eq 1 ]; then
    printf '%s\\n' "\$cmux_la_summary"
  else
    printf 'OK workspace=%s name=%s panes=%s surfaces=%s\\n' "\$cmux_la_ws" "\$cmux_la_ws_name" \\
      "\$(printf '%s\\n' "\$cmux_la_summary" | jq -r '.panes | length')" \\
      "\$(printf '%s\\n' "\$cmux_la_summary" | jq -r '[.panes[].surfaces | length] | add // 0')"
  fi
}

guest_layout_command() {
  cmux_layout_sub="\${1:-help}"
  [ "\$#" -gt 0 ] && shift
  case "\$cmux_layout_sub" in
    export|get) guest_layout_export "\$@" ;;
    apply|open) guest_layout_apply "\$@" ;;
    help|--help|-h) layout_usage ;;
    *) die "unknown layout command '\$cmux_layout_sub' (try: cmux layout help)" 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Peers.
# ---------------------------------------------------------------------------
peer_file() { printf '%s/%s.json' "\$PEERS_DIR" "\$1"; }

# Establish (or reuse) the headless link to a peer; prints the peer's local mux
# socket path. The link subprocess outlives this command (nohup) so later verbs
# reuse it. Route files are written by the Mac's \`cmux vm link\`.
ensure_link() {
  peer="\$1"
  file="\$(peer_file "\$peer")"
  if [ ! -f "\$file" ]; then
    reflection_discover_peer "\$peer" || die_message 2 missingLink "\$peer" "\$cmux_rd_reason"
  fi
  mkdir -p "\$LINKS_DIR"
  sock_file="\$LINKS_DIR/\$peer.sock-path"
  pid_file="\$LINKS_DIR/\$peer.pid"
  if [ -f "\$sock_file" ] && [ -f "\$pid_file" ] && kill -0 "\$(cat "\$pid_file")" 2>/dev/null; then
    sock="\$(cat "\$sock_file")"
    if [ -S "\$sock" ]; then printf '%s' "\$sock"; return 0; fi
  fi
  route="\$(jq -r .route "\$file")"
  [ -n "\$route" ] && [ "\$route" != null ] || die_message 2 invalidPeer "\$file"
  invite="\$(jq -r '.invite // empty' "\$file")"
  out_file="\$LINKS_DIR/\$peer.connect.jsonl"
  : > "\$out_file"
  set -- remote connect "\$route" --headless --json \\
    --device-name "vm-\$(hostname 2>/dev/null || echo guest)" \\
    --state-dir "\$CMUX_GUEST_HOME/peer-devices"
  if [ -n "\$invite" ]; then
    invite_file="\$LINKS_DIR/\$peer.invite"
    umask 077
    printf '%s' "\$invite" > "\$invite_file"
    set -- "\$@" --invite-file "\$invite_file"
  fi
  umask 077
  connect_dir="\$(mktemp -d "\$LINKS_DIR/.connect.XXXXXX")"
  link_pid=""; relay_pid=""; link_ready=false
  trap 'if [ "\$link_ready" != true ]; then
    [ -z "\$link_pid" ] || kill "\$link_pid" 2>/dev/null || true
    [ -z "\$relay_pid" ] || kill "\$relay_pid" 2>/dev/null || true
  fi
  rm -rf "\$connect_dir"' EXIT
  trap 'exit 130' HUP INT TERM
  mkfifo "\$connect_dir/events" "\$connect_dir/ready"
  exec 3<> "\$connect_dir/ready"
  nohup "\$CMUX_TUI_BIN" "\$@" 3>&- > "\$connect_dir/events" 2>>"\$LINKS_DIR/\$peer.log" &
  link_pid="\$!"
  printf '%s' "\$link_pid" > "\$pid_file"
  nohup /bin/sh -c '
    out_file="\$1"; announced=false
    while IFS= read -r event; do
      printf "%s\\n" "\$event" >> "\$out_file"
      [ "\$announced" = false ] || continue
      socket="\$(printf "%s\\n" "\$event" | jq -r "\$2" 2>/dev/null || true)"
      if [ -n "\$socket" ] && [ -S "\$socket" ]; then
        printf "%s\\n" "\$socket" >&3
        exec 3>&-
        announced=true
      fi
    done
    [ "\$announced" = true ] || printf "\\n" >&3
  ' sh "\$out_file" 'select(.event=="connection-snapshot") | .local_socket // empty' < "\$connect_dir/events" > /dev/null 2>>"\$LINKS_DIR/\$peer.log" &
  relay_pid="\$!"
  printf '%s' "\$relay_pid" > "\$LINKS_DIR/\$peer.events.pid"
  if ! sock="\$(/bin/bash -c 'IFS= read -r -t 30 socket <&3 && printf "%s" "\$socket"')"; then
    die_message 3 linkTimeout "\$peer" "\$LINKS_DIR/\$peer.log"
  fi
  exec 3>&-
  [ -n "\$sock" ] && [ -S "\$sock" ] || die_message 3 linkExited "\$peer" "\$LINKS_DIR/\$peer.log"
  printf '%s' "\$sock" > "\$sock_file"
  jq 'del(.invite)' "\$file" > "\$connect_dir/peer.json" && mv "\$connect_dir/peer.json" "\$file"
  if [ -n "\$invite" ]; then rm -f "\$invite_file"; fi
  link_ready=true
  printf '%s' "\$sock"
}

# The workspace a durable command runs in on the current target: the current
# one, or a fresh \`main\` when the session has none (a brand-new machine).
target_workspace() {
  if tui workspace current show >/dev/null 2>&1; then printf 'current'; return 0; fi
  cmux_tw_creation="\$(tui --json workspace create --name main 2>/dev/null)" || die_message 3 workspaceCreateFailed
  cmux_tw_created="\$(printf '%s' "\$cmux_tw_creation" | jq -r '(.value // .) | .workspace_id // .id // .workspace.id // empty')" || die_message 3 workspaceMissingID
  [ -n "\$cmux_tw_created" ] || die_message 3 workspaceMissingID
  printf '%s' "\$cmux_tw_created"
}

peer_usage() {
  cmux_message peerHelp
}

# agent_wait_terminal <terminal> <timeout-seconds|""> <output 0|1> <json 0|1> <label> <agent> <workspace>:
# block on the daemon's process wait in slices of at most 30 s until the agent
# exits or the timeout passes; with output, page the terminal's stream from
# offset 0. Prints the outcome (or the JSON summary) and returns the agent's
# exit code; a signal or a timeout returns 1 and says so on stderr.
agent_wait_terminal() {
  cmux_aw_term="\$1"
  cmux_aw_timeout="\$2"
  cmux_aw_output="\$3"
  cmux_aw_json="\$4"
  cmux_aw_where="\$5"
  cmux_aw_agent="\$6"
  cmux_aw_ws="\$7"
  cmux_aw_total=""
  [ -z "\$cmux_aw_timeout" ] || cmux_aw_total="\$(timeout_ms "\$cmux_aw_timeout" "agent --wait")"
  cmux_aw_elapsed=0
  cmux_aw_state=pending
  cmux_aw_out='{}'
  while :; do
    cmux_aw_slice=30000
    if [ -n "\$cmux_aw_total" ]; then
      cmux_aw_left=\$((cmux_aw_total - cmux_aw_elapsed))
      [ "\$cmux_aw_left" -gt 0 ] || break
      [ "\$cmux_aw_left" -ge "\$cmux_aw_slice" ] || cmux_aw_slice="\$cmux_aw_left"
    fi
    if cmux_aw_out="\$(tui --json terminal "\$cmux_aw_term" process wait --timeout-ms "\$cmux_aw_slice" 2>&1)"; then :; else
      die "agent --wait: process wait failed for \$cmux_aw_term on \$cmux_aw_where: \$cmux_aw_out" 1
    fi
    cmux_aw_state="\$(printf '%s\\n' "\$cmux_aw_out" | jq -r '(.value // .) | .state // "pending"' 2>/dev/null || printf pending)"
    [ "\$cmux_aw_state" != exited ] || break
    cmux_aw_elapsed=\$((cmux_aw_elapsed + cmux_aw_slice))
  done
  cmux_aw_line="\$(printf '%s\\n' "\$cmux_aw_out" | jq -r '(.value // .) | if .state == "exited" then ((.outcome // {}) | if .kind == "exit" then "exited code=\\(.code)" elif .kind == "signal" then "exited signal=\\(.signal)" else "exited unknown=\\(.reason // "?")" end) else "pending" end' 2>/dev/null || printf pending)"
  cmux_aw_code=1
  case "\$cmux_aw_line" in "exited code="*) cmux_aw_code="\${cmux_aw_line#exited code=}" ;; esac
  case "\$cmux_aw_code" in ''|*[!0-9]*) cmux_aw_code=1 ;; esac
  cmux_aw_text="\$(mktemp "\${TMPDIR:-/tmp}/cmux-agent-out.XXXXXX")"
  cmux_aw_after=0
  if [ "\$cmux_aw_output" -eq 1 ]; then
    while :; do
      if cmux_aw_page="\$(tui --json terminal "\$cmux_aw_term" output read --after "\$cmux_aw_after" 2>&1)"; then :; else
        rm -f "\$cmux_aw_text"
        die "agent --output: output read failed for \$cmux_aw_term on \$cmux_aw_where: \$cmux_aw_page" 1
      fi
      if [ "\$cmux_aw_json" -eq 1 ]; then
        printf '%s\\n' "\$cmux_aw_page" | jq -j '(.value // .) | .text // ""' >> "\$cmux_aw_text" 2>/dev/null || true
      else
        printf '%s\\n' "\$cmux_aw_page" | jq -j '(.value // .) | .text // ""' 2>/dev/null || true
      fi
      cmux_aw_next="\$(printf '%s\\n' "\$cmux_aw_page" | jq -r '(.value // .) | (.next_offset // empty)' 2>/dev/null || true)"
      cmux_aw_complete="\$(printf '%s\\n' "\$cmux_aw_page" | jq -r '(.value // .) | if .complete == true then 1 else 0 end' 2>/dev/null || printf 1)"
      case "\$cmux_aw_next" in ''|*[!0-9]*) cmux_aw_next="\$cmux_aw_after" ;; esac
      [ "\$cmux_aw_next" -gt "\$cmux_aw_after" ] || cmux_aw_complete=1
      cmux_aw_after="\$cmux_aw_next"
      [ "\$cmux_aw_complete" != 1 ] || break
    done
  fi
  if [ "\$cmux_aw_json" -eq 1 ]; then
    jq -n --arg term "\$cmux_aw_term" --arg ws "\$cmux_aw_ws" --arg machine "\$cmux_aw_where" --arg agent "\$cmux_aw_agent" \\
      --arg state "\$cmux_aw_state" --arg line "\$cmux_aw_line" --argjson output "\$cmux_aw_output" --argjson after "\$cmux_aw_after" \\
      --rawfile text "\$cmux_aw_text" '
      {terminal_id: \$term, workspace_id: \$ws, machine: \$machine, agent: \$agent, state: \$state,
       exit_code: ((\$line | capture("^exited code=(?<c>[0-9]+)\$")? | .c | tonumber) // null),
       signal: ((\$line | capture("^exited signal=(?<s>[0-9]+)\$")? | .s | tonumber) // null)}
      + (if \$output == 1 then {output: \$text, next_offset: \$after} else {} end)'
  elif [ "\$cmux_aw_output" -eq 0 ]; then
    printf '%s\\n' "\$cmux_aw_line"
  fi
  rm -f "\$cmux_aw_text"
  case "\$cmux_aw_line" in
    "exited code="*) return "\$cmux_aw_code" ;;
    exited*) printf '%s\\n' "cmux: agent \$cmux_aw_agent on \$cmux_aw_where ended by a signal (\$cmux_aw_line, terminal \$cmux_aw_term)" >&2; return 1 ;;
    *) printf '%s\\n' "cmux: agent \$cmux_aw_agent on \$cmux_aw_where is still running after \${cmux_aw_timeout}s (terminal \$cmux_aw_term; cmux vm terminal wait-exit \$cmux_aw_where \$cmux_aw_term, or cmux vm terminal output \$cmux_aw_where \$cmux_aw_term --after \$cmux_aw_after)" >&2; return 1 ;;
  esac
}

# \`cmux vm agent <peer> --agent <a> [--name n] [--cwd d] [--workspace ws] [--wait [--output] [--timeout s]] -- <args>\`:
# a durable terminal on the peer running the peer's own \`cmux agent\`, so the
# peer's CodeRouter config and machine env apply and the prompt rules match.
# --wait blocks until that terminal's process exits (exit code = the agent's);
# --output then prints its whole terminal stream; --timeout caps the wait.
peer_agent() {
  cmux_pa_peer="\$1"
  shift
  cmux_pa_agent=""
  cmux_pa_name=""
  cmux_pa_cwd=""
  cmux_pa_ws=""
  cmux_pa_wait=0
  cmux_pa_output=0
  cmux_pa_timeout=""
  cmux_pa_json=0
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --agent) [ "\$#" -ge 2 ] || die "vm agent: --agent needs claude, codex, opencode, or pi" 2; cmux_pa_agent="\$2"; shift 2 ;;
      --agent=*) cmux_pa_agent="\${1#--agent=}"; shift ;;
      --name) [ "\$#" -ge 2 ] || die "vm agent: --name needs a value" 2; cmux_pa_name="\$2"; shift 2 ;;
      --name=*) cmux_pa_name="\${1#--name=}"; shift ;;
      --cwd) [ "\$#" -ge 2 ] || die "vm agent: --cwd needs a value" 2; cmux_pa_cwd="\$2"; shift 2 ;;
      --cwd=*) cmux_pa_cwd="\${1#--cwd=}"; shift ;;
      --workspace) [ "\$#" -ge 2 ] || die "vm agent: --workspace needs a value" 2; cmux_pa_ws="\$2"; shift 2 ;;
      --workspace=*) cmux_pa_ws="\${1#--workspace=}"; shift ;;
      --wait) cmux_pa_wait=1; shift ;;
      --output) cmux_pa_output=1; cmux_pa_wait=1; shift ;;
      --timeout) [ "\$#" -ge 2 ] || die "vm agent: --timeout needs seconds" 2; cmux_pa_timeout="\$2"; cmux_pa_wait=1; shift 2 ;;
      --timeout=*) cmux_pa_timeout="\${1#--timeout=}"; cmux_pa_wait=1; shift ;;
      --json) cmux_pa_json=1; shift ;;
      --) shift; break ;;
      claude|codex|opencode|pi) if [ -z "\$cmux_pa_agent" ]; then cmux_pa_agent="\$1"; shift; else break; fi ;;
      *) break ;;
    esac
  done
  [ -n "\$cmux_pa_agent" ] || die "usage: cmux vm agent <machine> --agent <claude|codex|opencode|pi> [--name <n>] [--cwd <dir>] [--workspace <ws>] [--wait [--output] [--timeout <s>]] -- <prompt or args…>" 2
  case "\$cmux_pa_agent" in
    claude|codex|opencode|pi) ;;
    *) die "vm agent: unsupported agent '\$cmux_pa_agent' (choose claude, codex, opencode, or pi)" 2 ;;
  esac
  [ -z "\$cmux_pa_timeout" ] || timeout_ms "\$cmux_pa_timeout" "vm agent" >/dev/null
  use_peer "\$cmux_pa_peer"
  [ -n "\$cmux_pa_ws" ] || cmux_pa_ws="\$(target_workspace)"
  [ -n "\$cmux_pa_name" ] || cmux_pa_name="\$cmux_pa_agent"
  if [ -n "\$cmux_pa_cwd" ]; then
    set -- workspace "\$cmux_pa_ws" run --on-exit keep --name "\$cmux_pa_name" --cwd "\$cmux_pa_cwd" -- cmux agent "\$cmux_pa_agent" "\$@"
  else
    set -- workspace "\$cmux_pa_ws" run --on-exit keep --name "\$cmux_pa_name" -- cmux agent "\$cmux_pa_agent" "\$@"
  fi
  if cmux_out="\$(tui --json "\$@" 2>&1)"; then :; else die "vm agent: could not start \$cmux_pa_agent on \$cmux_pa_peer: \$cmux_out" 1; fi
  cmux_pa_term="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .terminal_id // empty')"
  cmux_pa_wsid="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .workspace_id // empty')"
  if [ "\$cmux_pa_wait" -eq 1 ]; then
    [ -n "\$cmux_pa_term" ] || die "vm agent: \$cmux_pa_peer returned no terminal id, so there is nothing to wait for: \$cmux_out" 1
    if [ "\$cmux_pa_json" -eq 0 ]; then
      printf 'started terminal=%s workspace=%s machine=%s agent=%s; waiting%s\\n' "\$cmux_pa_term" "\${cmux_pa_wsid:-\$cmux_pa_ws}" "\$cmux_pa_peer" "\$cmux_pa_agent" "\${cmux_pa_timeout:+ up to \${cmux_pa_timeout}s}" >&2
    fi
    agent_wait_terminal "\$cmux_pa_term" "\$cmux_pa_timeout" "\$cmux_pa_output" "\$cmux_pa_json" "\$cmux_pa_peer" "\$cmux_pa_agent" "\${cmux_pa_wsid:-\$cmux_pa_ws}" || exit "\$?"
    return 0
  fi
  if [ "\$cmux_pa_json" -eq 1 ]; then
    jq -n --arg term "\${cmux_pa_term:-}" --arg ws "\${cmux_pa_wsid:-\$cmux_pa_ws}" --arg machine "\$cmux_pa_peer" --arg agent "\$cmux_pa_agent" \\
      '{terminal_id: \$term, workspace_id: \$ws, machine: \$machine, agent: \$agent, state: "running"}'
    return 0
  fi
  printf 'OK terminal=%s workspace=%s machine=%s agent=%s (detached: it keeps running on the peer; read it with cmux vm terminal read %s %s)\\n' \\
    "\${cmux_pa_term:-?}" "\${cmux_pa_wsid:-\$cmux_pa_ws}" "\$cmux_pa_peer" "\$cmux_pa_agent" "\$cmux_pa_peer" "\${cmux_pa_term:-<term>}"
}

# peer_deliver <label> <MARKER> <terminal-name> <scratch-dir> <payload-file> -- <receiver argv…>:
# the sending half of a receive handshake on the current peer target. Starts the
# receiver in a durable terminal (--on-exit keep: its final OK/ERR line must stay
# readable), waits for CMUX-<MARKER>-READY (echo is off by then), types the
# payload as 76-column base64 lines plus CMUX-<MARKER>-END in 1 KiB writes, reads
# one CMUX-<MARKER>-(OK|ERR) line and closes the terminal. Sets cmux_pd_line to
# that line ("" when the receiver never answered). Payload bytes travel only
# inside the typed stream: never in a run argv (visible in process lists) and
# never through a control plane. Transport failures remove <scratch-dir> and die.
peer_deliver() {
  cmux_pd_label="\$1"
  cmux_pd_marker="\$2"
  cmux_pd_name="\$3"
  cmux_pd_dir="\$4"
  cmux_pd_payload="\$5"
  shift 5
  [ "\${1:-}" = "--" ] && shift
  cmux_pd_verb="\$(printf '%s' "\$cmux_pd_marker" | tr 'A-Z' 'a-z')"
  cmux_pd_ws="\$(target_workspace)"
  if cmux_out="\$(tui --json workspace "\$cmux_pd_ws" run --on-exit keep --name "\$cmux_pd_name" -- "\$@" 2>&1)"; then :; else
    rm -rf "\$cmux_pd_dir"; die "\$cmux_pd_label: could not start the receiver on \$TARGET_LABEL: \$cmux_out" 1
  fi
  cmux_pd_term="\$(printf '%s\\n' "\$cmux_out" | jq -r '(.value // .) | .terminal_id // empty')"
  [ -n "\$cmux_pd_term" ] || { rm -rf "\$cmux_pd_dir"; die "\$cmux_pd_label: the receiver on \$TARGET_LABEL returned no terminal id: \$cmux_out" 1; }
  cmux_pd_ready="\$(tui --json terminal "\$cmux_pd_term" screen wait --pattern "CMUX-\$cmux_pd_marker-READY" --timeout-ms 15000 2>/dev/null || true)"
  if [ "\$(printf '%s\\n' "\$cmux_pd_ready" | jq -r '(.value // .) | if .matched == true then 1 else 0 end' 2>/dev/null || printf 0)" != 1 ]; then
    cmux_pd_seen="\$(printf '%s\\n' "\$cmux_pd_ready" | jq -r '(.value // .) | .text // ""' 2>/dev/null | grep -Eo "CMUX-\$cmux_pd_marker-ERR[^[:cntrl:]]*" | tail -n 1 || true)"
    tui --json terminal "\$cmux_pd_term" close >/dev/null 2>&1 || true
    rm -rf "\$cmux_pd_dir"
    [ -z "\$cmux_pd_seen" ] || die "\$cmux_pd_label on \$TARGET_LABEL failed: \${cmux_pd_seen#CMUX-\$cmux_pd_marker-ERR }" 1
    die "\$cmux_pd_label: the receiver on \$TARGET_LABEL never became ready (its cmux shim may predate \$cmux_pd_verb receive; reconnect the machine to heal it)" 1
  fi
  { base64 < "\$cmux_pd_payload" | tr -d '\\n' | fold -w 76; printf '\\nCMUX-%s-END\\n' "\$cmux_pd_marker"; } > "\$cmux_pd_dir/stream"
  split -b 1024 "\$cmux_pd_dir/stream" "\$cmux_pd_dir/piece."
  for cmux_pd_piece in "\$cmux_pd_dir"/piece.*; do
    [ -f "\$cmux_pd_piece" ] || continue
    cmux_pd_b64="\$(base64 < "\$cmux_pd_piece" | tr -d '\\n')"
    if ! tui --json terminal "\$cmux_pd_term" write --bytes-base64 "\$cmux_pd_b64" >/dev/null 2>&1; then
      tui --json terminal "\$cmux_pd_term" close >/dev/null 2>&1 || true
      rm -rf "\$cmux_pd_dir"
      die "\$cmux_pd_label: the link to \$TARGET_LABEL dropped while sending" 1
    fi
  done
  cmux_pd_result="\$(tui --json terminal "\$cmux_pd_term" screen wait --pattern "CMUX-\$cmux_pd_marker-(OK|ERR)" --timeout-ms 30000 2>/dev/null || true)"
  cmux_pd_line="\$(printf '%s\\n' "\$cmux_pd_result" | jq -r '(.value // .) | .text // ""' 2>/dev/null | grep -Eo "CMUX-\$cmux_pd_marker-(OK|ERR)[^[:cntrl:]]*" | tail -n 1 || true)"
  tui --json terminal "\$cmux_pd_term" close >/dev/null 2>&1 || true
}

# \`cmux vm env set <peer> …\`: values onto a peer through its \`cmux env receive\`.
peer_env_set() {
  cmux_pe_peer="\$1"
  shift
  cmux_pe_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/cmux-env-send.XXXXXX")"
  env_collect_input "\$cmux_pe_dir/payload" "\$@"
  cmux_pe_n="\$(grep -c . "\$cmux_pe_dir/payload" || true)"
  cmux_pe_names="\$(sed 's/=.*//' "\$cmux_pe_dir/payload" | tr '\\n' ' ')"
  use_peer "\$cmux_pe_peer"
  peer_deliver "vm env set" ENV "cmux env" "\$cmux_pe_dir" "\$cmux_pe_dir/payload" -- cmux env receive
  rm -rf "\$cmux_pe_dir"
  case "\$cmux_pd_line" in
    CMUX-ENV-OK*)
      printf 'OK set %s variable%s on %s: %s(new cmux shells and agents there see them)\\n' "\$cmux_pe_n" "\$([ "\$cmux_pe_n" = 1 ] || printf s)" "\$cmux_pe_peer" "\$cmux_pe_names"
      ;;
    CMUX-ENV-ERR*)
      die "vm env set on \$cmux_pe_peer failed: \${cmux_pd_line#CMUX-ENV-ERR }" 1
      ;;
    *)
      die "vm env set: no answer from the receiver on \$cmux_pe_peer within 30s" 1
      ;;
  esac
}

# \`cmux vm push <peer> <local-file> <remote-path> [--mode <octal>] [--json]\`:
# one file onto a linked machine through its \`cmux file receive\`, the handshake
# the Mac's \`cmux vm push --secret\` uses. Single files up to 256 KiB, always
# over the link: secret-safe by construction, so there is no --secret flag here.
peer_push() {
  cmux_pp_peer="\$1"
  shift
  cmux_pp_local=""
  cmux_pp_remote=""
  cmux_pp_mode=600
  cmux_pp_json=0
  cmux_pp_usage="usage: cmux vm push <machine> <local-file> <remote-path> [--mode <octal>] [--json]"
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --mode) [ "\$#" -ge 2 ] || die "vm push: --mode needs an octal mode such as 600 or 755" 2; cmux_pp_mode="\$2"; shift 2 ;;
      --mode=*) cmux_pp_mode="\${1#--mode=}"; shift ;;
      --json) cmux_pp_json=1; shift ;;
      --help|-h) peer_usage; return 0 ;;
      --secret) shift ;;
      -*) die "vm push: unknown option \$1 (\$cmux_pp_usage)" 2 ;;
      *)
        if [ -z "\$cmux_pp_local" ]; then cmux_pp_local="\$1"
        elif [ -z "\$cmux_pp_remote" ]; then cmux_pp_remote="\$1"
        else die "vm push: one local file and one remote path (\$cmux_pp_usage)" 2; fi
        shift ;;
    esac
  done
  [ -n "\$cmux_pp_local" ] && [ -n "\$cmux_pp_remote" ] || die "\$cmux_pp_usage" 2
  file_mode_ok "\$cmux_pp_mode" || die "vm push: --mode takes an octal mode such as 600 or 755, got '\$cmux_pp_mode'" 2
  [ ! -d "\$cmux_pp_local" ] || die "vm push: \$cmux_pp_local is a directory; from inside a machine push one file at a time (tar it first)" 2
  [ -f "\$cmux_pp_local" ] && [ -r "\$cmux_pp_local" ] || die "vm push: cannot read \$cmux_pp_local" 2
  cmux_pp_bytes="\$(wc -c < "\$cmux_pp_local" | tr -d ' ')"
  [ "\$cmux_pp_bytes" -gt 0 ] || die "vm push: \$cmux_pp_local is empty" 2
  [ "\$cmux_pp_bytes" -le 262144 ] || die "vm push: \$cmux_pp_local is \$cmux_pp_bytes bytes; the link carries files up to 262144 bytes (256 KiB)" 2
  cmux_pp_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/cmux-file-send.XXXXXX")"
  use_peer "\$cmux_pp_peer"
  peer_deliver "vm push" FILE "cmux file" "\$cmux_pp_dir" "\$cmux_pp_local" -- cmux file receive "\$cmux_pp_remote" --mode "\$cmux_pp_mode"
  rm -rf "\$cmux_pp_dir"
  case "\$cmux_pd_line" in
    CMUX-FILE-OK*)
      cmux_pp_rest="\${cmux_pd_line#CMUX-FILE-OK }"
      cmux_pp_landed="\${cmux_pp_rest#*path=}"
      cmux_pp_landed="\${cmux_pp_landed% mode=*}"
      [ -n "\$cmux_pp_landed" ] || cmux_pp_landed="\$cmux_pp_remote"
      if [ "\$cmux_pp_json" -eq 1 ]; then
        jq -n --arg machine "\$cmux_pp_peer" --arg path "\$cmux_pp_landed" --arg mode "\$cmux_pp_mode" --argjson bytes "\$cmux_pp_bytes" \\
          '{machine: \$machine, path: \$path, bytes: \$bytes, mode: \$mode, transport: "link"}'
      else
        printf 'OK %s on %s (%s bytes, mode %s) delivered over the link\\n' "\$cmux_pp_landed" "\$cmux_pp_peer" "\$cmux_pp_bytes" "\$cmux_pp_mode"
      fi
      ;;
    CMUX-FILE-ERR*)
      die "vm push to \$cmux_pp_peer failed: \${cmux_pd_line#CMUX-FILE-ERR }" 1
      ;;
    *)
      die "vm push: no answer from the receiver on \$cmux_pp_peer within 30s" 1
      ;;
  esac
}

# \`cmux vm workspace new|rename|close|rm <peer> …\` in the Mac's spelling.
# Name-based creation is fenced by the authoritative daemon revision. Only a
# revision conflict retries; a failed mutation is never blindly repeated.
guest_workspace_get_or_create() {
  cmux_gc_name="\$1"; cmux_gc_empty="\$2"; cmux_gc_attempt=0
  [ -n "\$cmux_gc_name" ] || die_message 2 workspaceReuseNeedsName
  while [ "\$cmux_gc_attempt" -lt 8 ]; do
    cmux_gc_attempt=\$((cmux_gc_attempt + 1))
    cmux_gc_snapshot="\$(layout_snapshot)"
    cmux_gc_plan="\$(printf '%s\\n' "\$cmux_gc_snapshot" | jq -ce --arg name "\$cmux_gc_name" '
      (.value // .) | select((.workspaces | type) == "array")
      | {matches: [.workspaces[] | select(.name == \$name)], revision: (.cursor.revision // .session.revision)}
      | select((.revision | type) == "string" and (.revision | test("^[0-9]+\$")))
    ')" || die_message 1 workspaceReuseUnavailable
    cmux_gc_count="\$(printf '%s\\n' "\$cmux_gc_plan" | jq -r '.matches | length')"
    [ "\$cmux_gc_count" -le 1 ] || die_message 2 workspaceReuseAmbiguous
    if [ "\$cmux_gc_count" = 1 ]; then
      printf '%s\\n' "\$cmux_gc_plan" | jq -ce '{value: .matches[0], existing: true}'
      return
    fi
    cmux_gc_revision="\$(printf '%s\\n' "\$cmux_gc_plan" | jq -r .revision)"
    set -- --json --expected-revision "\$cmux_gc_revision" workspace create --name "\$cmux_gc_name"
    [ "\$cmux_gc_empty" != 1 ] || set -- "\$@" --empty
    if cmux_gc_out="\$(tui "\$@" 2>&1)"; then
      printf '%s\\n' "\$cmux_gc_out" | jq -ce 'select(type == "object") | . + {existing: false}'
      return
    fi
    cmux_gc_code="\$(printf '%s\\n' "\$cmux_gc_out" | jq -r '.code // .error.code // empty' 2>/dev/null)" || cmux_gc_code=""
    [ "\$cmux_gc_code" = revision.conflict ] || die "\$cmux_gc_out" 1
  done
  die_message 1 workspaceReuseUnavailable
}

workspace_verb() {
  cmux_pw_verb="\$1"
  cmux_pw_peer="\$TARGET_LABEL"
  shift
  case "\$cmux_pw_verb" in
    new)
      cmux_pw_json=""
      cmux_pw_name=""
      cmux_pw_reuse=0
      while [ "\$#" -gt 0 ]; do
        case "\$1" in
          --name) [ "\$#" -ge 2 ] || die "vm workspace new: --name needs a value" 2; cmux_pw_name="\$2"; shift 2 ;;
          --name=*) cmux_pw_name="\${1#--name=}"; shift ;;
          --json) cmux_pw_json=--json; shift ;;
          --no-open) shift ;;
          --reuse) cmux_pw_reuse=1; shift ;;
          *) die "vm workspace new: unknown option \$1" 2 ;;
        esac
      done
      if [ "\$cmux_pw_reuse" = 1 ]; then
        cmux_pw_result="\$(guest_workspace_get_or_create "\$cmux_pw_name" 0)" || return \$?
        if [ -n "\$cmux_pw_json" ]; then printf '%s\\n' "\$cmux_pw_result"; else
          printf '%s\\n' "\$cmux_pw_result" | jq -r '(.value // .) | .id // .workspace_id'
        fi
        return
      fi
      if [ -n "\$cmux_pw_name" ]; then exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" \$cmux_pw_json workspace create --name "\$cmux_pw_name"; fi
      exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" \$cmux_pw_json workspace create
      ;;
    rm|delete)
      [ "\$#" -ge 1 ] || die "usage: cmux vm workspace rm <machine> <ws>" 2
      cmux_pw_ws="\$1"
      cmux_pw_snap="\$(layout_snapshot)"
      cmux_pw_terms="\$(printf '%s\\n' "\$cmux_pw_snap" | jq -r --arg ws "\$cmux_pw_ws" '
        [ (.screens // [])[] | select(.workspace_id == \$ws) | .id ] as \$screens
        | [ (.panes // [])[] | select(.screen_id as \$sid | \$screens | index(\$sid)) | .id ] as \$panes
        | [ (.tabs // [])[] | select(.content_kind == "terminal" and (.pane_id as \$pid | \$panes | index(\$pid))) | .content_id ] | unique | .[]')"
      cmux_pw_killed=0
      for cmux_pw_term in \$cmux_pw_terms; do
        tui terminal "\$cmux_pw_term" close >/dev/null 2>&1 || warn "could not close terminal \$cmux_pw_term"
        cmux_pw_killed=\$((cmux_pw_killed + 1))
      done
      tui workspace "\$cmux_pw_ws" close >/dev/null
      printf 'OK deleted workspace %s on %s (%s terminal%s closed)\\n' "\$cmux_pw_ws" "\$cmux_pw_peer" "\$cmux_pw_killed" "\$([ "\$cmux_pw_killed" = 1 ] || printf s)"
      ;;
  esac
}

case "\${1:-}" in
  --version|-v|version)
    cmux_message version
    exec "\$CMUX_TUI_BIN" --version
    ;;
  --help|help|"")
    guest_usage
    ;;
  auth)
    shift
    auth_sub="\${1:-status}"
    [ "\$#" -gt 0 ] && shift
    case "\$auth_sub" in
      status) guest_auth_status "\$@" ;;
      login|logout) host_only_command "cmux auth \$auth_sub" ;;
      help|--help|-h) guest_usage ;;
      *) die_message 2 unknownAuth "\$auth_sub" ;;
    esac
    ;;
  login|logout)
    host_only_command "cmux \$1"
    ;;
  coderouter|cr)
    shift
    guest_coderouter_command "\$@"
    ;;
  agent)
    shift
    guest_agent_command "\$@"
    ;;
  ai-accounts|remotes)
    host_only_command "cmux \$1"
    ;;
  self|whoami|reflect|reflection)
    shift
    guest_self "\$@"
    ;;
  env)
    shift
    guest_env_command "\$@"
    ;;
  file)
    shift
    guest_file_command "\$@"
    ;;
  layout)
    shift
    guest_layout_command "\$@"
    ;;
  tree)
    shift
    for cmux_arg in "\$@"; do
      case "\$cmux_arg" in
        --json) ;;
        *) die "usage: cmux tree [--json]  (this machine's workspace/terminal snapshot; cmux vm tree <machine> for a peer)" 2 ;;
      esac
    done
    exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" --json session current snapshot
    ;;
  new-workspace)
    shift
    workspace_verb new "\$@"
    ;;
  new-split)
    shift
    cmux_ns_dir="\${1:-}"
    case "\$cmux_ns_dir" in
      right|down) shift ;;
      left|up) die "new-split: the daemon splits to the right or down only (the new pane lands right of / below the pane); use right or down" 2 ;;
      *) die "usage: cmux new-split <right|down> [--pane <pane_id>]" 2 ;;
    esac
    cmux_ns_pane=""
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --pane) [ "\$#" -ge 2 ] || die "new-split: --pane needs a pane id" 2; cmux_ns_pane="\$2"; shift 2 ;;
        --pane=*) cmux_ns_pane="\${1#--pane=}"; shift ;;
        --json) shift ;;
        *) die "usage: cmux new-split <right|down> [--pane <pane_id>]" 2 ;;
      esac
    done
    [ -n "\$cmux_ns_pane" ] || cmux_ns_pane="\$(default_pane)"
    exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" pane "\$cmux_ns_pane" split "--\$cmux_ns_dir"
    ;;
  send|send-key|read-screen)
    local_terminal_alias "\$@"
    ;;
  workspace|pane|tab)
    cmux_noun="\$1"; shift
    guest_topology_command "\$cmux_noun" "\$@"
    ;;
  terminal)
    # The Mac's verb-first spelling (\`terminal send <id> …\`); cmux-tui's own
    # id-first grammar (\`terminal <id> write …\`, \`terminal list\`) passes through.
    case "\${2:-}" in
      help|--help|-h)
        terminal_usage
        ;;
      send|write|read|screen|wait|wait-exit|output|close|rename|move)
        cmux_verb="\$2"
        cmux_term="\${3:-}"
        shift 2
        [ "\$#" -gt 0 ] && shift
        terminal_verb "\$cmux_verb" "\$cmux_term" "\$@"
        ;;
      *)
        exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" "\$@"
        ;;
    esac
    ;;
  vm)
    shift
    sub="\${1:-}"; [ "\$#" -gt 0 ] && shift
    case "\$sub" in
      ls|list|peers|links)
        guest_vm_ls "\$@"
        ;;
      connect)
        peer="\${1:-}"; [ -n "\$peer" ] || die_message 2 connectUsage
        sock="\$(ensure_link "\$peer")"
        cmux_message connected "\$peer" "\$sock"
        ;;
      exec)
        peer="\${1:-}"; [ -n "\$peer" ] || die_message 2 execUsage
        shift
        [ "\${1:-}" = "--" ] && shift
        [ "\$#" -gt 0 ] || die_message 2 execUsage
        use_peer "\$peer"
        sock="\$TARGET_VALUE"
        # A fresh session has no current workspace; create one and run in it by id.
        target="\$(target_workspace)"
        exec "\$CMUX_TUI_BIN" --socket "\$sock" workspace "\$target" run --on-exit close -- "\$@"
        ;;
      push)
        # The Mac spelling puts --secret first; here every push is link-typed, so it is accepted and means nothing extra.
        [ "\${1:-}" != --secret ] || shift
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm push <machine> <local-file> <remote-path> [--mode <octal>]" 2
        shift
        peer_push "\$peer" "\$@"
        ;;
      terminal)
        case "\${1:-}" in
          help|--help|-h) terminal_usage ;;
          send|write|read|screen|wait|wait-exit|output|close|rename|move)
            cmux_verb="\$1"
            peer="\${2:-}"
            cmux_term="\${3:-}"
            [ -n "\$peer" ] || die "usage: cmux vm terminal \$cmux_verb <machine> <term> …" 2
            shift 2
            [ "\$#" -gt 0 ] && shift
            use_peer "\$peer"
            terminal_verb "\$cmux_verb" "\$cmux_term" "\$@"
            ;;
          *)
            peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm terminal <machine> [args…]" 2
            shift
            use_peer "\$peer"
            exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" terminal "\$@"
            ;;
        esac
        ;;
      send|send-key|read-screen)
        peer="\${1:-}"
        cmux_term="\${2:-}"
        [ -n "\$peer" ] && [ -n "\$cmux_term" ] || die "usage: cmux vm \$sub <machine> <term> …" 2
        shift 2
        use_peer "\$peer"
        case "\$sub" in
          send) [ "\$#" -gt 0 ] || die "usage: cmux vm send <machine> <term> <text>" 2; exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" terminal "\$cmux_term" write --text "\$*" ;;
          send-key) [ "\$#" -gt 0 ] || die "usage: cmux vm send-key <machine> <term> <key> [key…]" 2; exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" terminal "\$cmux_term" keys "\$@" ;;
          read-screen)
            cmux_rs_json=""
            for cmux_arg in "\$@"; do case "\$cmux_arg" in --json) cmux_rs_json=--json ;; *) die "usage: cmux vm read-screen <machine> <term> [--json]" 2 ;; esac; done
            # shellcheck disable=SC2086
            exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" \$cmux_rs_json terminal "\$cmux_term" screen read
            ;;
        esac
        ;;
      workspace)
        case "\${1:-}" in
          help|--help|-h|"") cmux_message topologyHelp ;;
          new|rename|close|rm|delete|move|focus|list|ls|show)
            cmux_verb="\$1"; peer="\${2:-}"
            [ -n "\$peer" ] || die_message 2 topologyUsage
            shift 2
            use_peer "\$peer"
            guest_topology_command workspace "\$cmux_verb" "\$@"
            ;;
          *)
            peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm workspace <machine> [args…]" 2
            shift
            use_peer "\$peer"
            exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" workspace "\$@"
            ;;
        esac
        ;;
      agent)
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm agent <machine> --agent <claude|codex|opencode|pi> -- <prompt or args…>" 2
        case "\${2:-}" in
          --agent|--agent=*|claude|codex|opencode|pi|--wait|--output|--timeout|--timeout=*|--name|--name=*|--cwd|--cwd=*|--workspace|--workspace=*) peer_agent "\$@" ;;
          *)
            shift
            use_peer "\$peer"
            exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" agent "\$@"
            ;;
        esac
        ;;
      layout)
        cmux_layout_sub="\${1:-}"
        peer="\${2:-}"
        case "\$cmux_layout_sub" in
          export|get|apply|open) ;;
          *) die "usage: cmux vm layout export|apply <machine> [options]  (see cmux layout help)" 2 ;;
        esac
        [ -n "\$peer" ] || die "usage: cmux vm layout \$cmux_layout_sub <machine> [options]" 2
        shift 2
        use_peer "\$peer"
        guest_layout_command "\$cmux_layout_sub" "\$@"
        ;;
      env)
        cmux_env_sub="\${1:-}"
        peer="\${2:-}"
        case "\$cmux_env_sub" in
          set|ls|list|rm|unset|remove|path) ;;
          *) die "usage: cmux vm env set|ls|rm|path <machine> …  (see cmux env help)" 2 ;;
        esac
        [ -n "\$peer" ] || die "usage: cmux vm env \$cmux_env_sub <machine> …" 2
        shift 2
        if [ "\$cmux_env_sub" = set ]; then
          peer_env_set "\$peer" "\$@"
        else
          # Names only ever ride argv here; values go through peer_env_set.
          use_peer "\$peer"
          target="\$(target_workspace)"
          exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" workspace "\$target" run --on-exit close -- cmux env "\$cmux_env_sub" "\$@"
        fi
        ;;
      pane|tab)
        case "\${1:-}" in
          help|--help|-h|"") cmux_message topologyHelp ;;
          list|ls|show|rename|focus|close|move|split|swap|zoom|resize)
            cmux_verb="\$1"; peer="\${2:-}"
            [ -n "\$peer" ] || die_message 2 topologyUsage
            shift 2
            use_peer "\$peer"
            guest_topology_command "\$sub" "\$cmux_verb" "\$@"
            ;;
          *)
            peer="\$1"; shift
            use_peer "\$peer"
            guest_topology_command "\$sub" "\$@"
            ;;
        esac
        ;;
      tui|tree|session|screen|browser)
        # cmux vm <verb> <machine> [args…] → the same cmux-tui verb on the peer.
        peer="\${1:-}"; [ -n "\$peer" ] || die_message 2 peerUsage "\$sub"
        shift
        use_peer "\$peer"
        if [ "\$sub" = tui ]; then exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE"; fi
        if [ "\$sub" = tree ]; then exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" --json session current snapshot; fi
        exec "\$CMUX_TUI_BIN" "\$TARGET_FLAG" "\$TARGET_VALUE" "\$sub" "\$@"
        ;;
      ""|help|--help|-h)
        peer_usage
        ;;
      *) die_message 2 unknownVM "\$sub" ;;
    esac
    ;;
  notify)
    # Mac-CLI compatible \`cmux notify\` inside a machine (agent hooks call it
    # with --title/--subtitle/--body). cmux-tui's own \`notify\` verb takes the
    # macOS signature: it stores --subtitle as its own field, scopes --clear,
    # refuses --reply, and validates any selector it is handed, so the shim
    # forwards the arguments verbatim and the daemon stays the one place that
    # knows the grammar. Nothing here can name a Mac workspace, surface, or
    # socket: those selectors are rejected by the daemon rather than mapped.
    shift
    # Silent on success like the Mac CLI, unless the caller asked for the
    # JSON result: --quiet and --json are exclusive global output modes.
    cmux_notify_json=
    for cmux_notify_arg in "\$@"; do
      case "\$cmux_notify_arg" in
        --json|--jsonl) cmux_notify_json=1; break ;;
      esac
    done
    if [ -n "\$cmux_notify_json" ]; then
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" notify "\$@"
    fi
    exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" --quiet notify "\$@"
    ;;
  *)
    # Local daemon session. cmux-tui's own grammar is \`cmux <resource> <action>\`.
    local_alias "\$@" 2>/dev/null || exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" "\$@"
    ;;
esac
`;

/** Shell command installing the shim (idempotent; safe to run on every heal). */
export function guestCliInstallCommand(): string {
  const encoded = Buffer.from(GUEST_CMUX_SHIM, "utf8").toString("base64");
  return [
    `printf '%s' '${encoded}' | base64 -d > ${GUEST_CMUX_SHIM_PATH}.tmp`,
    `chmod 0755 ${GUEST_CMUX_SHIM_PATH}.tmp`,
    `mv ${GUEST_CMUX_SHIM_PATH}.tmp ${GUEST_CMUX_SHIM_PATH}`,
  ].join(" && ");
}
