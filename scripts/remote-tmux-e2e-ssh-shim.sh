#!/bin/bash
# Hermetic ssh replacement for RemoteTmuxSizingUITests: strip ssh's option
# framing and the destination, then run the "remote" command locally, so the
# app's tmux -CC control-mode attach runs against the local lab server
# (TMUX_TMPDIR is inherited from the app's environment). No sshd, no network.
want_pty=0
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -t|-tt) want_pty=1; shift ;;
    # ControlMaster ops (-O check/exit/…): there is no real master here —
    # every "remote" command just runs locally — so report success the way a
    # live master would and let the readiness gate pass.
    -O) exit 0 ;;
    -o|-p|-i|-l|-F) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift  # the ssh destination
# Two things real ssh does that we must replicate:
#  1. It hands the remaining arguments to the remote LOGIN SHELL, which
#     re-splits them — cmux passes the remote command as one shell-quoted
#     string, so it goes through `sh -c`.
#  2. With -t/-tt (and ONLY then) it allocates a remote PTY. `tmux -CC`
#     requires a controlling tty (bare pipe → "tcgetattr failed"), so the
#     control-stream attach runs under script(1), which provides a pty and
#     bridges it to our stdio. One-shot probes must NOT get a pty: script(1)
#     merges stderr into the pty, and the app classifies probe failures by
#     stderr text ("no server running", "no current client", …).
if [ "$want_pty" = 1 ]; then
  exec script -q /dev/null /bin/sh -c "$*"
fi
exec /bin/sh -c "$*"
