#!/usr/bin/env bash
# Self-test of vm.sh's --probe checks (the exec suite runs probes/NAME.swift as the guest's admin).
# Run it on a fleet host: bash scripts/fuzz/macos-matrix/test_probe_names.sh. It boots no VM: every case
# must be refused at argument parsing (exit 2), and the good case must get past it.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# A copy of the runner, so the test can plant links and files in its probes/ folder.
mkdir -p "$T/kit/probes" "$T/outside"
cp "$HERE/vm.sh" "$HERE/images.json" "$T/kit/"
echo 'print("ok")' >"$T/kit/probes/good.swift"
echo 'print("evil")' >"$T/outside/evil.swift"
ln -s "$T/outside/evil.swift" "$T/kit/probes/link.swift"
: >"$T/build.zip"
fail=0
run() {  # run WANT_REFUSED NAME...: vm.sh with a missing tart binary stops right after argument checks
  local want=$1; shift
  local out; out=$(TART_BIN=/nonexistent FUZZ_WORK="$T/work" bash "$T/kit/vm.sh" --suite exec "$@" "$T/build.zip" 2>&1); local rc=$?
  if [[ $want == refused ]]; then
    [[ $rc == 2 && $out == *"--suite exec needs --probe NAME"* ]] || { echo "FAIL: $* not refused (exit $rc: $out)"; fail=1; return; }
  else
    [[ $out != *"--suite exec needs --probe NAME"* ]] || { echo "FAIL: $* refused (exit $rc: $out)"; fail=1; return; }
  fi
  echo "ok   $want: $*"
}
run refused                                   # no --probe
run refused --probe ../outside/evil           # a path separator and ..
run refused --probe ..                        # .. alone
run refused --probe probes/good               # a separator
run refused --probe Good                      # not lowercase
run refused --probe good.swift                # a dot
run refused --probe link                      # a link out of probes/
run refused --probe missing                   # no such file
run refused --probe good --repro close-window # a repro with exec
rm -rf "$T/kit/probes.real"; mv "$T/kit/probes" "$T/kit/probes.real"; ln -s "$T/kit/probes.real" "$T/kit/probes"
run refused --probe good                      # probes/ itself a link
rm "$T/kit/probes"; mv "$T/kit/probes.real" "$T/kit/probes"
run accepted --probe good                     # a regular file in probes/
exit $fail
