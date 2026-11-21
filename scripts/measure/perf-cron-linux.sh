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
# Exit 0 whenever run-linux-part wrote its result (a failed bench is in it); 1 when it did not.
set -uo pipefail
part="${1:-}"
[ -n "$part" ] || { echo "usage: perf-cron-linux.sh PART" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 1
cache="${CMUX_CI_CACHE_DIR:-$HOME/.cache/cmux-ci}"
tools="$cache/tools"
out="$root/artifacts/perf-cron-linux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# The pinned bun, beside the cache as scripts/ci/ensure-web-bundles.sh keeps it.
bun_pin="$(python3 -I scripts/webviews_bun_version.py webviews/package.json)" || exit 1
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ]; then
  if [ ! -x "$tools/bun-$bun_pin/bin/bun" ]; then
    mkdir -p "$tools"
    curl -fsSL https://bun.sh/install | BUN_INSTALL="$tools/bun-$bun_pin" bash -s "bun-v$bun_pin" > /dev/null || exit 1
  fi
  export PATH="$tools/bun-$bun_pin/bin:$PATH"
fi
(cd webviews && bash ../scripts/ci/bun-install.sh --frozen-lockfile) || exit 1

case "$part" in
  web-ui*)
    # Playwright's WebKit in the cache, one directory per Playwright version; Chromium is the system Chrome
    # (scripts/ci/run-webviews-tests.sh does the same on these workers).
    playwright_version="$(cd webviews && python3 -I -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2>/dev/null || echo unknown)"
    export PLAYWRIGHT_BROWSERS_PATH="$cache/playwright-$playwright_version"
    (cd webviews && ./node_modules/.bin/playwright install webkit) || exit 1
    chrome_out="$(cd webviews && "$root/scripts/ci/ensure-system-chrome.sh" --optional)"
    printf '%s\n' "$chrome_out"
    shell_line="$(printf '%s\n' "$chrome_out" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -1 || true)"
    [ -n "$shell_line" ] && export CMUX_CHROME_HEADLESS_SHELL="${shell_line#CMUX_CHROME_HEADLESS_SHELL=}"
    ;;
  diff-viewer)
    command -v cargo >/dev/null || ./scripts/install-rust-ci.sh || exit 1
    export PATH="$HOME/.cargo/bin:$PATH"
    ;;
esac

# The branch tip's perf cron script judges the measured commit's benches (the runner job's "Fetch the perf cron
# script of the branch tip"); a worker that cannot fetch it uses the commit's own.
cron="$root/scripts/cmux-next/perf-cron.py"
if timeout 120 git fetch --no-tags --depth=1 origin feat-cmux-next 2>/dev/null \
    && git show FETCH_HEAD:scripts/cmux-next/perf-cron.py > "$work/perf-cron-tip.py" 2>/dev/null; then
  cp "$work/perf-cron-tip.py" scripts/cmux-next/perf-cron-tip.py && cron="$root/scripts/cmux-next/perf-cron-tip.py"
else
  echo "perf-cron-linux.sh: the branch tip's perf-cron.py was not fetched; using the commit's own"
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
