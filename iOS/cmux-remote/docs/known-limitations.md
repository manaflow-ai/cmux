# cmux-remote known limitations

## Terminal output is snapshot-based, not streamed

**What's missing.** cmux does not currently expose a streaming PTY-output
RPC. The only relevant primitives are:

* `cmux read-screen --surface <id>` — one-shot text snapshot of the
  visible viewport (and optionally scrollback).
* `cmux tmux-compat capture-pane` — same shape, tmux-compat aliasing.
* `cmux tmux-compat pipe-pane --command <shell>` — pipes the *current*
  pane text through a local shell command and exits.

There is no `surface.tail`, no `pane.subscribe`, no PTY raw-byte stream.

**What we do instead.** `TerminalSurfaceViewController`:

1. Refreshes the SwiftTerm emulator from `read-screen` on every
   `surface.input_sent` / `surface.key_sent` / `pane.focused` /
   `surface.focused` event (driven by the live event stream).
2. While the surface view is in the foreground, also polls `read-screen`
   at ~750 ms cadence so output that arrives without an event still
   appears.
3. Computes a naïve delta: if the prior snapshot is a prefix of the new
   one we only feed the suffix; otherwise we clear and repaint.

**Why this is acceptable for v1.** The most valuable iOS use cases are
agent-decision approval, notification triage, and short interactions —
all of which work with a near-real-time snapshot. Pure typing/CLI hacking
is much better on the Mac.

**The cmux-side fix.** Add a v2 RPC `surface.tail` that streams output
deltas as base64-encoded byte frames, keyed by surface UUID, terminating
on disconnect or close. cmux-remote already abstracts the transport behind
a `CmuxSSHTransport` so adopting the new RPC would be a localised change.

## Background events arrive only via BGAppRefreshTask

iOS suspends the app, the SSH socket dies, and there is no public
"keep an SSH session alive" entitlement. We accept this and:

* Drain the notification list and pending Feed decisions every BG refresh tick
  (~15 min budget).
* Surface a follow-up local notification for anything newly waiting, including
  pending permission/question/plan decisions when the device grants background
  runtime.
* Rely on the Live Activity's `staleDate` to make it clear the surface
  isn't live while the app is backgrounded.

True real-time delivery while the app is suspended requires APNs push
originated from a cmux-side daemon — out of scope for this PR.

## RSA SSH keys are intentionally not supported

The cmux-remote keychain store accepts ed25519 and ECDSA P-256 only. RSA
is still widely deployed but adds non-trivial parsing surface and is on
the way out per Apple's own toolchain trajectory. Users with only RSA
keys must generate an ed25519 key (which takes ~5 seconds) and add it to
the Mac's `~/.ssh/authorized_keys`.

## Secure-Enclave-only signing is staged

`CmuxResolvedCredential.Material.secureEnclaveSigner` is wired into the
type system but rejected by `CitadelSSHTransport`. Citadel's
`SSHAuthenticationMethod.custom(_:)` path lets us hook in a SE-backed
signer, but the SSH protocol details (signing the auth-blob in P-256
ECDSA format Apple's Secure Enclave produces vs the OpenSSH wire format)
need an additional bridge. Tracked as a follow-up.

## Hardware-keyboard shortcut catalogue is app-level only

Per SwiftTerm's documented behaviour, the terminal view consumes keys in
`pressesBegan` directly. App-level `UIKeyCommand`s on the responder
chain head only fire for chords with Cmd-modifier or `Esc`. Plain
alphanumerics, arrow keys, function keys, and Control combos route to
SwiftTerm. This is the right behaviour for terminal work but means the
discoverability HUD does *not* list every shortcut a vim user might
expect.

## No multi-window iPad Stage Manager polish yet

We declare `UIApplicationSupportsMultipleScenes = YES` and provide a
`SceneDelegate`, but Stage Manager / external display layouts are
generic — we do not yet take advantage of per-scene workspace pinning
(e.g. one Stage Manager window per active workspace). Follow-up.

## Push-to-start Live Activities require server work

`Activity<CMUXActivityAttributes>.pushToStartTokenUpdates` is wired but
there is no cmux-side sender. A Live Activity will start in-app and can
update via APNs once we register a push token, but cold-starting an
activity while the app is not running requires a cmux daemon to send the
APNs `liveactivity` push. Tracked as a follow-up.

## Host-key trust is TOFU, not CA-backed

cmux-remote displays the canonical OpenSSH SHA256 host-key fingerprint
for first-connect trust. Compare it on the Mac with:

```bash
ssh-keygen -E sha256 -lf /etc/ssh/ssh_host_*.pub
```

Trust remains per-host TOFU pinning. There is no host CA, DNS SSHFP, or
managed-device trust bootstrap yet, so first-connect verification is
still a user responsibility.

## No Cellular Mosh fallback

Blink and La Terminal both wrap [Mosh](https://mosh.org/) for resilient
roaming over cellular. We use plain SSH + reconnect + cursor replay. The
event-stream resume contract makes this acceptable for now, but a future
revision should evaluate Mosh.
