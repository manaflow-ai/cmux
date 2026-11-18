#!/usr/bin/env bash
# link-mobile-host.sh (CMUX-570): a bundled bin/cmux-mobile-host copy becomes a
# link to cmux only when bin/cmux runs the host by argv[0] and its commit has
# the copy's host source key; otherwise, and with no copy, nothing changes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/link-mobile-host.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

head="$(git -C "$ROOT" rev-parse HEAD)"
key="$("$ROOT/scripts/cmux-next/build-mobile-host.sh" --source-key-at "$head")"
[[ "$key" =~ ^[0-9a-f]{16}$ ]] || fail "--source-key-at printed '$key'"
[[ "$("$ROOT/scripts/cmux-next/build-mobile-host.sh" --source-key-at HEAD)" == "$key" ]] || fail "the key is not the commit's"
if "$ROOT/scripts/cmux-next/build-mobile-host.sh" --source-key-at 0000000000000000000000000000000000000001 2>/dev/null; then
  fail "--source-key-at accepted a commit this clone does not have"
fi

# setup <dir> <names bin/cmux lists> <copy key or empty for no copy>
setup() {
  rm -rf "$1"; mkdir -p "$1"
  cat > "$1/cmux" <<SH
#!/bin/sh
if [ "\${CMUX_FOLDED_HOSTS_PROBE:-}" = 1 ]; then echo "folded-hosts: $2"; exit 0; fi
echo "cmux 1.0.0 (\$(basename "\$0"))"
SH
  chmod 755 "$1/cmux"
  if [[ -n "$3" ]]; then
    printf 'copy' > "$1/cmux-mobile-host"; chmod 755 "$1/cmux-mobile-host"
    printf 'key=%s\ncommit=%s\n' "$3" "$head" > "$1/cmux-mobile-host.version"
  fi
}
is_link() { [[ -L "$1/cmux-mobile-host" && "$(readlink "$1/cmux-mobile-host")" == cmux ]]; }
is_copy() { [[ ! -L "$1/cmux-mobile-host" && "$(cat "$1/cmux-mobile-host")" == copy ]]; }

# Same source: the link, and it runs bin/cmux under the host's name.
setup "$TMP/same" "cmux-browser-host cmux-mobile-host" "$key"
out=$("$SCRIPT" "$TMP/same" "$head")
is_link "$TMP/same" || fail "same source: not a link ($out)"
[[ "$("$TMP/same/cmux-mobile-host")" == "cmux 1.0.0 (cmux-mobile-host)" ]] || fail "the link does not run bin/cmux as the host"
"$SCRIPT" "$TMP/same" "$head" | grep -q "already a link" || fail "a second run did not keep the link"

# The commit from bin/cmux-tui.version when none is given.
setup "$TMP/version" "cmux-mobile-host" "$key"
printf 'mode=tree\ncommit=%s\n' "$head" > "$TMP/version/cmux-tui.version"
"$SCRIPT" "$TMP/version" >/dev/null
is_link "$TMP/version" || fail "commit from cmux-tui.version: not a link"

# Another host source (a copy from a dirty tree or another commit): the copy stays.
setup "$TMP/other" "cmux-mobile-host" "0123456789abcdef"
"$SCRIPT" "$TMP/other" "$head" | grep -q "^note: " || fail "other source: no note"
is_copy "$TMP/other" || fail "other source: the copy was replaced"

# A cmux that does not run the host (before this fold, or Linux without the feature).
setup "$TMP/unfolded" "cmux-browser-host cmux-app-host" "$key"
"$SCRIPT" "$TMP/unfolded" "$head" >/dev/null
is_copy "$TMP/unfolded" || fail "unfolded cmux: the copy was replaced"

# An unknown commit, a copy with no record, and the opt-out keep the copy.
setup "$TMP/unknown" "cmux-mobile-host" "$key"
"$SCRIPT" "$TMP/unknown" >/dev/null
is_copy "$TMP/unknown" || fail "unknown commit: the copy was replaced"
setup "$TMP/norecord" "cmux-mobile-host" "$key"; rm "$TMP/norecord/cmux-mobile-host.version"
"$SCRIPT" "$TMP/norecord" "$head" >/dev/null
is_copy "$TMP/norecord" || fail "no record: the copy was replaced"
setup "$TMP/keep" "cmux-mobile-host" "$key"
CMUX_NEXT_MOBILE_HOST_KEEP_COPY=1 "$SCRIPT" "$TMP/keep" "$head" >/dev/null
is_copy "$TMP/keep" || fail "KEEP_COPY: the copy was replaced"

# No copy (a build without the iPhone host): no link appears.
setup "$TMP/none" "cmux-mobile-host" ""
"$SCRIPT" "$TMP/none" "$head" >/dev/null
[[ ! -e "$TMP/none/cmux-mobile-host" && ! -L "$TMP/none/cmux-mobile-host" ]] || fail "no copy: a link appeared"

# No bin/cmux yet (nightly bundles the host before installing cmux).
setup "$TMP/nocmux" "cmux-mobile-host" "$key"; rm "$TMP/nocmux/cmux"
"$SCRIPT" "$TMP/nocmux" "$head" >/dev/null
is_copy "$TMP/nocmux" || fail "no bin/cmux: the copy was replaced"

echo "link-mobile-host: OK"
