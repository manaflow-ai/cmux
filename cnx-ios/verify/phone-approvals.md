# Phone pairing and Face ID approvals

Branch `feat-cnx-ios-approvals`. Production audit items B2 (device trust),
B5 (Allow and answers from the phone) and B11 (Require Face ID).

Before this change:

- a Stack token was the whole device trust: anything holding one could pose
  as a phone and reach the Mac's terminals and agents;
- a phone could only deny: acpmux treats the `cnx-hostd` splice as a remote
  (`Web`) connection, and an allow or an answer needs the Mac app's person
  proof (`live.md`, finding 1);
- Settings → Require Face ID was saved and never read.

This page is the design, the security analysis for
https://github.com/manaflow-ai/cmux/issues/13742 (a trust-policy change),
and the verification record.

## Recommendation for #13742

Adopt Mac-approved device keys for every phone link, and Face ID signed
approvals for Allow and question answers:

- A token alone never reaches a Mac service: the Mac's user approves each
  phone once ("Allow “<phone>” to connect to this Mac?"), and every link
  proves the approved key.
- An Allow or an answer from the phone counts only with a Secure Enclave
  signature made after Face ID (or the device passcode), for that one prompt,
  option, answer set, Mac and daemon run, within 5 minutes, once.
- Deny and decline stay unsigned: narrowing needs no proof.

The user approved this approach for production on 2026-10-13.

## Design

### Keys on the phone (`CnxLive/PhoneKeys.swift`)

The phone makes two P-256 keys in the Secure Enclave the first time it needs
them. Only the enclave's encrypted blobs are stored, in the Keychain with
`ThisDeviceOnly` protection. A private key never leaves the enclave.

| Key | Access control | Used for |
| --- | --- | --- |
| identity | `.privateKeyUsage`, after first unlock | Each link's pairing challenge, with no prompt. |
| approval | `.privateKeyUsage` + `.userPresence`, when unlocked | Each Allow or answer: Face ID, with the device passcode as the fallback. |

Two keys, not one: a link is set up on every launch, foreground and network
change, and must not prompt; an approval must always prompt.

DEBUG builds on a simulator, which has no Secure Enclave, use software keys in
the Keychain, and `signApproval` still runs an `LAContext`
`.deviceOwnerAuthentication` check (Face ID matched with `xcrun simctl`).
Release builds never take that path: without an enclave the phone has no keys,
cannot pair with a Mac that requires pairing, and cannot approve.

Sign-out asks the linked Mac to forget the phone (`auth` with
`action: unpair`, signed by the identity key) and deletes both keys. The next
sign-in makes new keys, and the Mac asks again.

### Pairing on every link (`cnx-hostd/src/pairing.rs`)

The first channel of every link is `auth`:

1. The phone opens `auth` with `{identityKey, approvalKey, name, action}`.
   Keys are 65-byte X9.63 points as lowercase hex.
2. hostd sends `{challenge, mac}`: 32 random bytes and its own device id. The
   phone refuses to sign a challenge that names another Mac.
3. The phone signs, with the identity key:
   `cnx-link-auth-v1 \0 mac \0 phone \0 nonce \0 identityKey \0 approvalKey \0 action`.
   `phone` is the link's device id, which the backend stamps on every signal
   (hostd never takes it from the arguments).
4. hostd verifies the signature. Then:
   - the device id with both keys is on the app's approved list: `{ok}`;
   - otherwise hostd emits `pair_request` to the app, sends `{pending}`, and
     waits up to 120 s for the app's next `devices` line to approve or deny.
5. Until a link's `auth` succeeds, every other service on it, `echo`
   included, is refused with close code `unpaired`.

Unsupervised hostd (tests, `run-host.sh`) has no app to approve and serves
links as before. The app always runs hostd supervised.

### The Mac (`CmuxNextMobile`, the iPhone host)

- `pair_request` shows a cmux dialog, app-wide: "Allow “<phone>” to connect to
  this Mac?". The body names the account and the approval key's fingerprint.
  Allow pairs it; Don't Allow refuses that identity key (it does not ask
  again; a new key, after the phone signs out and in, asks again). Closing
  the dialog without an answer decides nothing.
- One dialog per phone at a time; a repeated request while it is open is
  dropped.
- `CnxPairedDevices` keeps the list per signed-in user in a 0600 file in the
  app's cnx-host state folder. Another user starts empty, and signing out of
  the Mac clears it.
- The list goes to hostd as the `devices` control line (at start and on every
  change), and to acpmux as approvers (`_acpmux/approvers_set`), on the app's
  own person-proven unix connection (`CnxApproverSync`). That connection stays
  open; a new connection after a daemon restart sends the list again.
- Settings → Mobile can show `paired` (name, paired date, key fingerprint) and
  revoke one with `revokePhone(id:)`. Removing a phone from the account
  (`removePhone(id:)`) also forgets it here. A phone that signs out asks to be
  forgotten (`unpaired`).

### Approving (`CnxLive/AcpmuxHub.swift`)

An Allow from any surface (the chat's permission bar, the Feed's buttons and
its Allow swipe, and later Chief) and every question answer go through
`AcpmuxHub.respond` or `answer`. For anything but a reject option, the hub:

1. reads the prompt with `_acpmux/info`: its `decisionNonce`, the daemon run
   `personInstance`, and the option's kind;
