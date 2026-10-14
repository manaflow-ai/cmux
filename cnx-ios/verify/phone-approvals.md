# Phone-signed agent approvals

Branch `feat-cnx-ios-approvals`. Before this change a phone could only deny:
acpmux treats the `cnx-hostd` splice as a remote (`Web`) connection, and an
allow needs the Mac app's person proof (`live.md`, finding 1). With this
change an Allow on the phone counts when it is signed with a Secure Enclave key
that the Mac app enrolled as a trusted approver, after Face ID.

## Design

### Keys

- On first link to a Mac, the phone makes one P-256 signing key in the Secure
  Enclave (`ApproverKey`). The key's access control is
  `[.privateKeyUsage, .userPresence]`: each signature needs Face ID, with the
  device passcode as the fallback when Face ID fails or is not enrolled. The
  private key never leaves the enclave; only its encrypted blob is stored in
  the Keychain (`ThisDeviceOnly`).
- DEBUG builds on a simulator, which has no Secure Enclave, use a software key
  in the Keychain and gate it with an explicit `LAContext`
  `.deviceOwnerAuthentication` check (Face ID matched with
  `xcrun simctl`). Release builds never take that path: without an enclave the
  phone cannot approve and keeps deny-only behavior.
- Sign-out on the phone revokes the key on the Mac (best effort) and deletes
  it. The next sign-in makes a new one.

### Enrollment (phone to Mac)

1. On every link up the phone opens the `approver` service on the link with
   `{action: "enroll", publicKey, name}`. `publicKey` is the 65-byte X9.63
   uncompressed point as lowercase hex; `name` is the device name (at most 64
   characters, no control characters).
2. `cnx-hostd` admits only the signed-in owner's phones. It checks the
   arguments and emits one control event to the app:
   `{"type":"approver_offer","phone_device_id","public_key","name"}`. The
   approver id is the link's authenticated device id, never a value from the
   arguments. `{action: "revoke"}` emits `approver_revoke` for that same
   device id only. Unsupervised hostd (no app) refuses the service.
3. The Mac app (`CnxApproverStore`) keeps approvers per signed-in user:
   - A new device id or a new key for a known id is enrolled; an unchanged
     offer changes nothing.
   - A key the user revoked on the Mac is never accepted again (a tombstone of
     its fingerprint). The phone must sign out and in to make a new key.
   - Sign-out on the Mac, or a different user, clears the list.
   - The list is a 0600 JSON file in the app's cnx-host state folder.
4. The app hands the list to acpmux with `_acpmux/approvers_set` on its own
   person-proven unix connection (`CnxApproverSync`). It sends the list again
   after each reconnect, so a restarted daemon gets it back. acpmux keeps
   approvers in memory only and never reads them from a file.

Settings → Mobile (owned by `feat-cnx-ios-machost`) can show the list:
`IPhoneHostService.approvers` (name, device id, fingerprint, enrolled at) and
`IPhoneHostService.revokeApprover(id:)`. `pageJSON` carries them as
`approvers`.

### Approving (phone to acpmux)

An Allow from any surface goes through `AcpmuxHub.respond`. For an allow
option the hub:

1. finds the prompt's `decisionNonce` (from `permission_pending`, the
   transcript's `permission_request` record, or an `_acpmux/events` read) and
   the daemon run's `personInstance` (from `initialize`);
2. asks Face ID ("Approve with Face ID"; the reason names the agent's tool);
3. signs the canonical payload and sends `_acpmux/permission_respond` with
   `_meta.acpmux = {decisionNonce, approverDecision: {approver, expiresAt,
   signature}}`.

A deny or a cancel is never signed and never prompts.

The canonical payload is UTF-8, the fields joined by single NUL bytes:

```
acpmux-approver-decision-v1 \0 instance \0 macDevice \0 approver \0
session \0 permission \0 option \0 nonce \0 expiresAt
```

- `instance`: the daemon run's `personInstance`.
- `macDevice`: the Mac's cnx device id. The Mac app passes its own id in
  `approvers_set`, so a signature for another Mac never counts here.
- `approver`: the phone's link device id.
- `session`, `permission`, `option`: the prompt and the chosen option.
- `nonce`: the prompt's `decisionNonce`.
- `expiresAt`: Unix seconds as a decimal string. The phone uses now + 120 s.

The signature is ECDSA P-256 with SHA-256, raw `r || s` (64 bytes) as
lowercase hex. Both sides have a test with the same fixed vector.

### What acpmux checks

`_acpmux/approvers_set {macDevice, approvers: [{id, publicKey, name}]}` and
`_acpmux/approvers` (list) are accepted only from the person's connection.
Everyone else gets `permission.person_required`, Web connections included.
At most 16 approvers; ids are 1 to 128 of `[A-Za-z0-9_.:-]`; keys must be
65-byte uncompressed points.

For a `permission_respond` allow that carries `approverDecision`, in the
person check and again under the prompt's lock:

- the session and permission are pending here, with that `decisionNonce`;
- no `answers` (questions stay the person's own) and no `answeredBy`;
- the option is offered and, from Web, is `allow_once` (the existing rule);
- the approver is enrolled and the signature verifies over the payload with
  this run's instance and the enrolled Mac device id;
- `now <= expiresAt <= now + 300 s`;
- the nonce has not counted yet. The answer that counts spends it (the same
  spent-nonce store as the HMAC decision proof), so a replay, or a second
  device racing the first, counts nothing.

Anything else is `permission.person_required` and the prompt stays pending.

### Security notes

- Default deny stays: the new hostd service has no command-bearing
  parameters and acts only for the link's own device id. The new acpmux
  methods are person-only; no Web or peer path can add an approver.
- A signature covers one prompt, one option and one daemon run, expires in at
  most 5 minutes, and counts once.
- Residual: any device that signs in with the user's account and links to the
  Mac is enrolled without a Mac-side confirmation (the user chose this). The
  Mac shows every approver and can revoke it. A same-user agent that writes
  the app's approver file could add its own key at the next sync. That is the
  same class as the existing same-uid file-write risk (`hub/person.rs`: an
  agent that edits `config.json` can already widen the policy).

## Known gaps

- Question answers from the phone still need the Mac (a proof never covers
  `answers`).
- Chief over the link has no permission card yet (`live.md` finding 7). When
  it gets one, its Allow goes through `AcpmuxHub.respond` and is signed the
  same way.

## Verification

See the "Verification" section below once filled in.
