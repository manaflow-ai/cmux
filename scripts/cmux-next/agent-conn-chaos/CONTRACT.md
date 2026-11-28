# Agent connection contract

The link between the app's chat pane and the agent service (the acpmux daemon) recovers by itself. suite.py checks
every rule below against a real built app and a real daemon; a rule it cannot check yet is said so here.

## Faults

An app update (Restart to Update, the bundle swapped), the daemon ending (SIGTERM, SIGKILL, a crash) or hanging, the
app ending
and being opened again, sleep and wake, and the network going away (the daemon socket removed or replaced, the
loopback WebSocket port blocked).

## What the person may see

- Within 3 s of the fault: nothing changes.
- After that, until the link is back: only the composer's status dot.
- Never, at any moment: an error row, "The agent service stopped.", "The agent service didn't answer in time.",
  "not connected", or a Retry button.

## What must hold after recovery

- A prompt sent while the link is down is delivered to the agent exactly once and answered once. Its row is not left
  pending.
- A turn that was running when the fault hit shows its whole output: every word the agent wrote, once each, in order.
  This holds on the page and in the store.
- The chat that was shown is shown again, with its session. Nothing is missing and nothing is unavailable.

## Bounds

The time from the fault's end to a connected chat with its turn live or done:

| fault | bound |
|---|---|
| app update, app killed and opened again | 60 s from the relaunch |
| daemon SIGTERM or SIGKILL, sleep/wake, socket gone, port blocked | 30 s |
| daemon hung (stopped, holding its lock and socket) | 45 s from the stop, while it stays stopped |

## What the suite simulates

- **Sleep/wake** is SIGSTOP of the app and the daemon for 35 s, then SIGCONT. A real sleep also stops the network and
  posts `NSWorkspace.didWakeNotification`. The agent pane has no wake hook to fake that, so the wake path itself is
  not checked.
- **The update** is the updater's relaunch hook plus Sparkle's swap of the bundle (an APFS clone swapped in with
  `renamex_np(RENAME_SWAP)`, with new page bytes and version), as `bench_relaunch_reconnect.py` does. The download
  and the signature check are not run.
- **The port block** needs root for pf. Without `sudo -n pfctl` the case is NOT RUN, never passed.
- A remote (Cloud or peer) link is not covered.

## Where it runs

Fleet Macs through `cmux-ci` (`scripts/measure/agent-conn-chaos.sh`). It never runs on cosmic-gray, air-blue,
huge-blue or big-red; both the entry script and suite.py refuse those names. It installs no
launchd agent. The daemon it starts is the DEV build's own, under a scratch `ACPMUX_HOME`.

## Real and simulated

| case | fault | real or simulated |
|---|---|---|
| update-midturn | the updater's relaunch hook, the bundle swapped, the app relaunched | real install swap; no download or signature check |
| daemon-sigterm, daemon-sigkill | the signal to the app's own daemon | real |
| app-sigkill | SIGKILL of the app, then a launch into the same HOME | real |
| sleep-wake-sim | SIGSTOP of the app and the daemon for 35 s, then SIGCONT | simulated |
| daemon-hung | SIGSTOP of the daemon only, left stopped | real hang (a stopped process), not a deadlock |
| socket-gone | the daemon's socket file moved away for 20 s, then back | real |
| ws-port-block | pf drop on the daemon's loopback WebSocket port for 20 s | real, needs root; NOT RUN without it |

## Expected failures

`XFAIL` in suite.py names each case expected to fail until an open PR lands:

- daemon-sigterm, daemon-sigkill: cmux#60429 (a reconnect starts the app's own stopped daemon).
- update-midturn: cmux#60430 (the update hand-off).
- daemon-hung: cmux#60685 (a hung lock holder is replaced).

A marked case still runs and is judged in full. A failure prints `XFAIL` with the PR and does not fail the suite. A
pass prints `XPASS` and fails it, so the mark comes off the day its PR lands.

## The daemon-only half (Linux, no app)

`linux_daemon.py` runs the cases that need no page on a machine with no app: a real acpmux daemon in a private home,
the same scripted agent, and the acpmux CLI as the only client. It checks that a client is served again within the
same bound with nothing done by the script to bring the daemon back, that each prompt reaches the agent exactly once,
and that the store holds the whole reply once. It does not judge the page, so it proves nothing about "What the
person may see"; that is suite.py's alone.

| case | fault | what recovers it |
|---|---|---|
| daemon-sigterm, daemon-sigkill | the signal to the daemon | the next client command starts a daemon, which adopts the running agent |
| daemon-hung | SIGSTOP of the daemon, left stopped | a client must be served while it stays stopped; the send is watched 90 s past the bound so a late recovery is reported with its time, and late still fails |
| sleep-wake-sim | SIGSTOP of the daemon, agent hosts and agent for 35 s, then SIGCONT | simulated, as above |
| socket-gone | the socket file moved away for 20 s, then back | the client's send during the gap |
| update-swap | a new binary renamed over the daemon's path, nothing else | the daemon hands over to a daemon of the new file by itself, and none dies in the hand-over; no download or signature check |

app-sigkill, update-midturn and ws-port-block have no daemon-only form (no app, and no WebSocket client without it).
The expected-failure marks above are about the app; this half has none.
