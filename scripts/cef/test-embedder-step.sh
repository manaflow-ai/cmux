#!/usr/bin/env bash
# The cmux-ci cef-embedder step: runs the CEF fork's embedder tests
# (scripts/test-cmux-embedder.sh, 12 cases) against a CEF release package, on
# the single-purpose GUI worker (cmux-lawrence-2; hq build-fleet README "The
# CEF embedder step and the GUI worker"). The controller allowlists it as class
# exclusive with labels gui + cef-embedder and CMUX_TEST_REQUIRE_GUI=1.
#
#   scripts/cef/test-embedder-step.sh PACKAGE SOURCES FORK_REF [CASE...]
#
#   PACKAGE   sha256:<hex> of the CEF tarball, or a cef release tag that this
#             checkout's scripts/cmux-next/cef-manifest.json pins (this Mac's arch)
#   SOURCES   sha256:<hex> of the test-source archive (below)
#   FORK_REF  the 40-hex fork commit the archive was made from (its REF file)
#   CASE      default: all 12
#
# Both archives come from the controller store by sha256 and are checked
# before use; the host holds no credential. The fork is private, so the
# operator makes the test-source archive once per fork ref, on a machine with
# GitHub access, and puts it in the store for the step's workspace:
#
#   ref=<40-hex fork commit>; f=/tmp/cef-embedder-src-$ref.tar.gz
#   git -C <cef fork checkout> fetch origin "$ref" &&
#   git -C <cef fork checkout> archive --format=tar.gz --prefix=src/ \
#     --add-virtual-file="src/REF:$ref" -o "$f" "$ref" \
#     scripts/test-cmux-embedder.sh tests/cmux_embedder include/cef_cmux.h &&
#   cmux-ci artifact put "$f" --sha256 "$(shasum -a 256 "$f" | cut -c1-64)" --lane <workspace>
#
# then submits the step with the same --workspace:
#
#   cmux-ci run --class exclusive --script scripts/cef/test-embedder-step.sh \
#     --ref <cmux sha> --workspace <workspace> --key <key> -- \
#     sha256:<package> sha256:<archive> "$ref"
#
# The log is the step log (controller, 7 days): the full per-case output and a
# final "cmux-embedder: N/M passed". The step FAILS when any case fails, and
# when a process or a window of the tests outlives them (ended by pid).
#
# Limits (accepted 2026-10-05): a window of ANOTHER app that moved or resized
# during the run is reported as a warning, not a failure (the host's own session
# may move windows). The step cannot prove that no fullscreen or Space change
# happened; it relies on the fork tests (the test app is LSUIElement and the
# duplicate case's window is off-screen).
set -euo pipefail

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
[[ "${1:-}" == -h || "${1:-}" == --help ]] && usage 0
(( $# >= 3 )) || usage
PACKAGE="$1" SOURCES="$2" FORK_REF="$3"; shift 3
ALL=(signals slow-teardown duplicate zoom-bubble bookmark-bubble window-close move-parent transparent pref-control opaque-webauthn passkeys password-core)
cases=("$@")
die() { echo "cmux-embedder: error: $*" >&2; exit 2; }
for c in "${cases[@]}"; do [[ " ${ALL[*]} " == *" $c "* ]] || die "unknown case $c"; done
(( ${#cases[@]} )) || cases=("${ALL[@]}")
[[ "$SOURCES" =~ ^sha256:[0-9a-f]{64}$ ]] || die "SOURCES must be sha256:<64 hex>"
[[ "$FORK_REF" =~ ^[0-9a-f]{40}$ ]] || die "FORK_REF must be a 40-hex commit"
here="$(cd "$(dirname "$0")" && pwd)"
if [[ "$PACKAGE" =~ ^cef-[0-9]+\.[0-9]+\.[0-9]+-cmux\.[0-9]+$ ]]; then
  arch="$(uname -m)"
  PACKAGE="sha256:$(/usr/bin/env python3 - "$here/../cmux-next/cef-manifest.json" "$PACKAGE" "$arch" <<'PY'
import json, sys
m, tag, arch = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
if m.get("tag") != tag:
    sys.exit("cef-manifest.json pins %s, not %s; pass the package sha256" % (m.get("tag"), tag))
a = m if arch == "arm64" else m.get("x86_64") or {}
print(a["sha256"])
PY
)" || die "cannot resolve $1"
fi
[[ "$PACKAGE" =~ ^sha256:[0-9a-f]{64}$ ]] || die "PACKAGE must be sha256:<64 hex> or a pinned cef release tag"

WORK="${CMUX_EMBEDDER_WORK:-${CI_JOB_DIR:-${TMPDIR:-/tmp}}/cef-embedder}"
rm -rf "$WORK"; mkdir -p "$WORK/in" "$WORK/cef" "$WORK/run"
CONTROLLER="${CMUX_CI_CONTROLLER:-http://100.89.225.106:18765}"

fetch() { # fetch <sha256:hex> <dest>: from the controller store (or a local test dir), sha256 checked
  local hex="${1#sha256:}" url
  if [[ -n "${CMUX_EMBEDDER_INPUT_DIR:-}" ]]; then
    cp "$CMUX_EMBEDDER_INPUT_DIR/$hex" "$2" || die "no input $hex"
  else
    url="$(curl -fsS -A cmux-fleet-recipe "$CONTROLLER/v1/artifacts/sha256:$hex/url" |
      /usr/bin/env python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')" || die "the controller has no $1 for this job"
    [[ "$url" == http* ]] || die "the controller gave no URL for $1"
    curl -fsS -A cmux-fleet-recipe -o "$2" "$url" || die "download of $1 failed"
  fi
  [[ "$(shasum -a 256 "$2" | cut -c1-64)" == "$hex" ]] || die "$1: the bytes do not match"
  echo "==> $1 verified ($(wc -c <"$2" | tr -d ' ') bytes)"
}
fetch "$PACKAGE" "$WORK/in/package.tar.xz"
fetch "$SOURCES" "$WORK/in/sources.tar.gz"
tar -C "$WORK/cef" -xJf "$WORK/in/package.tar.xz"
tar -C "$WORK" -xzf "$WORK/in/sources.tar.gz"
[[ "$(tr -d '[:space:]' <"$WORK/src/REF" 2>/dev/null)" == "$FORK_REF" ]] ||
  die "the test-source archive's REF is $(tr -d '[:space:]' <"$WORK/src/REF" 2>/dev/null || echo missing), not $FORK_REF"
runner="$WORK/src/scripts/test-cmux-embedder.sh"
[[ -f "$runner" ]] || die "the archive has no scripts/test-cmux-embedder.sh"
cef_path="$(dirname "$(find "$WORK/cef" -maxdepth 3 -type d -name 'Chromium Embedded Framework.framework' | head -1)")"
[[ -d "$cef_path/include" ]] || die "the package has no CEF_PATH folder"
echo "==> package $PACKAGE, fork ref $FORK_REF, cases: ${cases[*]}"

# Windows on screen, for the survivor and display checks (macOS GUI session).
windows() { # prints "pid<TAB>owner<TAB>id<TAB>x,y,w,h" for layer-0 windows
  [[ "${CMUX_EMBEDDER_WINDOWS:-}" == skip ]] && return 0
  if [[ ! -x "$WORK/winlist" ]]; then
    cat >"$WORK/winlist.swift" <<'SWIFT'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in all where (w[kCGWindowLayer as String] as? Int) == 0 {
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print("\(w[kCGWindowOwnerPID as String] ?? 0)\t\(w[kCGWindowOwnerName as String] ?? "")\t\(w[kCGWindowNumber as String] ?? 0)\t\(b["X"] ?? 0),\(b["Y"] ?? 0),\(b["Width"] ?? 0),\(b["Height"] ?? 0)")
}
SWIFT
    xcrun swiftc -O -o "$WORK/winlist" "$WORK/winlist.swift" >/dev/null 2>&1 || die "cannot build the window lister"
  fi
  "$WORK/winlist"
}
windows >"$WORK/windows.before"

set +e
CMUX_EMBEDDER_TEST_DIR="$WORK/run" bash "$runner" "$cef_path" "${cases[@]}" 2>&1 | tee "$WORK/log"
rc=${PIPESTATUS[0]}
set -e
passed=$(grep -cE '^    PASS \(' "$WORK/log" || true)
failed=0; (( rc == 0 )) || failed=1

# Survivors: processes whose command runs from the work dir, and their windows.
sleep 1
survivors="$(pgrep -f "$WORK/" | grep -vx "$$" || true)"
windows >"$WORK/windows.after"
if [[ -n "$survivors" ]]; then
  echo "cmux-embedder: $(echo "$survivors" | wc -l | tr -d ' ') process(es) outlived the tests (step fails):"
  for pid in $survivors; do ps -o pid=,command= -p "$pid" 2>/dev/null | cut -c1-200 | sed 's/^/    /'; done
  awk -F'\t' -v s=" $(echo $survivors) " 'index(s, " " $1 " ") {print "    window " $3 " of " $2 " (pid " $1 ") still open"}' "$WORK/windows.after"
  kill $survivors 2>/dev/null || true
  sleep 3
  left="$(for p in $survivors; do kill -0 "$p" 2>/dev/null && echo "$p"; done)"
  [[ -z "$left" ]] || { kill -9 $left 2>/dev/null || true; echo "    SIGKILL: $(echo $left)"; }
  failed=1
fi
# Test-app windows (owner CmuxEmbedderTest) left on screen fail the step too.
if grep -q $'\tCmuxEmbedderTest' "$WORK/windows.after" 2>/dev/null; then
  echo "cmux-embedder: a CmuxEmbedderTest window is still open (step fails)"; failed=1
fi
# Other apps' windows must not have moved or resized (reported, not failed:
# the host's own session may move them).
if [[ -s "$WORK/windows.before" ]]; then
  awk -F'\t' 'NR==FNR {b[$3]=$4; o[$3]=$2; next} ($3 in b) && b[$3] != $4 && $2 != "CmuxEmbedderTest" {print "cmux-embedder: warning: window " $3 " of " $2 " moved or resized: " b[$3] " -> " $4}' \
    "$WORK/windows.before" "$WORK/windows.after"
fi
echo "cmux-embedder: $passed/${#cases[@]} passed"
(( failed == 0 && passed == ${#cases[@]} ))
