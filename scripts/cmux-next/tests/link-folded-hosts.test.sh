#!/usr/bin/env bash
# link-folded-hosts.sh: a cmux that runs the browser host and the app host by
# argv[0] gets bin/cmux-browser-host and bin/cmux-app-host as links to cmux,
# replacing placed copies; a cmux from before the fold keeps the copies.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/link-folded-hosts.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

# folded: answers as the host when argv[0]'s file name is cmux-browser-host.
mkdir -p "$TMP/folded" "$TMP/old"
cat > "$TMP/folded/cmux" <<'SH'
#!/bin/sh
case "$(basename "$0")" in
  cmux-browser-host) [ "$1" = version ] && echo "cmux-browser-host 1.0.0 (abc)" ;;
  *) echo "cmux 1.0.0 (abc)" ;;
esac
SH
# old: every name runs the cmux CLI.
printf '#!/bin/sh\necho "cmux 0.9.0 (old)"\n' > "$TMP/old/cmux"
chmod 755 "$TMP/folded/cmux" "$TMP/old/cmux"
for dir in folded old; do
  for name in cmux-browser-host cmux-app-host; do printf 'copy' > "$TMP/$dir/$name"; done
done

"$SCRIPT" --probe "$TMP/folded/cmux" || fail "--probe refused a folded cmux"
if "$SCRIPT" --probe "$TMP/old/cmux"; then fail "--probe accepted a cmux from before the fold"; fi

out=$("$SCRIPT" "$TMP/folded")
for name in cmux-browser-host cmux-app-host; do
  [[ -L "$TMP/folded/$name" && "$(readlink "$TMP/folded/$name")" == cmux ]] || fail "$name is not a link to cmux"
  grep -qx "folded $name" <<<"$out" || fail "no 'folded $name' in: $out"
done
[[ "$("$TMP/folded/cmux-browser-host" version)" == "cmux-browser-host 1.0.0 (abc)" ]] || fail "the link does not run the host"
# Again: the links stay.
"$SCRIPT" "$TMP/folded" >/dev/null
[[ "$(readlink "$TMP/folded/cmux-app-host")" == cmux ]] || fail "a second run changed the link"

# Only the named host is linked.
printf 'copy' > "$TMP/folded/cmux-app-host.tmp"; rm "$TMP/folded/cmux-app-host"; mv "$TMP/folded/cmux-app-host.tmp" "$TMP/folded/cmux-app-host"
"$SCRIPT" "$TMP/folded" cmux-browser-host >/dev/null
[[ -f "$TMP/folded/cmux-app-host" && ! -L "$TMP/folded/cmux-app-host" ]] || fail "an unnamed host was linked"
if "$SCRIPT" "$TMP/folded" cmux-tui-host 2>/dev/null; then fail "linked a host that is not folded"; fi

out=$("$SCRIPT" "$TMP/old")
for name in cmux-browser-host cmux-app-host; do
  [[ -f "$TMP/old/$name" && ! -L "$TMP/old/$name" ]] || fail "a cmux from before the fold lost its $name copy"
done
grep -q "keeping their own binaries" <<<"$out" || fail "no note for a cmux from before the fold: $out"
echo "link-folded-hosts: ok"
