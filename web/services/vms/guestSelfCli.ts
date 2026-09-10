// The in-VM `cmux` command, self-discovery edition: `cmux self` says which
// machine this is, `cmux vm ls` lists the team's machines with this one
// marked. Both read `GET /api/vm/self` through the machine's TLS edge, which
// adds the VM-bound route token on the wire; the guest sends only the public
// placeholder bearer (services/coderouter/vmGuestEnv.ts).
//
// Installed by the driver on every attach and, when missing, in the same
// round trip as any `vm exec`, so it reaches machines created from any
// existing snapshot without a rebake. POSIX sh plus curl and jq,
// which the devbox image ships. Every other verb is refused with a pointer to
// the Mac CLI, so an agent learns the boundary from the tool, not from a doc.

export const GUEST_CMUX_SELF_SHIM_PATH = "/usr/local/bin/cmux";

export const GUEST_CMUX_SELF_SHIM = `#!/bin/sh
# cmux — inside a cmux Cloud machine. Self-discovery only; every other verb
# runs on the Mac. Managed by cmux, reinstalled on attach; do not edit.
set -eu

case "\${LC_ALL:-\${LC_MESSAGES:-\${LANG:-en}}}" in
  ja*) cmux_lang=ja ;;
  *) cmux_lang=en ;;
esac

msg() {
  key="$1"; shift
  case "$cmux_lang/$key" in
    en/help) printf '%s' 'cmux (inside a cmux Cloud machine)

  cmux self [--json]     which machine this is: name, id, status, team
  cmux vm ls [--json]    the team'"'"'s machines, this one marked with *
  cmux notify [flags]    post a notification from this machine (Mac flags: --title, --subtitle, --body, --clear, --surface)

Every other cmux verb (vm new, vm exec, vm push, …) runs on the Mac
cmux CLI. This machine holds no account token; the TLS edge authenticates it.
' ;;
    ja/help) printf '%s' 'cmux（cmux Cloud マシン内）

  cmux self [--json]     このマシンの名前、ID、状態、チーム
  cmux vm ls [--json]    チームのマシン一覧。このマシンには * が付きます
  cmux notify [flags]    このマシンから通知を送ります（Mac と同じフラグ: --title、--subtitle、--body、--clear、--surface）

その他の cmux コマンド（vm new、vm exec、vm push など）は Mac の
cmux CLI で実行してください。このマシンはアカウントトークンを持たず、
TLS エッジが認証します。
' ;;
    en/hostOnly) printf 'cmux: %s runs on the Mac cmux CLI, not inside a machine (try cmux --help)\\n' "$@" ;;
    en/noDaemon) printf 'cmux: %s needs the cmux-tui daemon, which is not installed in this machine\\n' "$@" ;;
    ja/noDaemon) printf 'cmux: %s には cmux-tui デーモンが必要ですが、このマシンにはインストールされていません\\n' "$@" ;;
    ja/hostOnly) printf 'cmux: %s は Mac の cmux CLI で実行してください。マシン内では使えません（cmux --help を参照）\\n' "$@" ;;
    en/noEdge) printf 'cmux: no cmux API endpoint in this machine (CMUX_CODEROUTER_URL is missing)\\n' ;;
    ja/noEdge) printf 'cmux: このマシンに cmux API エンドポイントがありません（CMUX_CODEROUTER_URL が未設定）\\n' ;;
    en/unreachable) printf 'cmux: cannot reach the cmux API from this machine (%s): %s\\n' "$@" ;;
    ja/unreachable) printf 'cmux: このマシン（%s）から cmux API に到達できません: %s\\n' "$@" ;;
    en/rejected) printf 'cmux: the cmux API rejected this machine (HTTP %s): %s\\n' "$@" ;;
    ja/rejected) printf 'cmux: cmux API がこのマシンを拒否しました（HTTP %s）: %s\\n' "$@" ;;
    en/badOption) printf 'cmux: unknown option %s\\n' "$@" ;;
    ja/badOption) printf 'cmux: 不明なオプション %s\\n' "$@" ;;
    en/thisMachine) printf 'this machine' ;;
    ja/thisMachine) printf 'このマシン' ;;
    en/team) printf 'team' ;;
    ja/team) printf 'チーム' ;;
    en/machines) printf 'machines' ;;
    ja/machines) printf 'マシン' ;;
  esac
}

die() { status="$1"; shift; msg "$@" >&2; exit "$status"; }

load_env() {
  if [ -f "\${HOME:-/root}/.config/cmux/model-plane.env" ]; then
    . "\${HOME:-/root}/.config/cmux/model-plane.env"
  elif [ -f /etc/cmux/model-plane.env ]; then
    . /etc/cmux/model-plane.env
  fi
  [ -n "\${CMUX_CODEROUTER_URL:-}" ] || die 2 noEdge
}

# One request; body on stdout, HTTP status in $http_status. A transport failure
# (DNS, TLS, timeout) exits 1 with curl's own reason so the cause is visible.
fetch_self() {
  load_env
  set -- --silent --show-error --connect-timeout 5 --max-time 20 \\
    --header "authorization: Bearer \${OPENAI_API_KEY:-cmux-vm-edge-placeholder}" \\
    --header "accept: application/json" \\
    --write-out '\\n%{http_code}'
  if [ -f /usr/local/share/ca-certificates/freestyle-tls.crt ]; then
    set -- --cacert /usr/local/share/ca-certificates/freestyle-tls.crt "$@"
  fi
  if ! raw="$(curl "$@" "\${CMUX_CODEROUTER_URL%/}/api/vm/self" 2>&1)"; then
    # curl still appends the --write-out status ("000") after its error line;
    # the error line is the reason worth showing. The edge becomes active
    # about half a minute after a machine boots, so a fresh machine can land
    # here once before the same command succeeds.
    reason="$(printf '%s' "$raw" | grep -m 1 '^curl:' || printf '%s' "$raw" | sed '$d' | tail -n 1)"
    die 1 unreachable "$(hostname 2>/dev/null || echo unknown)" "\${reason:-$raw}"
  fi
  http_status="$(printf '%s' "$raw" | tail -n 1)"
  body="$(printf '%s' "$raw" | sed '$d')"
  case "$http_status" in
    200) ;;
    *) die 1 rejected "$http_status" "$(printf '%s' "$body" | jq -r '.message // .error // "unexpected response"' 2>/dev/null || echo "$body")" ;;
  esac
}

want_json() {
  json=0
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      --help|-h) msg help; exit 0 ;;
      *) die 2 badOption "$arg" ;;
    esac
  done
}

cmd_self() {
  want_json "$@"
  fetch_self
  if [ "$json" -eq 1 ]; then printf '%s\\n' "$body"; return 0; fi
  printf '%s' "$body" | jq -r --arg self "$(msg thisMachine)" --arg team "$(msg team)" --arg machines "$(msg machines)" '
    "\\(.machine.name)\\t\\(.machine.id)\\t\\(.machine.status)\\t(\\($self))",
    "\\($team)\\t\\(.team.id)\\t\\(.machines | length) \\($machines)"'
}

cmd_vm_ls() {
  want_json "$@"
  fetch_self
  if [ "$json" -eq 1 ]; then printf '%s' "$body" | jq -c '{machines: .machines}'; printf '\\n'; return 0; fi
  printf '%s' "$body" | jq -r '.machines[] | "\\(if .self then "*" else " " end) \\(.name)\\t\\(.id)\\t\\(.status)"'
}

case "\${1:-}" in
  self) shift; cmd_self "$@" ;;
  notify|notification)
    # Notifications live in this machine's cmux-tui daemon; the Mac derives
    # its unread state from them. Same flags as the macOS cmux notify. Inside
    # a daemon terminal CMUX_TUI_SOCKET is set; elsewhere (vm exec, cron) the
    # daemon's own session socket is the target, never a default "main".
    tui="\${CMUX_TUI_BIN:-/usr/local/bin/cmux-tui}"
    if [ -x "$tui" ]; then
      if [ -z "\${CMUX_TUI_SOCKET:-}" ]; then
        run_dir="\${CMUX_TUI_RUN_DIR:-/tmp/cmux-tui-$(id -u)}"
        if [ -S "$run_dir/cloud.sock" ]; then exec "$tui" --socket "$run_dir/cloud.sock" "$@"; fi
      fi
      exec "$tui" "$@"
    fi
    die 2 noDaemon "cmux $1"
    ;;
  vm)
    shift
    case "\${1:-}" in
      ls|list) shift; cmd_vm_ls "$@" ;;
      ""|--help|-h|help) msg help ;;
      *) die 2 hostOnly "cmux vm $1" ;;
    esac
    ;;
  ""|--help|-h|help) msg help ;;
  --version|-v|version) printf 'cmux guest self-discovery CLI\\n' ;;
  *) die 2 hostOnly "cmux $1" ;;
esac
`;

/**
 * One idempotent exec that installs the shim: base64 keeps the script
 * byte-exact through any shell, and the temp-then-rename keeps a concurrent
 * `cmux` invocation from ever seeing a half-written file.
 */
export function guestSelfCliInstallCommand(): string {
  const encoded = Buffer.from(GUEST_CMUX_SELF_SHIM, "utf8").toString("base64");
  const tmp = `${GUEST_CMUX_SELF_SHIM_PATH}.tmp.$$`;
  return [
    `printf '%s' '${encoded}' | base64 -d > ${tmp}`,
    `chmod 0755 ${tmp}`,
    `mv -f ${tmp} ${GUEST_CMUX_SELF_SHIM_PATH}`,
  ].join(" && ");
}
