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

# console-session.sh asks bench_launch.py (beside it, through /usr/bin/python3) for the console user since #54474:
# run a copy of it next to a fake bench_launch.py that answers "person", as the stat fake did before.
mkdir -p "$WORK/repo/scripts/ci/frame-pacing" "$WORK/repo/scripts/cmux-next"
cp "$ROOT/scripts/ci/frame-pacing/console-session.sh" "$WORK/repo/scripts/ci/frame-pacing/"
printf 'print("person")\n' > "$WORK/repo/scripts/cmux-next/bench_launch.py"
SCRIPT="$WORK/repo/scripts/ci/frame-pacing/console-session.sh"

run() { MANAGER="$1" SUDO_GRANTS="$2" PATH="$WORK/bin:$PATH" bash "$SCRIPT" echo RAN 2>/dev/null; }

# sudo grants other commands but not launchctl: runs where it is.
out=$(run Background "purge fs_usage true") || fail "no launchctl grant exited non-zero"
[ "$out" = RAN ] || fail "no launchctl grant: '$out'"

# Already in Aqua, even with launchctl granted: runs where it is.
out=$(run Aqua "launchctl") || fail "in Aqua exited non-zero"
[ "$out" = RAN ] || fail "in Aqua: '$out'"

# Outside Aqua with launchctl granted: hops.
out=$(run Background "launchctl") || fail "hop exited non-zero"
[ "$out" = HOPPED ] || fail "hop: '$out'"

# Own-session fakes: launchctl print gui/N succeeds when GUI=1; bootstrap runs the plist's run.sh in the background.
cat > "$WORK/bin/launchctl" <<'EOS'
#!/bin/sh
case "$1" in
  managername) echo "$MANAGER" ;;
  print) [ "${GUI:-0}" = 1 ] ;;
  bootstrap) [ "${BOOTSTRAP_FAIL:-0}" = 1 ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    script=$(sed -n 's|.*<string>\(/[^<]*run\.sh\)</string>.*|\1|p' "$3" | head -1)
    /bin/bash "$script" & ;;
  bootout) exit 0 ;;
esac
EOS
# The hop's second sudo (to the console user) is refused when SECOND=refuse.
cat > "$WORK/bin/sudo" <<'EOS'
#!/bin/sh
if [ "$2" = -l ]; then
  case " $SUDO_GRANTS " in *" $3 "*) exit 0 ;; esac
  exit 1
fi
if [ "${SECOND:-}" = refuse ] && [ "$2" = launchctl ]; then echo "sudo: a password is required" >&2; exit 1; fi
case " $SUDO_GRANTS " in *" $2 "*) echo HOPPED; exit 0 ;; esac
echo "sudo: a password is required" >&2
exit 1
EOS
chmod +x "$WORK/bin/"*
runx() { PATH="$WORK/bin:$PATH" TMPDIR="$WORK" bash "$SCRIPT" "$@"; }

# CONSOLE_SESSION=own: runs in this user's gui domain with no sudo and keeps the exit code.
rc=0; out=$(MANAGER=Background GUI=1 SUDO_GRANTS="" CONSOLE_SESSION=own runx sh -c 'echo OWN; exit 7' 2>/dev/null) || rc=$?
[ "$out" = OWN ] || fail "own: '$out'"
[ "$rc" = 7 ] || fail "own rc: $rc"

# CONSOLE_SESSION=own with no GUI login: says why.
err=$(MANAGER=Background GUI=0 CONSOLE_SESSION=own runx echo RAN 2>&1 >/dev/null) && fail "own without GUI exited 0"
case "$err" in *"CONSOLE-SESSION-FAIL reason=no GUI login"*) ;; *) fail "own without GUI: '$err'" ;; esac

# A bootstrap that fails says why.
err=$(MANAGER=Background GUI=1 BOOTSTRAP_FAIL=1 CONSOLE_SESSION=own runx echo RAN 2>&1 >/dev/null) && fail "bootstrap fail exited 0"
case "$err" in *"CONSOLE-SESSION-FAIL reason=launchctl bootstrap"*"Input/output error"*) ;; *) fail "bootstrap fail: '$err'" ;; esac

# auto, launchctl granted but the second hop refused (air-blue 2026-11-21): names the sudo refusal, falls back to own.
both=$(MANAGER=Background GUI=1 SUDO_GRANTS="launchctl" SECOND=refuse runx echo RAN 2>&1) || fail "refused hop exited non-zero"
case "$both" in *"CONSOLE-SESSION-FAIL reason=hop into console user 'person' refused: sudo: a password is required"*) ;; *) fail "refused hop reason: '$both'" ;; esac
case "$both" in *RAN*) ;; *) fail "refused hop did not run own: '$both'" ;; esac

# An unknown mode is refused with a reason.
err=$(CONSOLE_SESSION=bogus runx echo RAN 2>&1 >/dev/null) && fail "bogus mode exited 0"
case "$err" in *"unknown CONSOLE_SESSION"*) ;; *) fail "bogus mode: '$err'" ;; esac

[ "$fails" -eq 0 ] || exit 1
echo "console-session-hop: ok"
