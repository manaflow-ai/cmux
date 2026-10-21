#!/usr/bin/env bash
# agent-session-start host gate against REAL machine markers (cx-d0tq): needs
# sudo, so it runs only on a throwaway Linux box (a Blacksmith Testbox), never
# on a workstation. It creates and removes /srv/team, /etc/cmux/image-stamp
# and /etc/cmux/vm-kind. Usage, from cmux-tui/ after `cargo build -p cmux-tui`:
#   bash scripts/smoke-agent-start-host.sh
# Every probe prints "<machine state>: <error_code>" and the script exits 1 on
# the first answer that differs from the expected one.
set -euo pipefail
bin="$PWD/target/debug/cmux-tui"
probe() {
  local label="$1" want="$2" root; root="$(mktemp -d /tmp/amp.XXXXXX)"; mkdir -p "$root/home" "$root/acpmux" "$root/work" "$root/state"; chmod 700 "$root/acpmux" "$root/state"
  printf '{"harnesses":{"fake":{"argv":["python3","%s"],"family":"fake"}},"defaultHarness":"fake"}' \
    "$PWD/crates/acpmux/tests/fake_agent.py" > "$root/acpmux/config.json"
  run() { env -i PATH=/usr/bin:/bin HOME="$root/home" TMPDIR="$root" ACPMUX_HOME="$root/acpmux" CMUX_TUI_STATE_DIR="$root/state" CMUX_TUI_CONFIG="$root/home/x.toml" "$bin" "$@"; }
  ensured="$(run --session amp --json server ensure)"
  local rc=0
  python3 - "$ensured" "$root/work" "$label" "$want" <<'PY' || rc=1
import json, socket, sys
ensured, work, label = sys.argv[1:4]
ep = json.loads([l for l in ensured.splitlines() if l.strip().startswith("{")][-1])
s = socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(ep["socket"]); f = s.makefile()
def req(i, o):
    s.sendall((json.dumps({"id": i, **o}) + "\n").encode())
    while True:
        m = json.loads(f.readline())
        if m.get("id") == i: return m
sid = req(1, {"cmd": "identify"})["data"]["session_id"]
req(2, {"cmd": "new-workspace"})
tab = req(3, {"cmd": "new-conversation-tab", "agent_session": {"host": "registry:" + sid}})["data"]["surface"]
r = req(4, {"cmd": "agent-session-start", "surface": tab, "cwd": work})
got = r.get("error_code") or "ok"
print(f"{label}: {got}")
sys.exit(0 if got == sys.argv[4] else 1)
PY
  run --session amp --json server stop --end-terminals >/dev/null 2>&1 || true
  run acp daemon shutdown --end-agents >/dev/null 2>&1 || true
  [ "$rc" = 0 ] || { echo "expected $want" >&2; exit 1; }
}
cleanup() { sudo rm -rf /srv/team /etc/cmux/image-stamp /etc/cmux/vm-kind; sudo chmod 0755 /etc/cmux 2>/dev/null || true; }
trap cleanup EXIT
cleanup
U=agent_session.untrusted_folder T=agent_session.team_vm_blocked H=agent_session.host_unverified
probe "plain linux host (no markers)" $U
getent group cmux-ssh >/dev/null || sudo groupadd cmux-ssh
sudo install -d -o root -g cmux-ssh -m 2750 /srv/team
probe "no Cloud marker + /srv/team root:cmux-ssh" $T
sudo rm -rf /srv/team
sudo install -d -o root -g root -m 0755 /etc/cmux
printf 'team\n' | sudo tee /etc/cmux/vm-kind >/dev/null; sudo chmod 0644 /etc/cmux/vm-kind
probe "no Cloud marker + vm-kind team" $T
sudo rm -f /etc/cmux/vm-kind
printf 'cmux-vm inputs=proof\n' | sudo tee /etc/cmux/image-stamp >/dev/null; sudo chmod 0644 /etc/cmux/image-stamp
probe "Cloud stamp, no kind record" $H
printf 'owner\n' | sudo tee /etc/cmux/vm-kind >/dev/null; sudo chmod 0644 /etc/cmux/vm-kind
probe "Cloud stamp + vm-kind owner (owner VM)" $U
sudo chmod 0664 /etc/cmux/vm-kind
probe "Cloud stamp + group-writable vm-kind owner" $H
sudo chmod 0644 /etc/cmux/vm-kind; sudo chmod 0775 /etc/cmux
probe "Cloud stamp + vm-kind owner in a group-writable /etc/cmux" $H
sudo chmod 0755 /etc/cmux
sudo chown "$(id -u)" /etc/cmux/vm-kind
probe "Cloud stamp + vm-kind owner not owned by root" $H
sudo chown root /etc/cmux/vm-kind
printf 'team\n' | sudo tee /etc/cmux/vm-kind >/dev/null
probe "Cloud stamp + vm-kind team" $T
printf 'owner\n' | sudo tee /etc/cmux/vm-kind >/dev/null
sudo install -d -o root -g cmux-ssh -m 2750 /srv/team
probe "Cloud stamp + vm-kind owner + /srv/team" $T
sudo rm -rf /srv/team
fake="$(mktemp -d)/kind"; printf 'owner\n' > "$fake"; sudo rm -f /etc/cmux/vm-kind; sudo ln -s "$fake" /etc/cmux/vm-kind
probe "Cloud stamp + vm-kind symlink" $H
echo "SMOKE OK"
