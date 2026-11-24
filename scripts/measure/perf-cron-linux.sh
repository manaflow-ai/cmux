#!/usr/bin/env bash
# One Linux part of the perf cron on a build-fleet Linux pool worker (Leo, 2026-11-19, on Blacksmith: "stop ...
# relying on it"). The build controller runs it for a `perf cron request <sha> <part>` job (cmuxterm-hq
# build-fleet/cmd/controller/perf_cron.go perfCronLinuxParts) on an idle worker of one machine type:
#   perf-cron-linux.sh PART
# It sets up what the runner job's steps set up (pinned bun, webviews packages, Playwright's WebKit and the system
# Chrome for the web UI parts), then runs `perf-cron.py run-linux-part` unchanged, so the rows (the runner
# calibration rows and the paired chat-open rows included) are the runner job's. The perf cron script is the branch
# tip's when the worker can fetch it, as the runner job does; the measured commit's benches run either way.
# Its one artifact, artifacts/perf-cron-linux/step.json, is {"report": ..., "result": ...}: perf-cron.py fetch-result
# reads both (linux_step_files). The rows carry the class fleet-linux-c4d-32 (LINUX_FLEET_CLASS).
# Exit 0 whenever run-linux-part wrote its result (a failed bench is in it). A setup failure (bun, the webviews
# packages, WebKit, Chrome, Rust) is the worker's, not the commit's: the artifact's result says yielded with the
# setup's last lines, and the script exits 0, so the cron asks again or runs the part on its runner job (record_part).
# 1 when run-linux-part wrote no result.
set -uo pipefail
part="${1:-}"
[ -n "$part" ] || { echo "usage: perf-cron-linux.sh PART" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root" || { echo "perf-cron-linux.sh: no checkout" >&2; exit 2; }
cache="${CMUX_CI_CACHE_DIR:-$HOME/.cache/cmux-ci}"
tools="$cache/tools"
out="$root/artifacts/perf-cron-linux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
setup_log="$work/setup.log"
: > "$setup_log"

# setup_yield STEP: the setup failed; the part yields (the cron's result names STEP and the setup's last lines).
setup_yield() {
  echo "perf-cron-linux.sh: setup failed: $1" >&2
  python3 -I - "$1" "$setup_log" "$out/step.json" <<'PY'
import json, sys
step, log, dest = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(log, errors="replace").read().splitlines()[-30:]
except OSError:
    lines = []
json.dump({"report": None, "result": {"state": "yielded", "tail": [*lines, f"perf-cron-linux.sh: setup failed: {step}"]}},
          open(dest, "w"))
PY
  exit 0
}

# The pinned bun, beside the cache as scripts/ci/ensure-web-bundles.sh keeps it.
bun_pin="$(python3 -I scripts/webviews_bun_version.py webviews/package.json 2>>"$setup_log")" || setup_yield "bun version"
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ]; then
  if [ ! -x "$tools/bun-$bun_pin/bin/bun" ]; then
    mkdir -p "$tools"
    curl -fsSL https://bun.sh/install | BUN_INSTALL="$tools/bun-$bun_pin" bash -s "bun-v$bun_pin" >>"$setup_log" 2>&1 \
      || setup_yield "bun $bun_pin"
  fi
  export PATH="$tools/bun-$bun_pin/bin:$PATH"
fi
(cd webviews && bash ../scripts/ci/bun-install.sh --frozen-lockfile) 2>&1 | tee -a "$setup_log" || setup_yield "bun install"

