#!/usr/bin/env bash
# Writes <bin>/daemon-capabilities.json (the app's Contents/Resources/bin): the
# protocol capabilities of the daemons the app bundles, as the bundled binary
# itself prints them, so the file is never kept by hand:
#
#   {"cmuxTui": [...], "acpmux": [...]}
#
#   cmuxTui  `<bin>/cmux-tui __daemon-capabilities --json`: what every cmux-tui daemon of
#            this build always advertises in `identify` (cmux-tui-core
#            server/capabilities.rs, static_capabilities)
#   acpmux   `<bin>/acpmux capabilities --json`: what acpmux serves, also in its
#            initialize `_meta.acpmux.capabilities` and `_acpmux/status`
#            (acpmux src/capabilities.rs)
#
# The web pages update apart from the app (plans/cmux-next/web-ota.md); the app
# reads this file to tell whether an update's daemon requirements are met.
#
# Every path that places bin/cmux runs it: bundle-cmux-tui.sh (the Xcode "Bundle
# cmux-tui" phase of dev reloads, tagged, fleet and Release compiles),
# scripts/install-cmux-tui-client.sh (nightly and release replace that client
# with a universal one) and write-cmux-tui-version.sh (release, nightly and
# build-sign-upload.sh).
#
# A binary that cannot print its list (a cmux-tui from before the command, a
# non-executable cached slice, a test fake) leaves no file and a warning, so the
# bundle claims no capability. --require makes that an error; bundle-cmux-tui.sh
# passes it for a same-tree build, which must print it.
#
# Usage: write-daemon-capabilities.sh [--require] <bin dir>
set -euo pipefail

require=0
if [[ "${1:-}" == --require ]]; then
  require=1
  shift
fi
bin_dir="${1:?usage: write-daemon-capabilities.sh [--require] <bin dir>}"
out="$bin_dir/daemon-capabilities.json"
work="$(mktemp -d "${TMPDIR:-/tmp}/daemon-capabilities.XXXXXX")"
trap 'rm -rf "$work"' EXIT

give_up() {
  if (( require )); then
    echo "error: daemon-capabilities.json: $1" >&2
    exit 1
  fi
  echo "warning: daemon-capabilities.json: $1; the bundle records no daemon capabilities"
  rm -f "$out"
  exit 0
}

# cmux-tui's mode is private: `cmux capabilities` is the app's classic verb.
for name in cmux-tui acpmux; do
  mode=capabilities
  [[ "$name" == cmux-tui ]] && mode=__daemon-capabilities
  [[ -x "$bin_dir/$name" ]] || give_up "$bin_dir/$name is not an executable"
  # stdin closed: an older binary that does not know the command must not wait on it.
  "$bin_dir/$name" "$mode" --json </dev/null >"$work/$name.json" 2>"$work/$name.err" \
    || give_up "\`$name $mode --json\` failed: $(head -c 300 "$work/$name.err")"
done

if ! python3 -I - "$work/cmux-tui.json" "$work/acpmux.json" "$work/out.json" 2>"$work/py.err" <<'PY'
import json
import sys


def listed(path, name):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except ValueError as error:
        sys.exit(f"`{name}` printed no capabilities JSON ({error})")
    capabilities = value.get("capabilities") if isinstance(value, dict) else None
    if (not isinstance(capabilities, list) or not capabilities
            or not all(isinstance(item, str) and item for item in capabilities)):
        sys.exit(f"`{name}` printed no capability list")
    return capabilities


document = {"cmuxTui": listed(sys.argv[1], "cmux-tui"), "acpmux": listed(sys.argv[2], "acpmux")}
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
then
  give_up "$(tail -n 1 "$work/py.err")"
fi

if ! cmp -s "$work/out.json" "$out"; then
  cp "$work/out.json" "$out"
  chmod 644 "$out"
fi
counts="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["cmuxTui"]), len(d["acpmux"]))' "$out")"
echo "daemon-capabilities.json: cmux-tui ${counts% *}, acpmux ${counts#* } capabilities"
