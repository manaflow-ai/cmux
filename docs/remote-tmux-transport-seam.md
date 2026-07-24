# A transport seam for remote tmux

Remote-tmux hardcodes `/usr/bin/ssh` as the way it reaches a host. This describes three
seams that let a different transport carry the same control stream, so a connection can
survive network drops instead of reconnecting from scratch, and a plan for proving the
result: a mock transport for unit speed, a real sshd plus a real
[EternalTerminal](https://github.com/MisterTea/EternalTerminal) server for end-to-end
truth, and a seeded model-based fuzz that ratchets until the state machine holds.

## Why

Reaching a remote tmux over plain ssh ties two unrelated things together: the bytes of the
`tmux -CC` control protocol, and the lifetime of one TCP connection. When the network
drops, the ssh child exits, and the only recovery is to spawn a new ssh, which
authenticates again.

For a host with cheap auth that is invisible. For a host with a second factor, every blip
costs an interactive prompt, and because the reconnect path runs non-interactively it
cannot prompt at all: it fails, gets classified as transient, and retries forever while
the mirror stays frozen. Persistent-session transports exist to decouple those two
things. An ET client stays alive across a drop and resumes the same byte stream, so there
is no new connection to authenticate.

Making the transport switchable is also the cheapest way to stop hardcoding assumptions
that are only true of ssh, which is what the reconnect logic does today.

## Where the transport is decided today

Two functions build the argv, both on `RemoteTmuxHost`:

- `controlModeArguments(sessionName:createIfMissing:)` for the long-lived `tmux -CC`
  stream.
- `sshControlArguments(controlPersistSeconds:batchMode:)` for one-shot commands and for
  opening the shared ControlMaster.

`RemoteTmuxControlConnection.spawnProcess` launches the first as a `Process` with pipes and
feeds stdout to `RemoteTmuxControlStreamParser`. `RemoteTmuxSSHTransport` runs the second.

## Seam 1: the transport protocol

```swift
protocol RemoteTmuxTransport: Sendable {
    /// argv for the long-lived `tmux -CC` control stream.
    func controlStreamArgv(host: RemoteTmuxHost, sessionName: String, createIfMissing: Bool) -> [String]
    /// argv for a one-shot remote command (discovery, mutations).
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String]
    /// Whether the transport recovers from network loss on its own, or whether cmux
    /// must respawn it.
    var reconnectsInternally: Bool { get }
}
```

`SSHTransport` is the current behavior, unchanged and still the default. A second
implementation wraps a persistent-session transport. For ET that is:

```
et --command 'exec tmux -CC attach-session -t <session>' [--port N] <user>@<host>
```

Four details are load-bearing for any such transport. Each one is a claim about a program cmux
does not control, so each one is a check in `scripts/remote-tmux-et-conformance.sh` rather than
only a paragraph here — every defect this transport shipped with was a claim in this list that
nothing executed. Run that script against every ET version you intend to support: 7.x rewrote the
pty input path that 6.x deadlocks on, so "et behaves like this" is version-scoped.


- **Run the command, do not open a shell.** ET's `--command` runs one command and exits.
  Prefix it with `exec` so the remote process tree does not keep a shell parent around.
- **The command has to fit on one line, so et does not get the tmux resolver.** ET does not
  exec the command: it types it into a login shell and appends `; exit`. That shell reads from
  a pty in canonical mode, which delivers at most `MAX_CANON` (1024 on macOS) bytes per line,
  and ssh's `PATH` resolver is about 1113 bytes. The line never completes, so the shell runs
  nothing, the stream stays silent, and the attach dies on a timeout with nothing to explain
  it. Plain `tmux` is both short enough and correct here, because a login shell already has
  the user's full `PATH` — ssh is the opposite case, a non-login shell with a minimal one.
- **The port is per-transport and per-host.** Keep it configurable instead of assuming
  ssh's 22.
- **Never pass a flag that kills other sessions.** ET's `-x` / `--kill-other-sessions`
  terminates every one of that user's sessions on the host, not just stale ones. Some
  wrappers pass it by default, so an unrelated reconnect elsewhere can kill cmux's
  session; recover by recreating on unexpected exit rather than trying to hold a claim.

One-shot commands can keep using ssh over the existing ControlMaster even when the control
stream rides another transport. `RemoteTmuxSSHTransport.ensureMasterReady()` already
funnels the cold-start burst through a single master open, and that logic is independent
of how the `-CC` stream is carried.

## Seam 2: reconnect stops being EOF-driven

This is the part that changes behavior, and the reason `reconnectsInternally` exists
rather than just swapping argv.

Today `handleStreamEnd` treats stdout EOF as the signal to reconnect and
`beginReconnecting()` respawns with backoff. A transport that reconnects internally
produces no EOF for a network drop: the stream pauses and resumes. Reacting only to EOF is
therefore correct and cmux notices nothing, which is the goal. What it must not do is
treat a *stall* as death and respawn on a timer, because that discards a session the
transport was about to recover.

So the failure mode moves from "stream ended" to "stream is alive but wedged", and a
transport that reconnects internally needs a liveness check instead:

1. the transport process is still alive, and
2. a control-mode round-trip completes.

cmux already has the round-trip primitive: a bounded `display-message -p ok` query, used as
`awaitCommandBarrier` in `RemoteTmuxViewConnection`. Reuse it rather than inventing a
heartbeat, and give the probe a deadline: measured against 6.2.11+7, et can accept stdin while
producing no control output, so an unanswered probe is the suspicion. The next probe's due time
is that deadline, which needs no second clock.

An unanswered probe cannot be the verdict, though, because a real network interruption looks
identical from the stream's side: the transport is reconnecting underneath and cannot answer
either, and recovering there kills the process and throws away the session it was resuming.
What tells the two apart is a question asked somewhere else. One-shot commands ride ssh's
shared master even for an et connection, so `tmux has-session` reaches the host over a channel
this stream's wedge cannot touch — the same asymmetry the `etserver` restart above measures. A
host that answers proves the stream is the broken part, and that is the case to recover. A host
that does not answer is an outage, so stay connected and ask again next tick, capped at four
consecutive deferrals (about two minutes) so a host that is both unreachable and wedged still
gets its reconnect.

A transport exit does **not** mean the session is over, tempting as the symmetry is. Restarting
only `etserver` ends the stream while `tmux has-session` still succeeds, so acting on it discarded
live, reattachable sessions. EOF cannot tell "the transport died" from "the session died" for any
transport, so end-of-stream reconnects and the reattach reports which it was —
`scripts/remote-tmux-et-conformance.sh` checks this rather than leaving it here as a claim.

There is a bug here worth fixing independently of any new transport.
`handleStreamEnd`'s classifier only distinguishes "session gone" (end) from everything else
(retry with backoff, forever). A reconnect that fails because the host wants interactive
authentication lands in the second bucket, so it retries silently and forever. cmux already
detects that case (`RemoteTmuxSSHTransport.indicatesAuthRequired`) and already has a path
for handing the user an interactive ssh on initial attach
(`RemoteTmuxAttachOutcome.authRequired(sshArgv:)`, built by
`RemoteTmuxHost.interactiveAuthInvocation()`). The reconnect path should reuse that outcome
instead of looping.

## Seam 3: a pre-connect hook

Some hosts need a step before the connection that cmux has no business knowing about:
minting a short-lived credential, unlocking an agent, refreshing a token. Rather than
teaching cmux any of them, give a host an optional command, in the same spirit as the
existing per-host upload command:

```
preseedCommand: <command>   # run as `<command> <host>` before opening a connection
```

cmux runs it before opening or reopening a connection, treats a non-zero exit as non-fatal
(proceed and let the connection fail normally, so a broken hook cannot make a host
unreachable), and ignores its output. Unset means today's behavior.

Two constraints, both learned the hard way wiring one up:

- **Run it once per connection, not once per config parse.** Anything minting a single-use
  credential must not run concurrently with itself; two mints racing can invalidate each
  other. The right home is the same single-flight path that opens the shared master
  (`ensureMasterReady()`), not a per-command hook.
- **The connection that follows must allow interactive auth methods.** A pre-connect step
  that satisfies a second factor typically does so through a keyboard-interactive exchange
  that completes without prompting. Opening that connection with `BatchMode=yes` refuses
  the method outright and fails `Permission denied (keyboard-interactive)` even though
  nothing would have prompted. Piped stdin already makes a genuine prompt fail fast, so
  batch mode is not what protects against hanging.

## Proving it

Scope this at the transport, not the mirror. Render fidelity already has strong coverage
that a transport change does not improve on: `remote-tmux-render-harness.sh` asserts the
mirror's visible screen equals the remote pane's visible screen across attach, resize,
rapid re-attach and reconnect, and `remote-tmux-shape-zoo.sh` plus
`RemoteTmuxSizingUITests` cover geometry. Those stay as the regression gate and should go
green unchanged; if a transport swap breaks them, that is the answer, and re-testing
rendering under a second transport adds cost without signal.

What is genuinely uncovered is the **connection state machine**: what cmux does when a
stream stalls, resumes, dies, or fails to authenticate, and who resolves the commands that
were in flight when it happened. Every layer below targets that.

Three layers, cheapest first. The mock keeps unit tests fast, the real servers keep the
mock honest, and the fuzz is what finds the state-machine bugs.

### Layer 1: mock transport (unit speed, no network)

`scripts/remote-tmux-e2e-ssh-shim.sh` already does this for ssh: it strips the option
framing, runs the "remote" command locally, and allocates a pty with `script(1)` only when
`-t`/`-tt` asked for one. `RemoteTmuxHost.defaultSSHExecutablePath()` honors
`CMUX_REMOTE_TMUX_SSH_FOR_TESTING` in DEBUG so the real app process can be pointed at it.

Add the same seam for the transport binary (an ET shim honoring `--command` instead of
ssh's framing) so `ETTransport` gets identical treatment. The shim must reproduce the two
behaviors that bite: hand the remote command to a shell that re-splits it, and allocate a
pty for the control stream but **not** for one-shot probes, because probe classification
reads stderr and a pty merges stderr into the stream.

It must also be able to *simulate the interesting failures on demand*, which the ssh shim
has no reason to do: pause the stream without exiting (the wedge), resume after a pause
(internal reconnect), drop mid-frame, and exit with a chosen status. Drive those from
environment variables so a unit test can request one deterministically.

### Layer 2: real sshd and a real ET server (end-to-end truth)

**No containers.** Nothing in remote-tmux uses Docker today, and this should not introduce
it. (`tests/fixtures/ssh-remote/` has a Dockerfile, but that fixture belongs to the
cloud-VM image builder, not to remote-tmux.) The established pattern is a **loopback ssh
alias whose forced command pins an isolated `TMUX_TMPDIR`**, so a harness drives real ssh
against the machine's own sshd and can never touch the developer's real tmux:

```
Host cmux-srvA
    HostName 127.0.0.1
    RemoteCommand TMUX_TMPDIR=/tmp/cmux-srvA $SHELL -l
    RequestTTY yes
```

`scripts/remote-tmux-render-harness.sh` uses exactly that and returns the number of failed
scenarios as its exit code. `scripts/remote-tmux-shape-zoo.sh` builds a geometry zoo on a
real host over one ordinary ssh connection for manual exercise. Reuse both conventions:
loopback, isolated tmpdir, generated keys on a nonstandard port, exit code = failed
scenario count.

ET drops into that pattern without a container, because an ET client bootstraps over ssh to
the host and then speaks to an `etserver` there. Pointed at loopback, the whole path is
local and real:

```
cmux → et client (upstream) → ssh 127.0.0.1 (real sshd) → etserver/etterminal → tmux -CC
```

Requirements for it to be trustworthy:

- **Use upstream ET, pinned to a tag** (Homebrew formula or a source build), so the test
  proves compatibility with public ET rather than with a fork.
- **Isolate hard**: a dedicated `TMUX_TMPDIR`, a nonstandard etserver port, per-run
  generated keys with explicit `IdentityFile`/`IdentitiesOnly`. Never the default tmux
  socket.
- **Exercise a real drop, and sever it at the network layer.** This is the one property only
  a real transport can prove. Run the client through a small TCP relay the harness can pause
  and resume (a packet-filter rule works too, but a relay needs no privileges and is
  deterministic). Killing the `et` process tests the wrong thing: that is the session-gone
  path, not a recoverable outage.
- **Assert on cmux's observable state, not log text**: the mirror stays populated across the
  outage, the spawn counter does not increment, and a command issued after the resume
  completes.

Skip cleanly with a stated reason when `et`/`etserver` is absent, rather than passing
vacuously.

### Layer 3: seeded model-based fuzz (where the bugs are)

Follow `RemoteTmuxMultiplexFuzzTests` exactly: `SplitMix64` seeded from the test argument
so every draw is deterministic, a fixed seed list under `@Test(arguments:)`, a tiny
reference model playing the transport and the remote server, and a step loop that mutates
the model, drives one action, then checks the full invariant set. Failure messages carry
seed plus step index so a case reproduces exactly. No `Date()`, no
`SystemRandomNumberGenerator`, no wall-clock.

The model needs three pieces of state the ssh-only world did not have: whether the
transport process is alive, whether the stream is flowing or stalled, and whether the
remote session still exists.

Step actions to draw from:

| Category | Actions |
|---|---|
| Transport | stall the stream; resume after a stall; drop mid-frame then resume; exit cleanly; exit with an auth failure; exit with a transient failure; refuse to launch (binary missing) |
| Session | kill the session remotely during an outage; create a session; rename; churn windows |
| cmux | issue a one-shot; issue a command batch; resize; stop the connection; close the window; quit |
| Hook | hook succeeds; hook exits non-zero; hook hangs past its timeout; two opens race the hook |

Invariants to assert after every step:

1. **No respawn while an internally-reconnecting transport is alive.** The spawn counter
   must not increment for a stall or a resume. This is the property the whole design rests
   on, and the easiest one to regress.
2. **A stall never ends the connection**, and a genuine transport exit always does.
3. **An auth-required failure always surfaces an auth outcome** and never enters an
   unbounded retry loop.
4. **Every pending command resolves exactly once**, either completing or failing. Nothing
   is silently dropped across a stall, a resume, or a teardown.
5. **The parser never desyncs.** A frame split across a resume boundary either completes or
   is discarded whole; a partial frame must never be delivered as a message.
6. **The pre-connect hook runs at most once per connection open**, even when opens race.
7. **A session the user killed is never silently recreated** (the existing sticky
   never-surfaced-a-workspace gate must still hold under transport churn).
8. **Teardown is ordering-independent**: a resume that lands after `stop()` changes
   nothing.

Ratchet discipline, which is the part that makes this worth doing: when a seed fails, fix
the product, then **add that seed to the permanent list** rather than only fixing the bug.
When a real-world failure shows up that no seed produced, add the step action that would
have produced it and re-run the whole list. The suite only ever grows. A fuzz suite that
stays at its original eight seeds after finding bugs is not ratcheting, it is decoration.

## Notes on carrying a control protocol over a PTY transport

`tmux -CC` is line-oriented, and any transport that allocates a remote PTY translates `\n`
to `\r\n` on the way back. cmux already runs `ssh -tt` (also a remote PTY) so
`RemoteTmuxControlStreamParser` tolerates `\r` today. Keep an explicit test for it rather
than rediscovering it after a transport swap.

## Order of work

1. Fix the reconnect classifier so an auth-required reconnect surfaces the interactive path
   instead of retrying forever. Independent of any new transport and testable red-first: a
   reconnect whose transport fails with a permission error must produce an auth outcome,
   not a backoff loop.
2. Introduce `RemoteTmuxTransport` with `SSHTransport` as the only implementation. No
   behavior change, so the existing suites are the regression gate.
3. Add the fuzz harness against the mock transport, with the invariants above. It should
   pass for `SSHTransport` before any new transport exists.
4. Add the persistent-session transport behind per-host opt-in, with the liveness check and
   a fallback to `SSHTransport` when the transport binary is missing. Turn on the
   internally-reconnecting arm of the fuzz.
5. Add the real sshd plus upstream-ET end-to-end fixture, including a real network drop.
6. Add the pre-connect hook, with the race and timeout cases in the fuzz.
