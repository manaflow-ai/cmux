# Lock bridge: agents keep running while the Mac is locked

Leo, 2026-11-06: "acpmux not dying just cuz mac is locked for whatever reason / similar to the dont
sleep while using feature tho ofc i forsee a couple security things we wanna make sure we get right".

## The setting

`sessions.keepAwakeWhenLocked`, "Keep Agents Running While Locked", Settings > Agents > Sessions, right
under "Keep Mac Awake While Agents Work" (`sessions.keepAwake`). A toggle, **off by default**. It
extends that setting rather than adding a second mechanism:

| `sessions.keepAwake` | screen unlocked | screen locked, toggle off | screen locked, toggle on |
| --- | --- | --- | --- |
| Off | sleeps as usual | sleeps as usual | sleeps as usual (Off wins) |
| While Plugged In (default) | awake on adapter while an agent works | same | same, and on battery too |
| Always | awake while an agent works | same | same |

Before this, a MacBook on battery under the default idle-slept a few minutes after it locked, and the
turn died with it. On adapter power the existing hold already kept a locked Mac up.

The hold is the one Keep Mac Awake takes: IOKit `PreventUserIdleSystemSleep` (the app's
`ProcessInfo` activity with `.idleSystemSleepDisabled` is the same assertion). acpmux takes it itself
(`cmux-tui/crates/acpmux/src/hub/lock_bridge.rs`, `src/mac_lock.rs`), so it holds whether the app is
frontmost, in the background or quit. The lock is read in process from
`CGSessionCopyCurrentDictionary`'s `CGSSessionScreenIsLocked`, as `NotificationPreviews` reads it.
`acpmux status` shows `lockBridge: {lock, on, holding, lockedForS}`; `pmset -g assertions` names the
hold "cmux keeps agents running while this Mac is locked".

## Security

### 1. The hold is bounded

The assertion is held only while all of these are true, checked on every session status change and
every 15 s while a session runs or waits:

- the toggle is on and Keep Mac Awake is not Off;
- the screen is locked (an unknown lock state holds nothing);
- a turn is running, or a turn waits for the person and the last running turn ended less than
  10 minutes ago;
- this locked stretch is under 2 hours.

A locked stretch starts when the worker first sees the screen locked, and only a read that says
unlocked ends it. Turns one after another share it: a turn that ends and a new one that starts while
the screen stays locked do not open a new window, and neither does a lock read that fails. If the Mac
is unlocked and locked again while no turn runs, the worker does not see it, and the next turn counts
from the earlier lock: the hold can only end sooner, never later.

