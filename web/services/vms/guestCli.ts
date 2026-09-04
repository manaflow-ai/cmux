// The in-VM `cmux` CLI: a POSIX shim over the machine's own cmux-tui binary.
//
// Every cmux Cloud machine runs the cmux-tui daemon (session "cloud"), and the
// same static binary is a full client. cmux-tui's public grammar is already
// `cmux <resource> <action>`, so local verbs forward directly; the shim adds a
// `cmux vm …` namespace for talking to OTHER machines through cmux-remote
// links the Mac granted with `cmux vm link <src> <dst>` (peer route files in
// ~/.cmux/peers). The shim is provider-agnostic: it only needs the daemon
// binary and route files, never a provider SDK.
//
// Installed by the driver at create/heal (see freestyle.ts bootstrap), so it
// reaches machines created from any existing snapshot.

export const GUEST_CMUX_SHIM_PATH = "/usr/local/bin/cmux";

export const GUEST_CMUX_SHIM = `#!/bin/sh
# cmux — in-VM CLI over this machine's cmux-tui daemon and linked peer machines.
# Local verbs forward to cmux-tui (session "cloud"). \`cmux vm …\` talks to peers
# this machine was linked to from the Mac (\`cmux vm link <src> <dst>\`).
set -eu

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

die() { printf '%s\\n' "cmux: \$1" >&2; exit "\${2:-1}"; }

[ -x "\$CMUX_TUI_BIN" ] || die "cmux-tui daemon binary not found at \$CMUX_TUI_BIN"

peer_file() { printf '%s/%s.json' "\$PEERS_DIR" "\$1"; }

# Establish (or reuse) the headless link to a peer; prints the peer's local mux
# socket path. The link subprocess outlives this command (nohup) so later verbs
# reuse it. Route files are written by the Mac's \`cmux vm link\`.
ensure_link() {
  peer="\$1"
  file="\$(peer_file "\$peer")"
  [ -f "\$file" ] || die "no link for machine '\$peer'. From the Mac: cmux vm link <this-machine> \$peer" 2
  mkdir -p "\$LINKS_DIR"
  sock_file="\$LINKS_DIR/\$peer.sock-path"
  pid_file="\$LINKS_DIR/\$peer.pid"
  if [ -f "\$sock_file" ] && [ -f "\$pid_file" ] && kill -0 "\$(cat "\$pid_file")" 2>/dev/null; then
    sock="\$(cat "\$sock_file")"
    if [ -S "\$sock" ]; then printf '%s' "\$sock"; return 0; fi
  fi
  route="\$(jq -r .route "\$file")"
  [ -n "\$route" ] && [ "\$route" != null ] || die "malformed peer file \$file" 2
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
  nohup "\$CMUX_TUI_BIN" "\$@" > "\$out_file" 2>>"\$LINKS_DIR/\$peer.log" &
  printf '%s' "\$!" > "\$pid_file"
  i=0
  while [ "\$i" -lt 150 ]; do
    # The headless client emits jsonl; the connection-snapshot event names the
    # local mux socket (field \`local_socket\`, same contract the Mac app parses).
    sock="\$(jq -r 'select(.event=="connection-snapshot") | .local_socket // empty' "\$out_file" 2>/dev/null | head -n 1 || true)"
    if [ -n "\$sock" ] && [ -S "\$sock" ]; then
      printf '%s' "\$sock" > "\$sock_file"
      # The single-use invitation is consumed by a successful connect.
      jq 'del(.invite)' "\$file" > "\$file.tmp" && mv "\$file.tmp" "\$file"
      printf '%s' "\$sock"
      return 0
    fi
    kill -0 "\$(cat "\$pid_file")" 2>/dev/null || die "link to '\$peer' exited; see \$LINKS_DIR/\$peer.log" 3
    i=\$((i + 1)); sleep 0.2
  done
  die "link to '\$peer' did not come up in 30s; see \$LINKS_DIR/\$peer.log" 3
}

case "\${1:-}" in
  vm)
    shift
    sub="\${1:-}"; [ "\$#" -gt 0 ] && shift
    case "\$sub" in
      ls|list)
        # This machine, then every linked peer.
        printf '%s\\t%s\\n' "\$(hostname 2>/dev/null || echo local)" "(this machine)"
        if [ -d "\$PEERS_DIR" ]; then
          for f in "\$PEERS_DIR"/*.json; do
            [ -e "\$f" ] || continue
            name="\$(basename "\$f" .json)"
            state=linked
            pidf="\$LINKS_DIR/\$name.pid"
            if [ -f "\$pidf" ] && kill -0 "\$(cat "\$pidf")" 2>/dev/null; then state=connected; fi
            printf '%s\\t%s\\n' "\$name" "\$state"
          done
        fi
        ;;
      connect)
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm connect <machine>" 2
        sock="\$(ensure_link "\$peer")"
        printf 'OK connected %s socket=%s\\n' "\$peer" "\$sock"
        ;;
      exec)
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm exec <machine> -- <command…>" 2
        shift
        [ "\${1:-}" = "--" ] && shift
        [ "\$#" -gt 0 ] || die "usage: cmux vm exec <machine> -- <command…>" 2
        sock="\$(ensure_link "\$peer")"
        # A fresh session has no current workspace; create one and run in it by id.
        target=current
        if ! "\$CMUX_TUI_BIN" --socket "\$sock" workspace current get >/dev/null 2>&1; then
          created="\$("\$CMUX_TUI_BIN" --socket "\$sock" --json workspace create --name main 2>/dev/null | jq -r '.id // .workspace_id // .workspace.id // empty' | head -n 1)"
          [ -n "\$created" ] && target="\$created"
        fi
        exec "\$CMUX_TUI_BIN" --socket "\$sock" workspace "\$target" run --on-exit close -- "\$@"
        ;;
      tui|tree|workspace|terminal|session|pane|tab|screen|browser|agent)
        # cmux vm <verb> <machine> [args…] → the same cmux-tui verb on the peer.
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm \$sub <machine> [args…]" 2
        shift
        sock="\$(ensure_link "\$peer")"
        if [ "\$sub" = tui ]; then exec "\$CMUX_TUI_BIN" --socket "\$sock"; fi
        if [ "\$sub" = tree ]; then exec "\$CMUX_TUI_BIN" --socket "\$sock" --json session current snapshot; fi
        exec "\$CMUX_TUI_BIN" --socket "\$sock" "\$sub" "\$@"
        ;;
      ""|help|--help|-h)
        cat <<'EOF'
cmux vm — talk to other cmux Cloud machines from inside this one.

  cmux vm ls                          linked machines and their link state
  cmux vm connect <machine>           bring up the link (done lazily otherwise)
  cmux vm exec <machine> -- <cmd…>    run a command on the peer (durable terminal)
  cmux vm tree <machine>              the peer's workspace/terminal snapshot
  cmux vm <resource> <machine> …      any cmux-tui resource verb on the peer

Links are granted from the Mac: cmux vm link <this-machine> <peer>.
Local verbs need no prefix: cmux workspace…, cmux terminal…, cmux session….
EOF
        ;;
      *) die "unknown vm subcommand '\$sub' (try: cmux vm help)" 2 ;;
    esac
    ;;
  notify)
    # Mac-CLI compatible \`cmux notify\` inside a machine (agent hooks call it
    # with --title/--subtitle/--body). cmux-tui's verb is \`notification create\`;
    # the notification lands in this machine's daemon ledger and the user's Mac
    # picks it up from the session event stream it already follows. The Mac
    # attributes it to the pane showing this terminal, so the daemon-assigned
    # CMUX_TUI_TERMINAL_ID is the only selector that means anything here: Mac
    # topology selectors are ignored, --subtitle folds into the body (cmux-tui
    # has no such field), and only the levels the daemon accepts are forwarded.
    # Nothing here can name a Mac workspace, surface, or socket.
    shift
    title=""; subtitle=""; body=""; level=""; terminal="\${CMUX_TUI_TERMINAL_ID:-}"
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --title) title="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --title=*) title="\${1#--title=}"; shift ;;
        --subtitle) subtitle="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --subtitle=*) subtitle="\${1#--subtitle=}"; shift ;;
        --body) body="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --body=*) body="\${1#--body=}"; shift ;;
        --level) level="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --level=*) level="\${1#--level=}"; shift ;;
        --terminal) terminal="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --terminal=*) terminal="\${1#--terminal=}"; shift ;;
        --workspace|--surface|--window|--tab|--panel) shift; [ "\$#" -gt 0 ] && shift ;;
        *) shift ;;
      esac
    done
    [ -n "\$title" ] || title=Notification
    if [ -n "\$subtitle" ]; then
      if [ -n "\$body" ]; then body="\$subtitle — \$body"; else body="\$subtitle"; fi
    fi
    set -- notification create --title "\$title" --body "\$body"
    case "\$level" in info|warning|error) set -- "\$@" --level "\$level" ;; esac
    if [ -n "\$terminal" ]; then set -- "\$@" --terminal "\$terminal"; fi
    exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" --quiet "\$@"
    ;;
  ""|help|--help|-h)
    "\$CMUX_TUI_BIN" --help 2>&1 || true
    printf '\\nIn-VM extras: cmux vm help (talk to linked cmux Cloud machines)\\n'
    ;;
  *)
    # Local daemon session. cmux-tui's own grammar is \`cmux <resource> <action>\`.
    exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" "\$@"
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
