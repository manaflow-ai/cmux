#!/usr/bin/env bash
# Agent-chat transcript scroll measurement (320 rich turns, synthetic trackpad scroll and fling,
# idle and concurrent streaming) on the exclusive Chromium/WebKit fleet worker.
# Run:
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/agent-chat-scroll.sh --ref SHA \
#     --artifact artifacts/agent-chat-scroll/report.json --key agent-chat-scroll-SHA
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
bash scripts/ci/ensure-web-bundles.sh
bun_pin="$(python3 -c 'import json; print(json.load(open("webviews/package.json"))["devEngines"]["packageManager"]["version"])')"
bun_dir="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/tools/bun-$bun_pin/bin"
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ] && [ -x "$bun_dir/bun" ]; then export PATH="$bun_dir:$PATH"; fi
cd webviews
bun install --frozen-lockfile
playwright_version="$(python3 -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2>/dev/null || echo unknown)"
export PLAYWRIGHT_BROWSERS_PATH="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/playwright-$playwright_version"
./node_modules/.bin/playwright install --only-shell chromium webkit
out="$root/artifacts/agent-chat-scroll"
mkdir -p "$out"
log="$out/raw.log"
set +e
CMUX_BROWSER_TESTS=1 bun test --timeout 30000 test/scrolling-text-perf.test.ts 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
python3 - "$log" "$out/report.json" "$root" "$status" <<'PY'
import json, pathlib, re, sys, time
log, report, root, status = sys.argv[1:]
rows = []
for line in pathlib.Path(log).read_text(errors="replace").splitlines():
    marker = "scrolling-text-perf "
    if marker not in line:
        continue
    payload = line.split(": ", 1)
    if len(payload) != 2:
        continue
    label, raw = payload
    try:
        rows.append({"label": label.removeprefix(marker), "report": json.loads(raw)})
    except json.JSONDecodeError:
        pass
pathlib.Path(report).write_text(json.dumps({
    "host": __import__("socket").gethostname(),
    "sha": __import__("subprocess").check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "measured_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "pass" if int(status) == 0 else "fail",
    "reports": rows,
}, indent=2) + "\n")
PY
exit "$status"
