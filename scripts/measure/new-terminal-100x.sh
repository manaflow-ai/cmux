#!/usr/bin/env bash
# New-terminal latency through the cmux-tui daemon (new-terminal-100x): Cmd-T / Ctrl-` new tab,
# split right and new workspace, each timed from send to reply and from send to the terminal's
# shell running (cmux-tui/scripts/bench-terminal-create.py), plus the processes and memory each
# live terminal costs. Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/new-terminal-100x.sh --ref SHA
#     [--arg=rounds=N] [--arg=against=SHA] [--arg=max_p50_ms=X] [--arg=disk_load=N]
# The binary is the commit's published cmux-tui tree, or a release build when unpublished.
# against=SHA runs that commit's binary too, interleaved pass by pass. max_p50_ms=X fails the
# step when any of this commit's first-text p50 is above X ms. Each run also measures login
# mode (labels *-login): as the app, so every shell starts through login(1). disk_load=N runs every pass again with N
# background writers that write and F_FULLFSYNC in a loop (labels *-load), as on a busy Mac.
set -euo pipefail
rounds=40
against=""
max_p50=""
disk_load=0
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    against=*) against="${arg#against=}" ;;
    max_p50_ms=*) max_p50="${arg#max_p50_ms=}" ;;
    disk_load=*) disk_load="${arg#disk_load=}" ;;
    *) echo "new-terminal-100x.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
case "$rounds" in [1-9]|[1-9][0-9]|[1-2][0-9][0-9]) ;; *) echo "new-terminal-100x.sh: rounds must be 1-299" >&2; exit 2 ;; esac
case "$disk_load" in [0-9]|1[0-6]) ;; *) echo "new-terminal-100x.sh: disk_load must be 0-16" >&2; exit 2 ;; esac
case "$max_p50" in ""|[0-9]*) ;; *) echo "new-terminal-100x.sh: max_p50_ms must be a number" >&2; exit 2 ;; esac
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/new-terminal-100x"
rm -rf "$work"
mkdir -p "$work"
echo "CREATE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD)"
echo "CREATE-LOAD before $(uptime | sed 's/.*load averages*: //')"
status=0

binary() { # label revision
  local key sum base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
  key="$(python3 scripts/ci/cmux_tui_tree_key.py "$2")"
  if curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin" -o "$work/bin-$1"; then
    sum="$(curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
    [ "$(shasum -a 256 "$work/bin-$1" | awk '{print $1}')" = "$sum" ] || { echo "CREATE sha256 mismatch for $1 ($key)" >&2; exit 1; }
    echo "CREATE-BIN $1 rev=$2 published key=$key"
  else
    echo "CREATE-BIN $1 rev=$2 key=$key not published; building it"
    local src="$work/src-$1"
    git worktree add --detach "$src" "$2" >/dev/null
    (cd "$src" && export CI=1 && git submodule update --init --depth 1 ghostty-next >/dev/null \
      && cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
    cp "$work/target/release/cmux-tui" "$work/bin-$1"
    git worktree remove --force "$src"
  fi
  chmod +x "$work/bin-$1"
}

ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
if [ -n "$against" ]; then
  git cat-file -e "$against^{commit}" 2>/dev/null || git fetch --quiet origin "$against"
  binary against "$against"
fi
binary ref HEAD
state_root="$(mktemp -d /private/tmp/ntc.XXXXXX)"
trap 'rm -rf "$state_root"' EXIT
passes=2
per=$(( (rounds + passes - 1) / passes ))
# Modes: plain (isolated HOME, no login(1)), load (plus disk_load writers), login (as the
# app: a frontend client and the account's HOME, so shells start through login(1)).
modes="plain login"
[ "$disk_load" -gt 0 ] && modes="plain load login"
for mode in $modes; do
  suffix="" load=0 extra=""
  case "$mode" in
    load) suffix="-load" load="$disk_load" ;;
    login) suffix="-login" extra="--login" ;;
  esac
  for pass in $(seq 1 "$passes"); do
    for label in against ref; do
      [ -x "$work/bin-$label" ] || continue
      # shellcheck disable=SC2086
      python3 -I cmux-tui/scripts/bench-terminal-create.py --bin "$work/bin-$label" --rounds "$per" \
        --disk-load "$load" $extra --label "$label$suffix-p$pass" --root-dir "$state_root" --spans \
        --out "$work/$label$suffix-p$pass.json" || status=$?
    done
  done
done
python3 -I - "$work" "$max_p50" <<'PY' || status=$?
import glob, json, os, sys
work, max_p50 = sys.argv[1], sys.argv[2]
bad = False
for label in ("against", "ref", "against-load", "ref-load", "against-login", "ref-login"):
    merged = {}
    for path in sorted(glob.glob(os.path.join(work, f"{label}-p*.json"))):
        for op, d in json.load(open(path))["ops"].items():
            merged.setdefault(op, []).extend(d["samples_ms"])
    for op, s in merged.items():
        s.sort()
        q = lambda p: s[min(len(s) - 1, int(p * len(s)))]
        print(f'CREATE-RESULT {label} op="{op}" n={len(s)} p50={q(0.5):.2f} p95={q(0.95):.2f} max={s[-1]:.2f}')
        if label == "ref" and max_p50 and op.endswith(" first-text") and q(0.5) > float(max_p50):
            bad = True
if bad:
    print(f"CREATE-RESULT FAIL: a first-text p50 is above {max_p50} ms")
    sys.exit(1)
PY
echo "CREATE-LOAD after $(uptime | sed 's/.*load averages*: //')"
exit "$status"