When no session runs or waits, the worker releases the hold and sleeps until the next status change:
no timer runs. Neither a turn that never ends nor turn after turn can keep the Mac up past 2 hours of
one locked stretch, and a question nobody answers cannot keep it up past 10 minutes. Quitting or crashing acpmux drops the assertion (IOKit
releases a dead process's assertions).

### 2. Credentials stay where they are

The bridge reads, copies and moves no credential. Each login keeps working through a lock only
because of where it already lives:

| Credential | Where it lives | Readable while locked |
| --- | --- | --- |
| cmux account tokens (`cmux-auth-access-token`, `cmux-auth-refresh-token`) | data-protection keychain, service `<bundle id>.auth`, `AfterFirstUnlockThisDeviceOnly` (`KeychainStackTokenStore`) | yes |
| CodeRouter provider API keys | keychain, `AfterFirstUnlockThisDeviceOnly` (`ProviderKeyStore`) | yes |
| Cloud device secret, Iroh identity and relays | keychain, `AfterFirstUnlockThisDeviceOnly` (`NativeDeviceSecret`) | yes |
| iPhone host identity, phone push keys | keychain, `AfterFirstUnlockThisDeviceOnly` (`MobileHostMacIdentity`, `PhonePushCrypto`) | yes |
| Mac approver key | Secure Enclave key, its blob `AfterFirstUnlockThisDeviceOnly` (`AcpmuxMacApprover`) | signs only when the person approves (item 3) |
| Claude Code login | the harness's own: login keychain item `Claude Code-credentials` or `~/.claude/.credentials.json` | yes, unless the person set the login keychain to lock with the screen; then Claude Code fails to refresh and says so, and nothing copies the token out |
| Codex login | the harness's own `~/.codex/auth.json` (0600) | yes |
| acpmux peer token | `ACPMUX_HOME/run/peer.token`, 0600, new at every daemon start | yes |
| Remote screen (VNC) passwords | keychain, `WhenUnlocked` (`RemoteVNCCredentialStore`) | no: viewing a remote screen needs the person at an unlocked Mac |
| Hand presence key | keychain, `WhenUnlockedThisDeviceOnly` (`HandPresenceKey`) | no, by design: a hand counts as present only while unlocked |

acpmux passes a harness only what it passed before (per-profile env such as `CLAUDE_CODE_OAUTH_TOKEN`).
Nothing new is written to disk.

One existing downgrade path is not changed here and is tracked as a follow-up:
`FallbackTokenStore` moves the cmux account tokens to a 0600 file when any keychain write fails. Its
doc says this is for `errSecMissingEntitlement` (-34018) on ad-hoc builds. An
`AfterFirstUnlock` item can be written while the screen is locked, so a lock does not trigger it.
Narrowing it to -34018 is a Swift change for its own PR.

### 3. Anything that needs the screen or a person waits, typed, and is never auto-approved

- **Computer Use.** A locked screen shows only the lock screen: a screenshot sees it, and a click or a
  keystroke lands in its password field. While the screen is locked, every Computer Use tool call
  gets an error result `{"structuredContent": {"error": "mac_locked"}, "isError": true}` with the text
  "mac_locked: this Mac's screen is locked ...", and never reaches the helper. Both drivers go through
  it: the helper v2 bridge (`acpmux cua-mcp`) and the legacy `cmux-cua mcp`, which acpmux now starts
  as `acpmux cua-lock-gate -- cmux-cua mcp ...` on a Mac (`src/cua_lock_gate.rs`). This applies
  **whether or not the toggle is on**: it is the safe answer on any locked Mac. `tools/list` still
  answers, so the agent knows the tools exist and can retry after the unlock.
- **Permission prompts and questions.** Unchanged: a request waits until the person answers, on the Mac
  or from an enrolled phone with its signed decision (`hub/person.rs`). No timeout allows anything.
  `_acpmux/permission_pending` now carries `macLocked: true` when it was sent while the screen was
  locked, so a client can say "Mac is locked" instead of showing a card nobody can click.
- **Consent cards.** Computer Use's screen and control consent are checked on every call
  (`machine/consent`); a locked Mac changes no grant, and a call that waits on the lock never reaches
  the consent check.

### 4. A locked Mac is not easier to drive remotely

No remote path changes auth on lock, and the bridge opens no listener:

- Peers still need the dashboard token and `x-acpmux-peer-token` over loopback.
- Phone access is still off by default. Once on, it still needs pairing approval, and an allow
  still needs the phone's signed approver decision (300 s).
- A Mac approver's allow still needs that Mac's Secure Enclave signature (120 s).
- cmux-rd-host owner links are still one-time tokens.

The bridge only stops idle sleep. While locked, the screen stays locked, Computer Use cannot act on it
(item 3), and every approval still comes from the person.

### 5. Lid closed on battery, low battery

macOS sleeps the Mac anyway: `PreventUserIdleSystemSleep` blocks only idle sleep. A closed lid on
battery (without an external display) still sleeps, and so does low battery, a forced sleep, or a
sleep from the Apple menu. The bridge does not fight it: no `pmset`, no `disablesleep`, and no
`caffeinate -s`. The turn pauses with the Mac. On wake, acpmux's existing reconnect resumes the
harness connection; the worker sees the lock again and holds again only if all of item 1 is still
true. The display still sleeps on its own schedule while locked.

## Not from a phone

The toggle changes how this Mac sleeps, which is the person's call at the Mac: it is `.userOnly` in
the agent policy (an agent cannot set it), and a paired phone does not set it either. A phone sees the
effect: a locked Mac's sessions keep answering, and a permission card says the Mac is locked.
