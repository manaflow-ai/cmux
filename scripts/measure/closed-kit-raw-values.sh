#!/usr/bin/env bash
# Raw values that type-check in the first closed directory (RFD 0040, the closed kit: webviews/src/kit/presets).
# Writes one probe file into that directory: 15 hand-set values, one per line, through every door a value can
# take there (`style` and `className` on each kit piece the directory renders, and three raw elements), type-checks
# it, prints how many compiled, and deletes the probe. Both modes check it in the tsconfig.closed.json program:
# `open` as the directory was before it closed (no pragma, React's own JSX: the kit pieces that take no `style`
# already refuse it, the rest compiles); `closed` as it is now (the closed runtime's pragma: none should). After
# `closed` it times `tsc -p tsconfig.closed.json`, cold and incremental.
#   cmux-ci test -- bash -c 'scripts/measure/closed-kit-raw-values.sh open; scripts/measure/closed-kit-raw-values.sh closed'
# From the repo root, after `bun install` in webviews/.
set -uo pipefail
mode="${1:-closed}"
webviews="$(git rev-parse --show-toplevel)/webviews"
probe="$webviews/src/kit/presets/zzRawValueProbe.tsx"
case "$mode" in
  open) pragma="" ;;
  closed) pragma='/** @jsxImportSource ../closed */' ;;
  *) echo "usage: closed-kit-raw-values.sh open|closed" >&2; exit 2 ;;
esac
config=tsconfig.closed.json
trap 'rm -f "$probe"' EXIT
{
  echo "${pragma:-// open: the React JSX runtime}"
  cat <<'PROBE'
import { List } from "../List";
import { Row } from "../Row";
import { Pill } from "../Pill";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { StatusGlyph } from "../../ui/StatusGlyph";
export const probes = [
  <List key="1" style={{ borderRadius: 7 }} />,
  <List key="2" className="x" />,
  <Row key="3" title="t" style={{ borderRadius: 7 }} />,
  <Row key="4" title="t" className="x" />,
  <Pill key="5" style={{ borderRadius: 7 }}>p</Pill>,
  <Pill key="6" className="x">p</Pill>,
  <Icon key="7" name="x" size={16} style={{ borderRadius: 7 }} />,
  <Icon key="8" name="x" size={16} className="x" />,
  <Spinner key="9" size={12} style={{ borderRadius: 7 }} />,
  <Spinner key="10" size={12} className="x" />,
  <StatusGlyph key="11" name="done" size={12} style={{ borderRadius: 7 }} />,
  <StatusGlyph key="12" name="done" size={12} className="x" />,
  <div key="13" style={{ borderRadius: 7 }} />,
  <span key="14" style={{ padding: 5 }} />,
  <button key="15" type="button" style={{ borderRadius: 7 }} />,
];
PROBE
} >"$probe"
cd "$webviews" || exit 1
# The probes are lines 9 to 23; an error on any other line is the harness's, not a probe's.
errors="$(node_modules/.bin/tsc -p "$config" --incremental false 2>&1 | grep 'zzRawValueProbe.tsx(')"
rejected="$(sed -n 's/.*zzRawValueProbe.tsx(\([0-9]*\),.*/\1/p' <<<"$errors" | sort -un | awk '$1 >= 9 && $1 <= 23' | wc -l)"
other="$(sed -n 's/.*zzRawValueProbe.tsx(\([0-9]*\),.*/\1/p' <<<"$errors" | sort -un | awk '$1 < 9 || $1 > 23' | wc -l)"
echo "RAW-VALUES $mode: $((15 - rejected)) of 15 compile ($config)"
[[ "$other" -gt 0 ]] && { echo "harness error outside the probes:"; echo "$errors"; exit 1; }
rm -f "$probe"
if [[ "$mode" == closed ]]; then
  rm -f node_modules/.cache/tsconfig.closed.tsbuildinfo
  for run in cold incremental incremental; do
    start=$(date +%s%N)
    node_modules/.bin/tsc -p tsconfig.closed.json >/dev/null || echo "tsc -p tsconfig.closed.json failed"
    echo "TSC-CLOSED $run: $(( ($(date +%s%N) - start) / 1000000 )) ms"
  done
  # A keystroke: touch one closed file and check again.
  touch src/kit/presets/SessionList.tsx
  start=$(date +%s%N)
  node_modules/.bin/tsc -p tsconfig.closed.json >/dev/null || echo "tsc -p tsconfig.closed.json failed"
  echo "TSC-CLOSED incremental after an edit: $(( ($(date +%s%N) - start) / 1000000 )) ms"
fi
