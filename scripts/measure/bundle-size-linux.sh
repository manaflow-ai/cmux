#!/usr/bin/env bash
# The newest cmux NEXT nightly's app bundle size, for the perf cron (its Linux part bundle-size; budget row disk.app in
# scripts/cmux-next/perf-budget-table.tsv). Downloads the nightly DMG from its appcast and unpacks it
# (scripts/cmux-next/fetch-nightly-dmg.py: nothing in it runs), then measures it as the nightly's size step does
# (scripts/cmux-next/bundle-size.py summary, the arm64 caps of bundle-size-budget.json). Prints BUNDLE-SIZE and
# PERF_ROW lines, then the rows as one JSON object ({"rows": [...]}) on a line of its own: the report perf-cron.py's
# Linux part reads (its rows are webui.bundle_size.nightly.*). The rows are the published nightly's, not the measured
# commit's (a Mac build per commit is not on a Linux runner), so perf-cron.py stores and shows them, never judges or
# bisects them (REPORT_ONLY_ROW_RE).
#   cmux-ci test -- scripts/measure/bundle-size-linux.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
# 7-Zip 20 or newer reads APFS (fetch-nightly-dmg.py). Ubuntu's p7zip (16.02) does not: noble's 7zip package does.
seven_ok() {
  local bin
  bin="$(command -v 7zz || command -v 7z || true)"
  [[ -n "$bin" ]] && "$bin" 2>/dev/null | head -3 | grep -Eq '7-Zip (\(a\) |\[64\] )?(2[0-9]|[3-9][0-9])\.'
}
if ! seven_ok; then
  sudo apt-get update -qq && sudo apt-get install -y -qq 7zip >/dev/null
fi
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
fetched="$(python3 -I scripts/cmux-next/fetch-nightly-dmg.py "$out/nightly" | tail -n 1)"
app="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["app"])' "$fetched")"
dmg="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["dmg"])' "$fetched")"
python3 -I scripts/cmux-next/bundle-size.py summary "$app" --budget scripts/cmux-next/bundle-size-budget.json \
  --variant arm64 --dmg "$dmg" --json "$out/summary.json" >/dev/null
python3 -I - "$out/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
mb = lambda b: round(b / 1e6, 1)
# MB (10^6 bytes), as bundle-size-budget.json's app_max_bytes (700000000) reads 700 MB in the budget table.
rows = [{"name": "bundle_size.nightly.app_mb", "p50": mb(s["app_bytes"]), "p95": mb(s["app_bytes"]), "unit": "MB",
         "target": mb(s["app_max_bytes"]) if s.get("app_max_bytes") else None, "floor": 1.0},
        {"name": "bundle_size.nightly.dmg_mb", "p50": mb(s["dmg_bytes"]), "p95": mb(s["dmg_bytes"]), "unit": "MB",
         "target": mb(s["dmg_max_bytes"]) if s.get("dmg_max_bytes") else None, "floor": 1.0}]
print(f"BUNDLE-SIZE {s['dmg']}: app {s['app_bytes']} bytes (cap {s.get('app_max_bytes')}), DMG {s['dmg_bytes']} bytes "
      f"(cap {s.get('dmg_max_bytes')}), {len(s.get('problems') or [])} rules broken")
for r in rows:
    print("PERF_ROW " + json.dumps(r))
print(json.dumps({"rows": rows}))
PY
