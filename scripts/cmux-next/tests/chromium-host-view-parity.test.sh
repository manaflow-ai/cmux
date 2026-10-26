#!/usr/bin/env bash
# gen-chromium-host-wire.py --check-view-parity passes on the repository and
# fails on each broken fixture: an unmapped mojom method, a stale row, a row
# mapped only by cmux text, a not_needed row without a reason or with a
# mapping, an unknown export, a [Sync] method answered by an op alone, a
# direction rule broken either way, an op listed as an event, a bad wire or
# export catalog entry, an unknown row field, and a vendored mojom that
# drifted from its recorded sha256.
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
  local rel wired=0
  for rel in plans/cmux-next/chromium-host-view-parity.json \
    plans/cmux-next/remote_cocoa_mojom/render_widget_host_ns_view.mojom \
    Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h; do
    mkdir -p "$work/repo/$(dirname "$rel")"
    cp "$repo/$rel" "$work/repo/$rel"
  done
  # The checker's WIRE_HEADERS: CEFShim/src before task p01-process-001, ChromiumHost/src after.
  for rel in Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_wire.h \
    Packages/macOS/CmuxNext/CEFShim/src/chromium_host_wire.h; do
    [[ -f "$repo/$rel" ]] || continue
    mkdir -p "$work/repo/$(dirname "$rel")"
    cp "$repo/$rel" "$work/repo/$rel"
    wired=1
  done
  [[ $wired -eq 1 ]] || fail "no chromium_host_wire.h in the repository"
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
expect_red text-only "RenderWidgetHostNSView.DisplayCursor: no op or event (cmux text only describes)" \
  'p["methods"]["RenderWidgetHostNSView.DisplayCursor"] = {"cmux": "todo", "task": "p01-process-045"}; del p["wire"]["CURSOR"]'
expect_red host-to-cmux-ops-only "RenderWidgetHostNSView.SetTooltipText: host -> cmux method needs an event" \
  'p["methods"]["RenderWidgetHostNSView.SetTooltipText"] = {"ops": ["KEY"], "task": "p01-process-054"}'
expect_red cmux-to-host-events-only "RenderWidgetHostNSViewHost.RouteOrProcessMouseEvent: cmux -> host method needs an op" \
  'p["methods"]["RenderWidgetHostNSViewHost.RouteOrProcessMouseEvent"] = {"events": ["CURSOR"], "task": "p01-process-042"}'
expect_red not-needed-maps "RenderWidgetHostNSView.DisableDisplay: a not_needed row maps nothing" \
  'p["methods"]["RenderWidgetHostNSView.DisableDisplay"]["ops"] = ["KEY"]'
expect_red export-as-event "export cmux_shim_browser_set_embedder_active is cmux -> host, not an event" \
  'p["methods"]["RenderWidgetHostNSView.SetTooltipText"]["events"].append("cmux_shim_browser_set_embedder_active")'
expect_red unknown-field "RenderWidgetHostNSView.SetTooltipText: unknown field 'evnts'" \
  'p["methods"]["RenderWidgetHostNSView.SetTooltipText"]["evnts"] = ["TOOLTIP"]'
expect_red catalog-existing-kind "wire KEY: already a kind" \
  'p["wire"]["KEY"] = {"dir": "op", "task": "p01-process-042", "fields": "x"}'
expect_red catalog-shim-name "wire CMUX_SHIM_X: planned names are UPPER_SNAKE and not CMUX_SHIM_*" \
  'p["wire"]["CMUX_SHIM_X"] = {"dir": "event", "task": "p01-process-054", "fields": "x"}'
expect_red catalog-lower-name "wire Tooltip: planned names are UPPER_SNAKE" \
  'p["wire"]["Tooltip"] = p["wire"].pop("TOOLTIP"); p["methods"]["RenderWidgetHostNSView.SetTooltipText"]["events"] = ["Tooltip"]'
expect_red catalog-bad-dir "wire TOOLTIP: dir must be op or event" \
  'p["wire"]["TOOLTIP"]["dir"] = "both"'
expect_red catalog-no-task "wire TOOLTIP: needs the task id that adds it" \
  'del p["wire"]["TOOLTIP"]["task"]'
expect_red catalog-no-fields "wire TOOLTIP: needs its fields" \
  'del p["wire"]["TOOLTIP"]["fields"]'
expect_red export-already-exported "export cmux_shim_browser_set_embedder_active: already exported" \
  'p["exports"]["cmux_shim_browser_set_embedder_active"] = {"task": "p01-process-046", "args": "x"}'
expect_red export-bad-name "export cmux_shim_Bad: planned exports are cmux_shim_" \
  'p["exports"]["cmux_shim_Bad"] = {"task": "p01-process-220", "args": "x"}'
expect_red export-no-task "export cmux_shim_browser_set_page_visibility: needs the task id" \
  'del p["exports"]["cmux_shim_browser_set_page_visibility"]["task"]'
expect_red export-no-args "export cmux_shim_browser_set_page_visibility: needs its arguments" \
  'del p["exports"]["cmux_shim_browser_set_page_visibility"]["args"]'
expect_red export-unused "export cmux_shim_never_used: no method uses it" \
  'p["exports"]["cmux_shim_never_used"] = {"task": "p01-process-220", "args": "x"}'

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
