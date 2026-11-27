# Agent connection contract

The link between the app's chat pane and the agent service (the acpmux daemon) recovers by itself. suite.py checks
every rule below against a real built app and a real daemon; a rule it cannot check yet is said so here.

## Faults

An app update (Restart to Update, the bundle swapped), the daemon ending (SIGTERM, SIGKILL, a crash), the app ending
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

Fleet Macs through `cmux-ci` (`scripts/measure/agent-conn-chaos.sh`), alone on the host. It never runs on cosmic-gray
or air-blue (Leo's own Macs) or on big-red; both the entry script and suite.py refuse those names. It installs no
launchd agent. The daemon it starts is the DEV build's own, under a scratch `ACPMUX_HOME`.

## Expected failures

`XFAIL` in suite.py names each case expected to fail until a sibling branch lands. A marked case that passes (XPASS)
fails the suite, so the mark comes off the day the fix lands.
