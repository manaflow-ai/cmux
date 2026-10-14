#!/usr/bin/env bash
# A tagged build launched from an acpmux agent (an agent pane of cmux NEXT) inherits its
# daemon's ACPMUX_HOME and ACPMUX_SOCKET. The build then resolves NEXT's daemon as its own
# and hands it off as an outdated build, stopping it (2026-10-14). The tagged launchers drop
# the agent's acpmux variables; an explicit --env pair still reaches the app.
#
# launch-tagged-automation.sh runs against a temporary HOME holding an empty app bundle
# path, with a stub `open` that records the environment it gets. reload.sh's launch builds
# the app first, so its clean-environment list is read from source.
set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

tag="acpmux-env-test-$$"
mkdir -p "$tmp/home/Library/Developer/Xcode/DerivedData/cmux-${tag}/Build/Products/Debug/cmux DEV ${tag}.app" "$tmp/bin"
cat > "$tmp/bin/open" <<EOF
#!/usr/bin/env bash
env > "$tmp/open.env"
EOF
chmod +x "$tmp/bin/open"

launch() {
  env HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
    ACPMUX_HOME=/Users/me/.acpmux/tags/cmux-next \
    ACPMUX_SOCKET=/Users/me/.acpmux/tags/cmux-next/acpmux.sock \
    ACPMUX_ENV=1 ACPMUX_SESSION_ID=agent-session ACPMUX_SESSION_NAME=agent \
    "$scripts/launch-tagged-automation.sh" "$tag" --wait-socket 0 "$@" > /dev/null
}

launch
for name in ACPMUX_HOME ACPMUX_SOCKET ACPMUX_ENV ACPMUX_SESSION_ID ACPMUX_SESSION_NAME; do
  if grep -q "^${name}=" "$tmp/open.env"; then
    fail "launch-tagged-automation.sh passed the agent's $name to the app: $(grep "^${name}=" "$tmp/open.env")"
  fi
done

launch --env ACPMUX_HOME=/tmp/isolated --env ACPMUX_SOCKET=/tmp/isolated/acpmux.sock
grep -qx "ACPMUX_HOME=/tmp/isolated" "$tmp/open.env" || fail "an explicit --env ACPMUX_HOME did not reach the app"
grep -qx "ACPMUX_SOCKET=/tmp/isolated/acpmux.sock" "$tmp/open.env" || fail "an explicit --env ACPMUX_SOCKET did not reach the app"

clean="$(awk '/^  OPEN_CLEAN_ENV=\(/ { inside = 1 } inside { print } inside && /^  \)/ { exit }' "$scripts/reload.sh")"
[[ -n "$clean" ]] || fail "reload.sh has no OPEN_CLEAN_ENV list"
for name in ACPMUX_HOME ACPMUX_SOCKET ACPMUX_ENV ACPMUX_SESSION_ID ACPMUX_SESSION_NAME; do
  grep -q -- "-u ${name}\$" <<< "$clean" || fail "reload.sh's OPEN_CLEAN_ENV keeps the agent's $name"
done
echo "tagged-launch-acpmux-env: ok"
