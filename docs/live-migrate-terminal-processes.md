# Moving a running terminal process into cmux without killing it

Question (Nov 5): a program runs in tmux, herdr or Claude Code inside Ghostty,
Rex or another terminal. Can cmux take it over while the process keeps running?

Answer: yes when a multiplexer holds the PTY (tmux, herdr, zellij), on every
OS. Yes on Linux for a plain terminal too, via `reptyr -T`. On macOS with SIP
on, a program that runs directly in Ghostty or another emulator cannot be
moved: only that emulator holds the PTY master, and macOS gives no way to take it.

## Why: who owns the PTY master

A terminal program reads and writes the *slave* side of a pseudo-terminal
(`/dev/ttys073`). The *master* fd is held by whatever draws the screen.
When the last master fd closes, the kernel hangs up the tty and sends SIGHUP to
the session, and the default action kills the program. To "migrate" the
program, the new terminal must get a master fd for the same tty, or the program
must be moved onto a new tty. That gives these routes:

| Route | What moves | Needs | Works on |
|---|---|---|---|
| Re-attach to a multiplexer | nothing: tmux/herdr/zellij keep the master, cmux opens a new client | program started under the multiplexer | macOS, Linux |
| SCM_RIGHTS handoff | the master fd, passed over a Unix socket | the old emulator to cooperate (Ghostty, Rex and others do not) | macOS, Linux |
| `reptyr -T` (steal the master) | the master fd, taken out of the emulator with ptrace | ptrace rights over the emulator | Linux |
| `reptyr PID` / lldb injection (re-point fds) | the program's fds 0-2 move to a new tty | ptrace/task_for_pid over the program | Linux; macOS only as root with SIP off |

## Experiments (Nov 5, scripts in `experiments/live-migrate/`)

Test tools: `probe.py` logs its pid, ppid, session, tty, SIGWINCH and SIGHUP
once a second. `owner.py` is a stand-in emulator: it holds the master, and it
can pass it on with `--handoff`. `receiver.py` is a stand-in cmux that takes the
fd. `tfp.c` calls `task_for_pid`.

### 1. tmux, macOS: works

- Started `tmux new -d -s lm` with `probe.py` in window 0 and Claude Code
  (pid 19731) in window 1.
- Attached a second client from a stand-in emulator (`owner.py tmux attach`),
  then closed that emulator. The client went away. tmux, the probe and Claude
  Code kept running (`ps`: 19731 `Ss+ ttys091`, same pid, elapsed time kept
  growing).
- Attached from a cmux terminal (`tmux attach -t lm`), then from a new cmux
  workspace with `scripts/cmux-adopt 19731 --detach-others`. The client size
  became 164x97. Claude Code got SIGWINCH and redrew at 164 columns: the full
  input box and status line came back, with nothing lost.

### 2. herdr, macOS: works

- `herdr --session lmherdr` started from a stand-in emulator, which then
  exited. `herdr server` (pid 43816) re-parented to launchd and kept running.
- `herdr pane run w1:p1 "python3 probe.py H.log"` started probe 46444.
- `scripts/cmux-adopt 46444` found the herdr server in the process's
  ancestors, read the session name from its socket path (`lsof`), and opened
  `herdr session attach lmherdr` in a new cmux workspace. The probe kept
  beating in the cmux screen, and it logged `SIGWINCH size=53x23`.
- zellij follows the same pattern (`zellij attach NAME`). It was not run
  live, because the only zellij session on this Mac belongs to the user.

### 3. Plain terminal, emulator exits: the program dies

`owner.py python3 probe.py`, then the owner exits without a handoff. The probe
logged `SIGHUP (logged, exiting)` in the same second. Its pid was gone. This is
what happens when a Ghostty window closes.

### 4. SCM_RIGHTS handoff (cooperating emulator): works on macOS

`owner.py --handoff /tmp/lm-recv.sock` sent its master fd to `receiver.py`
and exited. Result for probe 11195:
- It stayed alive with the same sid, pgid and controlling tty (`/dev/ttys073`).
- Its output kept arriving at the receiver (`beat 3..8`).
- Input arrived (`input b'hello-from-receiver\n'`).
- `TIOCSWINSZ` on the master gave it `SIGWINCH size=132x40`.

