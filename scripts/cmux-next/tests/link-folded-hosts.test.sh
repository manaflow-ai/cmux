#!/usr/bin/env bash
# link-folded-hosts.sh: a cmux that runs the browser host and the app host by
# argv[0] gets bin/cmux-browser-host and bin/cmux-app-host (and every name its
# --list prints) as links to cmux,
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

# A cmux that prints its list (CMUX_FOLDED_HOSTS_PROBE=1, cmux_tui::main FOLDED_HOSTS)
# folds every name on it; the default links them all.
mkdir -p "$TMP/listed"
cat > "$TMP/listed/cmux" <<'SH'
#!/bin/sh
if [ "$CMUX_FOLDED_HOSTS_PROBE" = 1 ]; then
  case "$(basename "$0")" in
    cmux-browser-host|cmux-app-host|cmux-agent-screen-detection|cmux-cloud)
      echo "folded-hosts: cmux-browser-host cmux-app-host cmux-agent-screen-detection cmux-cloud"; exit 0 ;;
  esac
fi
echo "cmux 1.1.0 (def)"
SH
chmod 755 "$TMP/listed/cmux"
listed=(cmux-browser-host cmux-app-host cmux-agent-screen-detection cmux-cloud)
for name in "${listed[@]}"; do printf 'copy' > "$TMP/listed/$name"; done
[[ "$("$SCRIPT" --list "$TMP/listed/cmux" | tr '\n' ' ')" == "${listed[*]} " ]] || fail "--list: $("$SCRIPT" --list "$TMP/listed/cmux")"
[[ "$("$SCRIPT" --list "$TMP/folded/cmux" | tr '\n' ' ')" == "cmux-browser-host cmux-app-host " ]] || fail "--list of the first fold"
[[ -z "$("$SCRIPT" --list "$TMP/old/cmux")" ]] || fail "--list named a host for a cmux from before the fold"
"$SCRIPT" --probe "$TMP/listed/cmux" || fail "--probe refused a cmux with a list"
out=$("$SCRIPT" "$TMP/listed")
for name in "${listed[@]}"; do
  [[ "$(readlink "$TMP/listed/$name")" == cmux ]] || fail "$name is not a link to cmux"
  grep -qx "folded $name" <<<"$out" || fail "no 'folded $name' in: $out"
done
# The first fold carries only the two hosts: the detector stays a copy there.
printf 'copy' > "$TMP/folded/cmux-agent-screen-detection"
if "$SCRIPT" "$TMP/folded" cmux-agent-screen-detection 2>/dev/null; then fail "linked a program the first fold does not run"; fi
[[ -f "$TMP/folded/cmux-agent-screen-detection" && ! -L "$TMP/folded/cmux-agent-screen-detection" ]] || fail "the refused name was replaced"
echo "link-folded-hosts: ok"