2. asks for Face ID. The system sheet names the tool ("Allow “rm -rf
   build”") or says "Send your answer to the agent";
3. signs and sends `_acpmux/permission_respond` with
   `_meta.acpmux = {decisionNonce, approverDecision: {approver, expiresAt,
   signature}}`.

A reject option is never signed and never prompts. A cancelled Face ID sends
nothing and says so under the card.

The signed payload:

```
acpmux-approver-decision-v1 \0 instance \0 macDevice \0 approver \0 session
\0 permission \0 option \0 nonce \0 expiresAt \0 answersDigest
```

- `instance`: the daemon run's `personInstance`.
- `macDevice`: the Mac's cnx device id (the app sets it with the approvers).
- `approver`: the phone's link device id.
- `expiresAt`: Unix seconds, now + 120 s on the phone.
- `answersDigest`: lowercase hex SHA-256 of the answers in canonical JSON
  (keys in byte order, no whitespace, only `"`, `\` and control characters
  escaped), or empty for a plain allow.

The signature is ECDSA P-256 / SHA-256, raw `r || s` as lowercase hex.
acpmux, hostd and the phone each have a test with the same fixed vectors.

### What acpmux checks (`hub/approvers.rs`)

- `_acpmux/approvers_set {macDevice, approvers: [{id, publicKey, name}]}`
  and `_acpmux/approvers` are accepted only from the person's connection.
  Everyone else, Web connections included, gets `permission.person_required`.
  At most 16 approvers; a bad entry refuses the whole set. The set lives in
  memory only, never in a file.
- A `permission_respond` with `approverDecision` counts when, in the person
  check and again under the prompt's lock:
  - the prompt is pending with that `decisionNonce`;
  - the approver is enrolled and the signature verifies over this daemon
    run, the enrolled Mac id, the session, permission, option, nonce, expiry
    and the digest of the answers it carries;
  - `now <= expiresAt <= now + 300 s`;
  - it carries no `answeredBy` (that stays the person's own claim);
  - the nonce has not counted yet. The answer that counts spends it (the same
    spent store as the Mac's HMAC decision proof), so a replay or a racing
    second answer counts nothing.
- From a Web connection the existing rule still holds: only `allow_once` or
  `reject_once`, never a lasting grant.
- Anything else is `permission.person_required` and the prompt stays pending.

### App lock (`CnxShell/AppLock.swift`)

With Settings → Require Face ID on, cmux opens locked and locks again when it
goes to the background. Face ID, or the passcode, unlocks it. The app
switcher snapshot shows the lock. A device with no passcode cannot check the
owner, so it stays unlocked.

## Security analysis

Following the relay rules in the repository's CLAUDE.md:

- **Default deny.** hostd's service list is unchanged. The new `auth` service
  is the only one open before pairing. Its arguments are two public keys, a
  display name and `pair` or `unpair`; nothing in them names a command, a
  path, a session or another device.
- **Scoped ids.** The device id comes from the backend-stamped signal
  envelope, never from the phone's arguments. `unpair` works only for the
  link's own device id with its approved identity key.
- **Local command or content execution.** None is added. `auth` runs no
  process and reads no file. acpmux's new methods change an in-memory key list
  and are person-only.
- **Access to unowned objects.** A signature binds one prompt, option,
  answer set, Mac and daemon run; it cannot answer another prompt, another
  session or another Mac.
- **Local-state exposure.** hostd sends the phone only its challenge and the
  Mac's own device id. The paired list stays on the Mac (0600).
- **Residual risks.**
  - The Worker relays WireGuard and DTLS keys, so it remains trusted for the
    transport. A Worker that relays a pairing challenge to the real phone
    could ride its link. Binding the pairing signature to the transport keys
    (channel binding) is a follow-up.
  - A same-user process that writes the app's paired-devices file can add its
    own key, which the app then gives hostd and acpmux. That is the same class
    as the existing same-uid file-write risk in acpmux (`hub/person.rs`: an
    agent that edits `config.json` can already widen the policy).
  - The first pairing prompt asks the person at the Mac. If nobody is there,
    the phone waits 120 s and retries on its next link.

## Tests

- Rust, acpmux (`cargo test -p acpmux`): `hub::approvers` unit tests (the
  fixed vector, every field change, expiry, revocation, bad sets) and four
  integration tests in `tests/person_allow.rs` against the real daemon:
  only the person enrolls; a signed allow counts once and stops when revoked;
  a signed answer covers exactly its answers.
- Rust, cnx-hostd (`cargo test -p cnx-hostd`): the fixed challenge vector,
  the standing rule, the `devices` control line, and two end-to-end tests over
  the fake signaling server: a token alone reaches no service, a forged
  signature asks nobody, the Mac's approval opens the link, the next link
  passes at once, a new approval key asks again, unpair reaches the app, and
  a refused phone is closed `denied`.
- Swift, CnxLiveTests: the same vectors (canonical answers, payload, link
  challenge); the hub signs an allow and not a deny, and a cancelled Face ID
  sends nothing.
- Swift, CmuxNextMobileTests (`CnxPairingTests`): pairing events, decisions,
  the `devices` line and acpmux params, and the per-user 0600 file.

## Known gaps

- Chief over the link has no permission card yet (`live.md` finding 7). When
  it gets one, its Allow goes through `AcpmuxHub.respond` and is signed.
- Settings → Mobile rows for paired phones (with Remove) are for the Mobile
  page's owner (`feat-cnx-ios-machost`): the service publishes `paired` and
  `revokePhone(id:)`.

## Verification

Filled in below by the live run.