# A Node.js for the packages' node scripts (node_modules/.bin/playwright, used here and by ensure-system-chrome.sh, is
# `#!/usr/bin/env node`). The build-fleet Linux pool workers have bun but no node on the step PATH: from 2026-11-21
# every web-ui part's setup here failed with "/usr/bin/env: 'node': No such file or directory" and yielded, so each
# Linux part ran on the runner job only after two unanswered requests (record_part), three ticks a part, and tip
# measurement 9a55953f reached its 12 h bound with 3 of its parts still to do (abandoned 2026-11-22 07:14Z). The
# pool's own Node.js when it has one (/opt/node-v*, as its runner image keeps it), else bun, which runs a script as
# Node does when it is called as `node` (what `bun --bun` sets up).
if ! command -v node >/dev/null 2>&1; then
  mkdir -p "$work/node-bin"
  node_bin=""
  for candidate in /opt/node-v*/bin/node; do [ -x "$candidate" ] && node_bin="$candidate"; done
  [ -n "$node_bin" ] || node_bin="$(command -v bun)" || setup_yield "node (no Node.js and no bun on the step PATH)"
  ln -sfn "$node_bin" "$work/node-bin/node"
  export PATH="$work/node-bin:$PATH"
  echo "perf-cron-linux.sh: no node on the step PATH; node is $node_bin" | tee -a "$setup_log"
fi

case "$part" in
  web-ui*)
    # Playwright's WebKit in the cache, one directory per Playwright version; Chromium is the system Chrome
    # (scripts/ci/run-webviews-tests.sh does the same on these workers).
    playwright_version="$(cd webviews && python3 -I -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2>/dev/null || echo unknown)"
    export PLAYWRIGHT_BROWSERS_PATH="$cache/playwright-$playwright_version"
    (cd webviews && ./node_modules/.bin/playwright install webkit) 2>&1 | tee -a "$setup_log" || setup_yield "playwright webkit"
    # Required, as on the runner job (its "Install Playwright" step).
    chrome_out="$(cd webviews && "$root/scripts/ci/ensure-system-chrome.sh" 2>>"$setup_log")" || setup_yield "system Chrome"
    printf '%s\n' "$chrome_out"
    shell_line="$(printf '%s\n' "$chrome_out" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -1 || true)"
    [ -n "$shell_line" ] && export CMUX_CHROME_HEADLESS_SHELL="${shell_line#CMUX_CHROME_HEADLESS_SHELL=}"
    ;;
  diff-viewer)
    command -v cargo >/dev/null || ./scripts/install-rust-ci.sh >>"$setup_log" 2>&1 || setup_yield "rust"
    export PATH="$HOME/.cargo/bin:$PATH"
    ;;
esac

# The branch tip's perf cron script judges the measured commit's benches (the runner job's "Fetch the perf cron
# script of the branch tip"); a worker that cannot fetch it uses the commit's own. A full fetch: a shallow one would
# make the worker's warm clone shallow.
cron="$root/scripts/cmux-next/perf-cron.py"
if timeout 300 git fetch --no-tags origin feat-cmux-next 2>/dev/null \
    && git show FETCH_HEAD:scripts/cmux-next/perf-cron.py > "$work/perf-cron-tip.py" 2>/dev/null \
    && grep -q "\"name\": \"$part\"" "$work/perf-cron-tip.py"; then
  cp "$work/perf-cron-tip.py" scripts/cmux-next/perf-cron-tip.py && cron="$root/scripts/cmux-next/perf-cron-tip.py"
else
  # A part the measured commit adds (a PR's new bench, measured before it merges) is not in the tip's PARTS yet.
  echo "perf-cron-linux.sh: the branch tip's perf-cron.py was not fetched or has no part $part; using the commit's own"
fi

python3 -I "$cron" run-linux-part --part "$part" --runner-class fleet-linux-c4d-32 --out "$work/part"
[ -f "$work/part/result.json" ] || { echo "perf-cron-linux.sh: run-linux-part wrote no result" >&2; exit 1; }
python3 -I - "$work/part" "$out/step.json" <<'PY'
import json, os, sys
part, dest = sys.argv[1], sys.argv[2]
def read(name):
    try:
        with open(os.path.join(part, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
json.dump({"report": read("report.json"), "result": read("result.json")}, open(dest, "w"))
PY
echo "perf-cron-linux.sh: wrote artifacts/perf-cron-linux/step.json"
