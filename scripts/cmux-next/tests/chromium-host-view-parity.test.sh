#!/usr/bin/env bash
# gen-chromium-host-wire.py --check-view-parity passes on the repository and
# fails on each broken fixture: an unmapped mojom method, a stale row, a
# not_needed row without a reason, an unknown export, a [Sync] method answered
# by an op alone, a host -> cmux reply with no answering op, an op listed as an
# event, and a vendored mojom that drifted from its recorded sha256.
# Portable: python3 only, no build.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
gen="$repo/scripts/cmux-next/gen-chromium-host-wire.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-view-parity.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "$gen" --check-view-parity >/dev/null || fail "repository parity check is red"
a="$(python3 "$gen" --check-view-parity --list-unmapped 2>/dev/null)"
b="$(python3 "$gen" --check-view-parity --list-unmapped 2>/dev/null)"
[[ "$a" == "$b" ]] || fail "two runs of --list-unmapped differ"
grep -q $'^planned\tp01-process-044\tRenderWidgetHostNSView.SetTextInputState\tTEXT_INPUT_STATE(p01-process-044)$' <<<"$a" \
  || fail "--list-unmapped lacks the planned TEXT_INPUT_STATE row"

# A fixture repository: the real inputs, copied, so each case edits only its copy.
fixture() {
  rm -rf "$work/repo"
  for rel in plans/cmux-next/chromium-host-view-parity.json \
    plans/cmux-next/remote_cocoa_mojom/render_widget_host_ns_view.mojom \
    Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h \
    Packages/macOS/CmuxNext/CEFShim/src/chromium_host_wire.h; do
    mkdir -p "$work/repo/$(dirname "$rel")"
    cp "$repo/$rel" "$work/repo/$rel"
  done
}

# expect_red NAME PATTERN PYTHON: PYTHON edits the fixture's parity JSON `p`
# (a dict), the check must exit 1 and print PATTERN.
expect_red() {
  local name="$1" pattern="$2" edit="$3" out status
  fixture
  python3 - "$work/repo/plans/cmux-next/chromium-host-view-parity.json" "$edit" <<'PY'
import json, sys
path, edit = sys.argv[1], sys.argv[2]
p = json.load(open(path))
exec(edit, {"p": p})
json.dump(p, open(path, "w"), indent=2)
PY
  set +e
  out="$(python3 "$gen" --repo "$work/repo" --check-view-parity 2>&1)"
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "$name: exit $status, want 1"$'\n'"$out"
  grep -qF -- "$pattern" <<<"$out" || fail "$name: no '$pattern' in"$'\n'"$out"
}

fixture
python3 "$gen" --repo "$work/repo" --check-view-parity >/dev/null || fail "unchanged fixture is red"

expect_red unmapped "RenderWidgetHostNSView.SetTooltipText: unmapped" \
  'del p["methods"]["RenderWidgetHostNSView.SetTooltipText"]'
expect_red stale-row "RenderWidgetHostNSView.Gone: row names no method" \
  'p["methods"]["RenderWidgetHostNSView.Gone"] = {"not_needed": "x"}'
expect_red empty-reason "RenderWidgetHostNSView.DisableDisplay: not_needed needs a written reason" \
  'p["methods"]["RenderWidgetHostNSView.DisableDisplay"] = {"not_needed": " "}'
expect_red unknown-export "cmux_shim_no_such_export is not exported" \
  'p["methods"]["RenderWidgetHostNSViewHost.OnWindowIsKeyChanged"]["ops"] = ["cmux_shim_no_such_export"]'
expect_red sync-by-op "RenderWidgetHostNSViewHost.SyncIsSpeaking: [Sync] in Chrome" \
  'p["methods"]["RenderWidgetHostNSViewHost.SyncIsSpeaking"] = {"ops": ["EDIT"], "task": "p01-process-047"}'
expect_red reply-without-op "RenderWidgetHostNSView.DisplayPopupMenu: has a reply in Chrome" \
  'del p["methods"]["RenderWidgetHostNSView.DisplayPopupMenu"]["ops"]'
expect_red wrong-direction "wire kind KEY is an op, listed as an event" \
  'p["methods"]["RenderWidgetHostNSView.SetTooltipText"]["events"] = ["KEY"]'
expect_red unused-catalog "wire NEVER_USED: no method uses it" \
  'p["wire"]["NEVER_USED"] = {"dir": "op", "task": "p01-process-055", "fields": "x"}'
expect_red no-task "RenderWidgetHostNSView.SetTooltipText: needs the task id" \
  'del p["methods"]["RenderWidgetHostNSView.SetTooltipText"]["task"]'

# Upstream drift: a method added to the vendored mojom changes its sha256 and
# is unmapped until a row maps it.
fixture
mojom="$work/repo/plans/cmux-next/remote_cocoa_mojom/render_widget_host_ns_view.mojom"
python3 - "$mojom" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().replace("  // Make the NSView be the first responder", "  NewUpstreamMethod();\n\n  // Make the NSView be the first responder", 1)
open(path, "w").write(text)
PY
set +e
out="$(python3 "$gen" --repo "$work/repo" --check-view-parity 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "drift: exit $status, want 1"
grep -qF "differs from the parity JSON" <<<"$out" || fail "drift: no sha256 error in"$'\n'"$out"
grep -qF "RenderWidgetHostNSView.NewUpstreamMethod: unmapped" <<<"$out" || fail "drift: new method not unmapped in"$'\n'"$out"

echo "chromium-host-view-parity: ok"
