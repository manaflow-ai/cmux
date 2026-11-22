#!/usr/bin/env bash
# scripts/ci/tests/console-session-hop.test.sh: console-session.sh hops into the console user's Aqua session with
# `sudo -n launchctl asuser` only when it is not in Aqua already and sudo grants launchctl. On 2026-11-18 a measure
# Mac's sudoers granted purge, fs_usage and /usr/bin/true but not launchctl; `sudo -n true` passed, so every
# launch-ready step tried the hop and failed with "sudo: a password is required".
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# Fakes: the console user is "person"; MANAGER is launchctl's session; SUDO_GRANTS lists what sudo -n allows.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/stat" <<'EOF'
#!/bin/sh
echo person
EOF
cat > "$WORK/bin/id" <<'EOF'
#!/bin/sh
echo 501
EOF
cat > "$WORK/bin/dscl" <<'EOF'
#!/bin/sh
echo "NFSHomeDirectory: /Users/person"
EOF
cat > "$WORK/bin/launchctl" <<'EOF'
#!/bin/sh
[ "$1" = managername ] && echo "$MANAGER"
EOF
cat > "$WORK/bin/sudo" <<'EOF'
#!/bin/sh
# sudo -n -l CMD: allowed when CMD is in SUDO_GRANTS; sudo -n launchctl asuser ...: the hop.
if [ "$2" = -l ]; then
  case " $SUDO_GRANTS " in *" $3 "*) exit 0 ;; esac
  exit 1
fi
case " $SUDO_GRANTS " in *" $2 "*) echo HOPPED; exit 0 ;; esac
echo "sudo: a password is required" >&2
exit 1
EOF
chmod +x "$WORK/bin/"*

run() { MANAGER="$1" SUDO_GRANTS="$2" PATH="$WORK/bin:$PATH" bash "$ROOT/scripts/ci/frame-pacing/console-session.sh" echo RAN 2>/dev/null; }

# sudo grants other commands but not launchctl: runs where it is.
out=$(run Background "purge fs_usage true") || fail "no launchctl grant exited non-zero"
[ "$out" = RAN ] || fail "no launchctl grant: '$out'"

# Already in Aqua, even with launchctl granted: runs where it is.
out=$(run Aqua "launchctl") || fail "in Aqua exited non-zero"
[ "$out" = RAN ] || fail "in Aqua: '$out'"

# Outside Aqua with launchctl granted: hops.
out=$(run Background "launchctl") || fail "hop exited non-zero"
[ "$out" = HOPPED ] || fail "hop: '$out'"

[ "$fails" -eq 0 ] || exit 1
echo "console-session-hop: ok"
