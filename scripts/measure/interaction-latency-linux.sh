#!/usr/bin/env bash
# The nightly interaction latency benches on an exclusive build-fleet Linux worker (.github/workflows/
# nightly-interaction-latency.yml), not on a cmux-linux runner. The pool packs two runners onto each 8-vCPU VM
# (skills/infra/linux-runner-pool), so a bench shared about 4 vCPUs with another job: there Playwright's WebKit drew
# its fastest frame in 37 ms, and composer typing read 117 ms at p99 (run 46074259108). The same commit on an
# exclusive 32-vCPU worker read 17 ms (fleet job 755fb9d831f5445af002c99f), and a bare contenteditable on 4 pinned
# CPUs reads 30-39 ms at p99 against 16 ms with all of them. The perf cron's Linux parts run on these workers for
# the same reason (scripts/measure/perf-cron-linux.sh).
#   cmux-ci run --class exclusive --measurement --os linux --label measure \
#     --script scripts/measure/interaction-latency-linux.sh --ref SHA --arg=interactions=KEY,KEY \
#     --artifact artifacts/interaction-latency/results.json
# KEY is an interaction of scripts/ci/nightly_interaction_latency.py (INTERACTIONS). The one artifact is its `run`
# command's results.json, which the workflow's `report` step reads as if the runner job had run the benches.
# Exit 0 when results.json was written (a failed bench is in it), 1 when it was not.
set -uo pipefail
interactions=""
for arg in "$@"; do
  case "$arg" in
    interactions=*) interactions="${arg#interactions=}" ;;
    *) echo "interaction-latency-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[ -n "$interactions" ] || { echo "usage: interaction-latency-linux.sh interactions=KEY[,KEY...]" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 2
cache="${CMUX_CI_CACHE_DIR:-$HOME/.cache/cmux-ci}"
tools="$cache/tools"
out="$root/artifacts/interaction-latency"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

echo "interaction-latency-linux.sh: $(hostname) nproc=$(nproc) load $(cut -d' ' -f1-3 /proc/loadavg)"

# The pinned bun, beside the cache as perf-cron-linux.sh keeps it.
bun_pin="$(python3 -I scripts/webviews_bun_version.py webviews/package.json)" || exit 1
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ]; then
  if [ ! -x "$tools/bun-$bun_pin/bin/bun" ]; then
    mkdir -p "$tools"
    curl -fsSL https://bun.sh/install | BUN_INSTALL="$tools/bun-$bun_pin" bash -s "bun-v$bun_pin" || exit 1
  fi
  export PATH="$tools/bun-$bun_pin/bin:$PATH"
fi
(cd webviews && bash ../scripts/ci/bun-install.sh --frozen-lockfile) || exit 1

# node for node_modules/.bin/playwright (`#!/usr/bin/env node`): the pool's own, else bun (perf-cron-linux.sh).
if ! command -v node >/dev/null 2>&1; then
  mkdir -p "$work/node-bin"
  node_bin=""
  for candidate in /opt/node-v*/bin/node; do [ -x "$candidate" ] && node_bin="$candidate"; done
  [ -n "$node_bin" ] || node_bin="$(command -v bun)" || exit 1
  ln -sfn "$node_bin" "$work/node-bin/node"
  export PATH="$work/node-bin:$PATH"
fi

# Playwright's WebKit with its system libraries, and the system Chrome, as the runner job's "Install Playwright".
playwright_version="$(cd webviews && python3 -I -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2>/dev/null || echo unknown)"
export PLAYWRIGHT_BROWSERS_PATH="$cache/playwright-$playwright_version"
(cd webviews && ./node_modules/.bin/playwright install --with-deps webkit) || exit 1
chrome_out="$(cd webviews && "$root/scripts/ci/ensure-system-chrome.sh")" || exit 1
printf '%s\n' "$chrome_out"
shell_line="$(printf '%s\n' "$chrome_out" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -1 || true)"
[ -n "$shell_line" ] && export CMUX_CHROME_HEADLESS_SHELL="${shell_line#CMUX_CHROME_HEADLESS_SHELL=}"

# The plan the runner job made, rebuilt from its interaction keys in its order.
python3 -I - "$interactions" "$(git rev-parse HEAD)" "$work/plan.json" <<'PY' || exit 1
import json, sys
sys.path.insert(0, "scripts/ci")
import nightly_interaction_latency as nil
keys, head, dest = sys.argv[1].split(","), sys.argv[2], sys.argv[3]
unknown = [k for k in keys if k not in nil.INTERACTIONS]
if unknown:
    sys.exit(f"interaction-latency-linux.sh: unknown interactions {unknown}")
json.dump({"schema": nil.SCHEMA, "head": head, "run": [{"key": k, "bench": nil.INTERACTIONS[k][0]} for k in keys]},
          open(dest, "w"))
PY
python3 -I scripts/ci/nightly_interaction_latency.py run --plan "$work/plan.json" --webviews webviews --out "$out"
[ -f "$out/results.json" ] || { echo "interaction-latency-linux.sh: no results.json" >&2; exit 1; }
echo "interaction-latency-linux.sh: wrote artifacts/interaction-latency/results.json"
