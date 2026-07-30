# Acceptance test: a reconnect that needs a login

When a mirror's control stream drops and the reconnect cannot authenticate, cmux offers a
login and resumes afterwards. The reconnect runs `BatchMode=yes` on pipes with no tty, so a
password / MFA / security-key touch cannot be satisfied by retrying.

Automated equivalent: `scripts/remote-tmux-reconnect-auth-harness.sh` (exit code = failed
scenarios). It covers all five criteria below: scenario 1 covers 1, 2 and 5, scenario 2
covers 3, scenario 3 checks the pane does not vanish before the reconnect, and scenario 4
checks it closes after it. Run that first; the steps here are for manual verification on a real 2FA host.

## Pass criteria

1. Killing the stream while the shared master is gone does **not** leave a silently frozen
   mirror. A workspace titled **"Sign in to `<host>`"** appears, focused, with the login
   prompt in it.
2. The mirror's workspaces and their scrollback are **still there** while you log in —
   nothing is torn down, because the connection is parked, not ended.
3. Completing the login **resumes the mirror by itself**, with no further prompt and no
   manual reattach, and the login workspace closes once the host is back — cmux opened it,
   its purpose is served, and leaving it means a flapping host collects one per flap.
4. Cancelling instead (close the login tab) leaves the mirror intact and recoverable: it
   goes back to retrying, so a later failure offers a fresh login rather than leaving that
   host stuck until cmux restarts.
5. One login tab per host, even when several sessions on that host drop at once.

## Path A — hermetic, no 2FA, no network games (preferred)

Uses the loopback sshd the fuzz harness already relies on, so auth is a keypair you can
break and restore on demand. Deterministic on any machine.

```bash
# 1. Bring up the loopback sshd (generated keys, isolated TMUX_TMPDIR), then attach a
#    mirror to it. The sshd and its ssh alias come from the fuzz host script.
scripts/remote-tmux-fuzz-host.sh cmux-fuzzhost
cmux ssh-tmux cmux-fuzzhost

# 2. Break authentication for the NEXT connection only, leaving the live one alone.
AUTH=~/Library/Caches/cmux/remote-tmux-fuzz/cmux-fuzzhost-sshd/authorized_keys
mv "$AUTH" "$AUTH.off"

# 3. Drop the shared master and the control stream, so cmux must reconnect and re-auth.
ssh -O exit -o ControlPath="$HOME/.cmux/ssh/tmux-cmux-fuzzhost-<hash>.sock" cmux-fuzzhost
# The remote command is a /bin/sh resolver script, so no argv contains "tmux -CC" —
# a pattern built on that matches nothing and the kill silently does nothing. Match
# `attach-session` and narrow to this host, or you drop every mirror on the machine.
drop_streams() {
  pgrep -f attach-session | while read -r p; do
    ps -o command= -p "$p" | grep -q "$1" && kill "$p"
  done
}
drop_streams cmux-fuzzhost
```

Expect: the reconnect fails `Permission denied (publickey)`, the retry loop stops, and the
"Sign in to cmux-fuzzhost" tab appears. The mirror is still populated.

```bash
# 4. Restore auth, then complete the login in that tab (just press return in it).
mv "$AUTH.off" "$AUTH"
```

Expect: the login exits reporting success, and the mirror resumes on its own within a couple
of seconds. Criteria 1-3 met.

For criterion 4, repeat steps 2-3 and close the login tab instead. The mirrored
workspaces must stay, and breaking auth again must offer a new login rather than being
silently swallowed.

For criterion 5, attach two sessions on the same host before step 3 and confirm both have
live control streams (`drop_streams` should report two pids). Exactly one login tab must
appear.

## Path B — a real 2FA host (what the bug was reported against)

No network unplugging needed; killing the master is enough, because the reconnect then has
to authenticate from scratch.

```bash
cmux ssh-tmux <2fa-host>                       # attach, wait for the mirror to populate
ssh -O exit -o ControlPath="$HOME/.cmux/ssh/tmux-<slug>-<hash>.sock" <2fa-host>
drop_streams <2fa-host>                        # stream EOF -> reconnect -> cannot 2FA
                                               # (drop_streams as defined in Path A)
```

Expect the login tab, complete the 2FA in it, and the mirror resumes. The exact
`ControlPath` for a host is `~/.cmux/ssh/tmux-<slug>-<fnv1a64>.sock`; `ls ~/.cmux/ssh/`
while the mirror is up shows it.

## What the automated tests cover

`cmuxTests/RemoteTmuxAuthTests` pins the decision this rests on
(`RemoteTmuxReconnectDisposition.classify`), which is the part that was wrong:

- an auth failure classifies `.authRequired`, not `.transient` (5 stderr forms),
- a `ProxyCommand` that closes the transport silently classifies `.authRequired` too, while
  a non-recoverable one (a missing proxy binary) stays `.transient`,
- a gone session still classifies `.sessionGone` and outranks a co-reported auth failure,
- unreachable / refused / reset / empty stay `.transient` so they keep retrying and do
  **not** pop a login the user cannot act on.

It also covers the two things about the login pane that a string comparison cannot see. The
command is *executed* the way a terminal command is executed
(`bash --noprofile --norc -c "exec -l <command>"`, with `/bin/echo` standing in for ssh and
a throwaway script for `$SHELL`), then the filesystem is checked: the tail must have run,
and a destination carrying `'; touch …; '` must not have executed anything. Asserting the
hostile text is merely absent from the command string would prove nothing — it belongs
there, quoted, as data.

The classifier is a pure function precisely so it is provable without driving a real `ssh`.
What the unit tests still cannot see is the wiring — that the workspace surfaces, that the
mirror survives, that the resume fires — and that is what the harness above covers.