When the receiver closed the fd, the probe got SIGHUP, as expected.
`receiver.py --relay` bridges the fd to its own tty, so the program shows up
in a cmux tab. This is the clean design for handoff between cmux processes,
or with any emulator that adds a "hand over this PTY" socket. Ghostty, Rex
and Terminal.app have no such API.

### 5. macOS injection (reptyr-style): blocked on a normal Mac

- This Mac (SIP on, Developer Mode off): `task_for_pid` returned
  `5 (os/kern) failure` for every target. That was so even for my own
  unsigned child. The targets were Ghostty 31628, probe 19702, Claude Code
  19731 and the calling shell.
- Code signatures: Ghostty `flags=0x10000(runtime)` (hardened, no
  get-task-allow), the `claude` binary `flags=0x10000(runtime)`, and `/bin/zsh`
  `Platform identifier=26` (platform binary). With SIP on, even root cannot get
  the task port of a platform binary. Hardened binaries refuse debuggers that
  lack Apple's restricted entitlements.
- aws-m4pro-3 (SIP **disabled**, root): `task_for_pid` succeeded for every
  target. `sudo lldb -p PROBE` ran `open("/dev/ttys001")`, `dup2` onto 0, 1
  and 2, and `signal(SIGHUP, SIG_IGN)`. Then the stand-in emulator was killed.
  The probe stayed alive and its output went to the new pty (`beat 13..16`,
  `lsof` showed fds 0-2 on `/dev/ttys001`). But `ps` showed `TTY ??`: the
  probe had no controlling tty any more. So resize (SIGWINCH), `/dev/tty`,
  Ctrl-C and job control are lost. A shell under the emulator also dies on
  close and hangs up its jobs. This works in a lab only. It is not a product
  route.

### 6. Linux (cmux-dev-backend-1, kernel 7.0, ptrace_scope=1): works

reptyr was built from source in `~/lm` and given `cap_sys_ptrace` on that one
binary. Nothing else on the system changed.
- `reptyr -T PID` run in a new tmux pane (stand-in for a new cmux terminal):
  it stole the stand-in emulator's master. The emulator was killed. Probe
  4137489 kept its session, ctty `/dev/pts/0` (before and after) and pid. Its
  ppid became 1. It got input (`typed-after-T`) and `SIGWINCH 120x40` and
  `90x20` from the new terminal. This is a full migration.
- `reptyr PID` (fd re-pointing): the probe moved from `pts/1` to `pts/5`, got
  input and SIGWINCH, and survived the emulator. Note: run with `sudo`, it
  failed (`Unable to open the tty in the child: Permission denied`), because
  the new pty then belongs to root. Run it as the same user with
  CAP_SYS_PTRACE or `ptrace_scope=0`.
- This is the route for the cmux remote daemon on Linux. It is the same user,
  and the daemon can hold the capability.

## Claude Code and other TUIs after the move

They need no changes. When the new terminal's size differs, the move sends
SIGWINCH and the TUI redraws (shown above with Claude Code 2.1.317 in tmux).
The scrollback that the old emulator drew does not come along. The
multiplexer routes keep their own scrollback.

## Prototype: `scripts/cmux-adopt`

```
cmux-adopt --list                  # tmux, zellij, herdr sessions
cmux-adopt PID [--detach-others]   # find the route for a pid, open it in cmux
cmux-adopt tmux:lm:1.0 | herdr:NAME | zellij:NAME
```

For a pid, it walks the process ancestors:
- tmux pane pid (all tmux sockets): `tmux attach -t S ; select-window ; select-pane`
- zellij server: `zellij attach NAME`
- herdr server: the session name comes from the socket path
- on Linux, otherwise: `reptyr -T PID`

On macOS without a multiplexer, it explains why and exits 2. It opens the
route with `cmux workspace create --name "adopted: …" -- ARGV`, or uses
`--tab` for the focused pane.

## What cmux could build next

1. `cmux adopt` in the Rust CLI, with this route logic, plus a Cmd+Shift+P
   entry that lists adoptable tmux, herdr and zellij sessions.
2. tmux control mode (`tmux -CC`), like iTerm2: tmux windows become native
   cmux tabs and panes, instead of one terminal running a tmux client.
3. On the Linux remote daemon: `reptyr -T` adoption of a plain-terminal
   process (same user, CAP_SYS_PTRACE).
4. A PTY handoff socket in cmux itself (SCM_RIGHTS), so cmux processes and
   other emulators can pass live terminals to cmux without ptrace.
