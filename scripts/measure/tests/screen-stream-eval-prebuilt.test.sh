#!/usr/bin/env bash
# Portable build/connection regressions; platform commands use isolated fakes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="$root/screen-stream-eval.sh"
apple="$root/screen-stream-eval/targets/apple.sh"
fail=0

if ! bash -n "$harness" "$apple"; then
  echo "FAIL: screen-stream-eval scripts do not parse"
  fail=1
fi

tools_block=$(sed -n '/^if \[\[ "$tools_only" == 1 \]\]; then$/,/^  exit 0$/p' "$harness")
if [[ "$tools_block" != *'screen-eval-window-id'* || "$tools_block" != *'window-id.swift'* ]]; then
  echo "FAIL: tools-only does not compile screen-eval-window-id"
  fail=1
fi
if ! grep -q 'screen-eval-window-id' "$root/screen-stream-eval/README.md" ||
   ! grep -q 'apple-high.*apple-standard' "$root/screen-stream-eval/README.md"; then
  echo "FAIL: prebuilt README omits the Apple helper or targets"
  fail=1
fi

build_block=$(sed -n '/^  build)$/,/^    ;;$/p' "$apple")
prebuilt_branch=$(sed -n '/^    if \[\[ -n "${EVAL_PREBUILT:-}" \]\]; then$/,/^    else$/p' <<<"$build_block")
if [[ "$prebuilt_branch" != *'helper="$EVAL_PREBUILT/screen-eval-window-id"'* ||
      "$prebuilt_branch" != *'[[ -x "$helper" ]]'* ||
      "$prebuilt_branch" != *'cp "$helper" "$EVAL_BIN/screen-eval-window-id"'* ]]; then
  echo "FAIL: Apple prebuilt build does not validate and copy screen-eval-window-id"
  fail=1
fi
if [[ "$prebuilt_branch" == *swiftc* ]]; then
  echo "FAIL: Apple prebuilt branch invokes swiftc"
  fail=1
fi
if ! grep -q 'EVAL_PRESENTED_OBSERVER_BIN' "$apple" ||
   ! grep -q 'cmux.presented-marker/1' "$apple" ||
   ! grep -q 'no supported glass-to-glass timestamp API' "$apple" ||
   ! grep -q 'AXMenuItemMarkChar' "$apple"; then
  echo "FAIL: Apple latency path does not require a complete presented-marker observer"
  fail=1
fi
if ! grep -q 'presented-observer=' "$harness" ||
   ! grep -q 'EVAL_PRESENTED_OBSERVER_BIN=.*EVAL_BIN/cmux-rd' "$harness"; then
  echo "FAIL: presented observer geometry is not exposed through harness arguments"
  fail=1
fi

if ! grep -q 'app="$home/Applications/CmuxScreenEvalLauncher.app"' "$harness" ||
   ! grep -q 'app=$(bash "$here/launcher/install.sh"' "$harness"; then
  echo "FAIL: launcher path does not distinguish prebuilt and build routes"
  fail=1
fi
launcher_install=$(grep -n 'app=$(bash "$here/launcher/install.sh"' "$harness" | head -1 | cut -d: -f1)
launcher_else=$(sed -n "1,${launcher_install}p" "$harness" | grep -n '^[[:space:]]*else$' | tail -1 | cut -d: -f1)
if [[ -z "$launcher_else" || "$launcher_else" -ge "$launcher_install" ]]; then
  echo "FAIL: launcher install is not behind the non-prebuilt branch"
  fail=1
fi

python3 - "$apple" "$harness" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

