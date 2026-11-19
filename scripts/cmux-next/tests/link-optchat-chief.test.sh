#!/usr/bin/env bash
# link-optchat-chief.sh: a cmux that runs the Home Chief by argv[0] gets
# bin/optchat-chief as a link to cmux, replacing the placed copy; a cmux from
# before the fold keeps the copy; no copy, no link.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/link-optchat-chief.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

# folded: prints the Chief's usage when argv[0]'s file name is optchat-chief.
mkdir -p "$TMP/folded" "$TMP/old" "$TMP/none" "$TMP/keep"
cat > "$TMP/folded/cmux" <<'SH'
#!/bin/sh
case "$(basename "$0")" in
  optchat-chief) [ "$1" = help ] && echo "optchat-chief host --daemon-socket PATH [--mux-home DIR]   run the Chief host" ;;
  *) echo "cmux 1.0.0 (abc)" ;;
esac
SH
# old: every name runs the cmux CLI.
printf '#!/bin/sh\necho "cmux 0.9.0 (old)"\n' > "$TMP/old/cmux"
chmod 755 "$TMP/folded/cmux" "$TMP/old/cmux"
cp "$TMP/folded/cmux" "$TMP/none/cmux"
cp "$TMP/folded/cmux" "$TMP/keep/cmux"
for dir in folded old keep; do printf 'copy' > "$TMP/$dir/optchat-chief"; done

"$SCRIPT" --probe "$TMP/folded/cmux" || fail "--probe refused a folded cmux"
if "$SCRIPT" --probe "$TMP/old/cmux"; then fail "--probe accepted a cmux from before the fold"; fi

out=$("$SCRIPT" "$TMP/folded")
[[ -L "$TMP/folded/optchat-chief" && "$(readlink "$TMP/folded/optchat-chief")" == cmux ]] || fail "optchat-chief is not a link to cmux"
grep -qx "folded optchat-chief" <<<"$out" || fail "no 'folded optchat-chief' in: $out"
"$TMP/folded/optchat-chief" help | grep -q '^optchat-chief host ' || fail "the link does not run the Chief"
# Again: the link stays.
"$SCRIPT" "$TMP/folded" >/dev/null
[[ "$(readlink "$TMP/folded/optchat-chief")" == cmux ]] || fail "a second run changed the link"

out=$("$SCRIPT" "$TMP/old")
[[ -f "$TMP/old/optchat-chief" && ! -L "$TMP/old/optchat-chief" ]] || fail "a cmux from before the fold lost its copy"
grep -q "keeping bin/optchat-chief" <<<"$out" || fail "no note for a cmux from before the fold: $out"

# A link left from a cmux that carried the Chief, now beside one that does not: removed, never left to run the CLI.
ln -s cmux "$TMP/old/optchat-chief.link" && mv "$TMP/old/optchat-chief.link" "$TMP/old/optchat-chief"
"$SCRIPT" "$TMP/old" 2>/dev/null
[[ ! -e "$TMP/old/optchat-chief" && ! -L "$TMP/old/optchat-chief" ]] || fail "a link to a cmux without the Chief stayed"

"$SCRIPT" "$TMP/none" >/dev/null
[[ ! -e "$TMP/none/optchat-chief" ]] || fail "a build without a Chief got a link"

CMUX_NEXT_OPTCHAT_CHIEF_KEEP_COPY=1 "$SCRIPT" "$TMP/keep" >/dev/null
[[ -f "$TMP/keep/optchat-chief" && ! -L "$TMP/keep/optchat-chief" ]] || fail "KEEP_COPY=1 did not keep the copy"

if "$SCRIPT" "$TMP/missing" 2>/dev/null; then fail "a folder without bin/cmux passed"; fi
echo "link-optchat-chief: ok"
