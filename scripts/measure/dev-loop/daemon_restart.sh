#!/usr/bin/env bash
# Goal dev-loop-ceiling, loop daemon_restart: a one-line Rust edit to the daemon's `identify` going live in a
# running terminal daemon with its terminals kept, through `cmux live start --rust`'s own loop
# (scripts/cmux-next/rust-live.py, building here), split into stages (fs_event, compile, link, swap,
# first_answer, unattributed), with each stage's floor measured beside it on the same host.
#   scripts/measure/dev-loop/daemon_restart.sh OUT [N]
# Writes OUT/daemon_restart.json (schema dev-loop-ceiling/loop/v1); exit 0 when it measured.
# The daemon is a scratch one (socket, state and home in a temporary folder), never the host's. The
# edited file and the touched binary root are put back on exit, and only processes this run started
# are stopped. Fleet Mac:
#   cmux-ci run --class exclusive --os macos --measurement --script scripts/measure/dev-loop/daemon_restart.sh \
#     --ref SHA --arg=.build/dlc-daemon_restart --arg=5 --artifact .build/dlc-daemon_restart --timeout 3600
set -euo pipefail
out="${1:?usage: daemon_restart.sh OUT [N]}"
n="${2:-5}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
here="$root/scripts/measure/dev-loop/daemon_restart"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
edited="$root/cmux-tui/crates/cmux-tui/src/bin/cmux-tui/identify.rs"
bin_root="$root/cmux-tui/crates/cmux-tui/src/bin/cmux-tui.rs"
core_edited="$root/cmux-tui/crates/cmux-tui-core/src/server/cmd_server.rs"  # the core_edit_s round
scratch="$(mktemp -d /tmp/dlc-dr-sh.XXXXXX)"
cp -p "$edited" "$scratch/edited.rs"
cp -p "$bin_root" "$scratch/bin.rs"
cp -p "$core_edited" "$scratch/core.rs"
restore() {
  # measure.py puts both back itself; this is for a run that died before its own cleanup.
  cmp -s "$scratch/edited.rs" "$edited" || cp "$scratch/edited.rs" "$edited"
  cmp -s "$scratch/bin.rs" "$bin_root" || cp "$scratch/bin.rs" "$bin_root"
  cmp -s "$scratch/core.rs" "$core_edited" || cp "$scratch/core.rs" "$core_edited"
  rm -rf "$scratch"
}
trap restore EXIT

fail_json() {
  python3 - "$out/daemon_restart.json" "$1" "$root" <<'EOF'
import json, socket, subprocess, sys, time
path, error, root = sys.argv[1:4]
commit = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
json.dump({"schema": "dev-loop-ceiling/loop/v1", "loop": "daemon_restart", "commit": commit,
           "host": socket.gethostname(), "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "target": "cmux-tui-core edit through cmux live start --rust", "error": error, "rounds": [],
           "floors_ms": {}, "graph": {}, "notes": []}, open(path, "w"), indent=2)
EOF
}

# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as rust-dev-loop.sh does).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next || { fail_json "ghostty-next submodule init failed"; exit 1; }
fi
# Zig's packages, fetched with retries before any clock starts (the warm build would fetch them otherwise).
"$root/scripts/ci/fetch-ghostty-zig-packages.sh" "$root/ghostty-next" \
  || echo "notice: fetch-ghostty-zig-packages.sh failed; the warm build fetches them itself"

# The fs_event floor's helper: FSEvents on macOS, inotify on Linux.
fs_bin="$scratch/fs_event_latency"
if [[ "$(uname -s)" == Darwin ]]; then
  cc -O2 -o "$fs_bin" "$here/fs_event_latency.c" -framework CoreServices || fs_bin=""
else
  cc -O2 -o "$fs_bin" "$here/fs_event_latency.c" || fs_bin=""
fi

code=0
python3 "$here/measure.py" --out "$out" --runs "$n" --fs-event-bin "$fs_bin" \
  2> >(tee "$out/measure.log" >&2) || code=$?
[[ -f "$out/daemon_restart.json" ]] || fail_json "measure.py exited $code without a report"
# A fleet step (cmux-ci run --artifact) brings back what is in $FAST_CHECKS_OUT.
if [[ -n "${FAST_CHECKS_OUT:-}" && "$out" != "$FAST_CHECKS_OUT" ]]; then
  mkdir -p "$FAST_CHECKS_OUT" && cp -R "$out/." "$FAST_CHECKS_OUT/"
fi
exit "$code"