apple = Path(sys.argv[1]).read_text()
harness = Path(sys.argv[2]).read_text()
prefix, dispatch = apple.split('case "$verb" in', 1)
with tempfile.TemporaryDirectory(prefix="screen-eval-regression-") as directory:
    root = Path(directory)
    prebuilt = root / "prebuilt"
    binary = root / "bin"
    prebuilt.mkdir()
    binary.mkdir()
    helper = prebuilt / "screen-eval-window-id"
    helper.write_text("#!/bin/sh\n"
                      "if [ -n \"${WINDOW_HELPER_CALLS:-}\" ]; then printf '%s|%s|%s\\n' \"$1\" \"${2-}\" \"${3-}\" >>\"$WINDOW_HELPER_CALLS\"; fi\n"
                      "if [ \"${WINDOW_CHANGED:-0}\" = 1 ] && [ -e \"$EVAL_STATE/menu-selected\" ]; then echo 43; else echo 42; fi\n")
    helper.chmod(0o755)
    env = {**os.environ, "EVAL_PREBUILT": str(prebuilt), "EVAL_BIN": str(binary),
           "EVAL_ROOT": str(root), "EVAL_STATE": str(root), "EVAL_PEER": "192.0.2.1",
           "EVAL_PRESENTED_OBSERVER_PID": "7", "EVAL_PRESENTED_OBSERVER_WINDOW": "42",
           "WINDOW_HELPER_CALLS": str(root / "helper-calls")}
    stubs = '''
screen_sharing_app() { echo /fixture/ScreenSharing.app; }
screencapture() { return 0; }
swiftc() { echo unexpected-compiler >&2; return 99; }
'''
    script = prefix + stubs + 'case "$verb" in' + dispatch
    def run(source, verb, **variables):
        return subprocess.run(["bash", "-c", source, "test", verb],
                              env={**env, **variables}, text=True, capture_output=True)
    result = run(script, "build")
    assert result.returncode == 0, result.stderr
    copied = binary / helper.name
    assert copied.read_bytes() == helper.read_bytes() and os.access(copied, os.X_OK)
    for executable in (False, None):
        if executable is False:
            helper.chmod(0o644)
        else:
            helper.unlink()
        result = run(script, "build")
        assert result.returncode != 0 and "missing or not executable" in result.stderr
        assert "unexpected-compiler" not in result.stderr

    # Run the actual connect function in the same || context as production.
    connection = prefix + stubs + '''
open() { return 0; }
osascript() {
  printf '%s|%s|%s\\n' "$1" "$2" "$3" >>"$EVAL_STATE/menu-calls"
  cat >/dev/null
  [[ "$PROFILE_STATUS" == 0 ]] && touch "$EVAL_STATE/menu-selected"
  return "$PROFILE_STATUS"
}
ps() { echo '7 Screen Sharing'; }
connect || exit 1
'''
    receipt = root / "apple-connection.json"
    result = run(connection, "host-stop", PROFILE_STATUS="1")
    assert result.returncode != 0 and not receipt.exists(), result.stderr
    result = run(connection, "host-stop", PROFILE_STATUS="0")
    assert result.returncode == 0 and receipt.is_file(), result.stderr
    assert all(line == "Screen Sharing|7|42" for line in (root / "helper-calls").read_text().splitlines())
    assert all(line == "-|Full Quality|7" for line in (root / "menu-calls").read_text().splitlines())
    receipt.unlink()
    (root / "menu-selected").unlink()
    result = run(connection, "host-stop", PROFILE_STATUS="0", WINDOW_CHANGED="1")
    assert result.returncode != 0 and not receipt.exists(), "changed window after menu selection must refuse"

    # Execute the real tools-only branch and inspect the actual tar archive.
    block = harness.split('if [[ "$tools_only" == 1 ]]; then', 1)[1].split('\nfi', 1)[0]
    work = root / "work"
    out = root / "out"
    work.mkdir()
    out.mkdir()
    (work / "bin").mkdir()
    build = '''set -euo pipefail
swiftc() {
  while [[ "$1" != -o ]]; do shift; done
  printf '#!/bin/sh\\nexit 0\\n' >"$2"
  chmod +x "$2"
}
bash() { printf '#!/bin/sh\\nexit 0\\n' >"$EVAL_BIN/cmux-rd"; chmod +x "$EVAL_BIN/cmux-rd"; }
git() { echo test-revision; }
''' + block
    result = run(build, "build", EVAL_BIN=str(work / "bin"), work=str(work), out=str(out),
                 root=str(root), here=str(root))
    assert result.returncode == 0, result.stderr
    with tarfile.open(out / "tools.tar.gz") as archive:
        for name in ("screen-eval-window-id", "screen-eval-scene", "cmux-rd"):
            entry = archive.getmember(f"tools/{name}")
            assert entry.isfile() and entry.mode & 0o111
print("prebuilt copy, fail-closed profile, and executable archive regressions: ok")
PY

if [[ "$fail" -eq 0 ]]; then
  echo "screen-stream-eval prebuilt checks: ok"
fi
exit "$fail"
