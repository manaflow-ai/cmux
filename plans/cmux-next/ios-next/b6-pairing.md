# B6 `pairing`: identity chain, discovery, QR pairing, trust store

Status: landed (local) on `feat-cmux-next-ios-b6-pairing`, 2026-10-06. Plan: [PLAN.md](PLAN.md) B6.
Binding: OWNERSHIP-PRINCIPLES.md, [a0-rpc.md](a0-rpc.md) 5.11, [b1-control-do.md](b1-control-do.md)
(TeamDO.hostAccess, UserDO socket registry, 4401), [b4-direct.md](b4-direct.md) 3 (X25519 keys signed
by the install key), transport.md 8 (keys), [c10-onboarding.md](c10-onboarding.md) (pair step),
[c16-platform.md](c16-platform.md) (`.pairing(URL)`).

## 1. Ownership

| Fact | Owner (single writer) | Mirrors |
| --- | --- | --- |
| Install key (P-256) and its public JWK | the device (Secure Enclave); UserDO `installs` records the public key | everyone reads it from the trust store |
| Link key certificates of a user's installs | UserDO, stream `trust:<user>` (`devices`) | the user's phones and Macs |
| Guests: other accounts' devices accepted on this user's hosts | host owner's UserDO, `trust:<owner>` (`guests`) | the owner's Macs (authorizer) and phones (devices list) |
| Remote hosts: other accounts' hosts this user's devices may reach | the guest's UserDO, `trust:<guest>` (`remote`); written only by the owner's side | the guest's phones |
| Pending cross-account requests | host owner's UserDO (`requests`) | the owner's Mac shows Accept / Decline |
| One offer (QR code): open, claimed, done | `PairingDO`, one object per offer code (existing class, new `offer` table) | nobody; a code is a credential |
| Socket admission of a guest device to a host | TeamDO (`host_guests`), read by `hostAccess` | HostDO re-asks every 60 s (b1 2) |
| Presence of a Mac | HostDO `host:<host>` (b1 4) | phones open one control socket per Mac |

Phones never write trust: every change is an op to the owner, and the phone's `DeviceRegistry` is
mirror + intent receipts (no optimistic copy).

## 2. Identity chain

```
Secure Enclave install key K_i (P-256, never leaves the device; registered in UserDO at sign-in)
  └─ signs  LinkCertificate(purpose = direct | wg)   long-lived X25519 keys, 90-day expiry
  └─ signs  SessionFingerprint(purpose = dtls)       one per WebRTC session (B2)
```

Secure Enclave keys are P-256 only (transport.md 11), so X25519 keys live in the Keychain
(`AfterFirstUnlockThisDeviceOnly`, never synced) and are bound to the install by a signature.

Canonical signed message (UTF-8, `\n`-joined, no trailing newline), ES256 over SHA-256, signature
raw `r||s` base64url (the format `verifyInstallSignature` already accepts):

```
cmux-link-cert/1
<environment>          API environment (`production`, `staging`, `test`, …)
<user>                 user_…
<install>              inst_…
<purpose>              direct | wg | dtls
<key>                  base64url, 32 bytes: raw X25519 public key, or for dtls the SHA-256 DTLS fingerprint
<issued_at>            ms since epoch
<expires_at>           ms since epoch
```

- `direct`/`wg`: `expires_at - issued_at <= 90 days`; UserDO refuses `issued_at` more than 5 min
  in the future or older than 10 min (proof of freshness at publish), and any expired cert.
- `dtls`: `expires_at - issued_at <= 15 min`, sent inside the signed `signal` offer/answer body
  (`body.fingerprint_cert`); B2 verifies it against the sender install's JWK from the trust store
  and compares it with the SDP `a=fingerprint` before accepting DTLS. The relay already rewrites
  `from`; the cert makes the fingerprint end-to-end (a compromised relay cannot swap it).
- Verification is local on every client: the trust store hands out `{install, public_jwk, certs}`,
  the verifier re-checks the signature, purpose, environment, user and expiry. A compromised DO can
  hide or revoke keys but cannot forge a cert for an existing install key.
- Rotation: publish a new cert for the purpose; it replaces the old one in the same commit.
  Sessions re-handshake on the next connect (b4-direct.md 3). Revoking the install
  (`install.revoke`, `install.sign_out`) removes its certs in the same DO turn.

The Mac (B5) publishes its `direct` cert with `host: <host id>`; UserDO confirms with
`TeamDO.hostAccess` that this install enrolled that host before it records the claim.

## 3. Same-account zero-touch discovery

1. Every signed-in install publishes its `direct` cert: `trust.key.publish` on `/v1/wire/user`.
2. The phone subscribes `trust:<user>`. Devices with `host` set are this account's Macs, each with
   its pinned `direct` key and its install JWK. No QR, no prompt: same account means trusted.
3. For each Mac the phone opens the HostDO control socket (`/v1/wire/host/<host>`) and subscribes
   `host:<host>` for presence (`online | offline | sleeping | paused`, viewers). Nothing polls.
4. The Mac's `DirectAuthorizer` (B5) is `TrustStoreAuthorizer` over its own `trust:<user>` mirror:
   a device key is allowed when it is the `direct` cert of a non-revoked own install, or of an
   accepted guest of this host, and the cert verifies.
5. Team members who are other accounts are admitted on the control socket by membership (b1 2),
   but get no link-key trust until they pair (section 4): a direct or WireGuard link is always
   between keys someone accepted.

Onboarding (C10) projects this: `searching` until the first Mac appears, `found` with Macs from
the trust store, `pairing(id)` while the phone publishes its own cert (the "Connect" intent), and
`paired(name)` when the Mac's presence reaches `online` with both certs present.

## 4. QR pairing

### 4.1 Grammar (versioned, short-lived, single-use)

```
cmux://pair/1?o=<offer>&h=<host>&t=<team>&k=<host direct key>&e=<expires>&n=<name>
https://cmux.com/app/pair/1?…        (same query; C16 hands both to B6)
```

| Field | Format | Meaning |
| --- | --- | --- |
| path `pair/<v>` | `1` | grammar version; another value is `unsupportedVersion` (the app shows "update cmux") |
| `o` | 26 Crockford base32 chars (130 bits, top 2 bits zero) | offer code: names the PairingDO, unguessable |
| `h` | `host_…` / `h_…` | host id |
| `t` | `team_…` | the host's team (HostDO admission asks this TeamDO) |
| `k` | base64url, 43 chars (32 bytes) | the host's `direct` X25519 key: the claim binds it |
| `e` | unix seconds | expiry (at most 5 minutes after the offer) |
| `n` | percent-encoded, 1 to 64 chars | display name, untrusted: the confirm sheet shows the name the server returns |

Unknown query keys are ignored (additive within v1); a missing or malformed required key is a
parse error. The bundle scheme `cmux-ios-<bundle id>://pair/1?…` is accepted like `cmux://`.

`cmux://attach/1?h=<host>&t=<team>` opens a host the account already trusts (no secret); when the
host is not in the trust store the app explains that the Mac must show a pairing code.

### 4.2 Flow

1. Mac (host install, not an agent): `pairing.offer {host, team}` on `/v1/wire/user` → UserDO checks
   role `host` with TeamDO and that its `direct` cert is published, mints the code, stores the offer
   in `PairingDO` (host, team, owner user, host install, the host cert, `expires_at`). Result:
   `{offer, expires_at, link}`; the Mac renders `link` as the QR code.
2. Phone scans → `PairingLink` parses → `pairing.claim {offer, host, host_key}` on its own
   `/v1/wire/user`. UserDO sends PairingDO the claimant (user, install, name, platform, its own
   published `direct` cert). PairingDO refuses an unknown or expired offer, a host or `host_key`
   that differs from the offer (QR binding), and any second claimant (single use).
3. Same account (claimant user = host owner): the offer is consumed; the result is
   `{status: "trusted", host, host_cert, host_jwk}`. Nothing else is written: own devices are
   already trusted (section 3).
4. Another account: PairingDO marks the offer `claimed`; the owner's UserDO commits
   `trust.request.add` (claimant user and display name, device name, platform, key fingerprint,
   expiry). The phone gets `{status: "pending"}` and waits on its `trust:` stream (no polling).
5. Owner accepts on the Mac or any signed-in device of the owner (never an agent):
   `trust.request.accept {offer_id}` → PairingDO `complete` (single use) → TeamDO `host.guest.set`
   (admission) → owner `trust.guest.add` (key trust, request removed) → guest's UserDO
   `trust.remote.add` (index with the host cert). Each step is keyed by the offer, so a retry
   finishes a partial acceptance. `trust.request.decline` removes the request and spends the offer.
6. The phone sees `remote[host]` appear; it pins the host's key from that entry.

Expired requests are dropped on the owner's next trust write and refused by accept.

## 5. Revoke and the multi-Mac list

- Own device: `install.revoke {install}` (existing op on `user:`): UserDO revokes install and grant,
  closes its sockets (4401), and drops its certs from `trust:` in the same turn. Every Mac's
  authorizer stops accepting its key on the next event.
- Guest on my host: `pairing.revoke {host, install}` by the owner, or by the guest for itself.
  UserDO removes `guests[host/install]` (owner) or `remote[host]` (guest), then tells TeamDO
  (`host.guest.remove`: the next admission check closes the guest's host socket with 4403) and the
  other user's UserDO. Keyed by `revoke:<host>:<install>`.
- Multi-Mac list: `DeviceRegistry.updates()` yields own Macs (trusted), remote Macs (trusted),
  this phone, other own phones, guests on my Macs, plus pending requests as `discovered`, each
  with presence-derived `lastSeen`. Order is the owner's (sorted by name, then id); C5 owns hidden
  Macs and custom order.

## 6. Wire (additions to the a0 pairing family)

On `/v1/wire/user` (UserDO). `trust:<user>` is a UserDO secondary stream like `ssh:`.

| Message | Kind | Params → result |
| --- | --- | --- |
| `trust.key.publish` | op (install) | `{cert: LinkCertificate, host?}` → `{install, purpose}` |
| `pairing.offer` | op (host install) | `{host, team}` → `{offer, offer_id, expires_at, link}` |
| `pairing.claim` | op (install) | `{offer, host, host_key}` → `{status: trusted\|pending, offer_id, host, team, name, owner_user, host_install, host_jwk, host_cert}` |
| `trust.request.accept` / `.decline` | op (owner session or install) | `{offer_id}` → `{host, install}` / `{offer_id}` |
| `pairing.revoke` | op | `{host, install}` → `{host, install}` |
| `pairing.hosts` | read | `{}` → own and remote hosts with trust |
| `trust.*` events | owner | `trust.key.set`, `trust.install.revoked`, `trust.request.add/remove`, `trust.guest.add/remove`, `trust.remote.add/remove` |

Snapshot state of `trust:<user>`: `{devices, guests, requests, remote}` (maps; at most 64 devices,
256 guests, 32 requests, 256 remote hosts). No private key, token or offer code is ever in it
(requests carry only an `offer_id` = SHA-256 of the code, base64url, so a subscriber cannot claim).

## 7. Client APIs (Swift)

`Packages/Shared/CmuxPairing` (Foundation, CryptoKit, CmuxControlPlane, CmuxMobileWire, CmuxLinkDirect):

```swift
public struct LinkCertificate: Codable, Hashable { purpose, user, install, key, issuedAt, expiresAt, signature
    func signedMessage(environment:) -> Data; func verify(publicKey: P256.Signing.PublicKey, environment:) throws }
public protocol LinkKeySigning: Sendable { func sign(_ message: Data) async throws -> Data }   // the SE install key
public struct LinkCertificateIssuer { func issue(purpose:key:user:install:environment:now:) async throws -> LinkCertificate }
public struct PairingLink: Hashable { enum Kind { pair(offer:host:team:hostKey:expires:name:), attach(host:team:) }
    init(url: URL) throws(PairingLinkError); var url: URL }
public struct TrustStoreState: Hashable, Sendable { devices, guests, requests, remote; apply(event:) }
public actor TrustStoreMirror { updates(); state; start(client:user:) }      // over ControlPlaneClient trust:<user>
public protocol TrustedKeyLookup: Sendable {
    func hostKey(for host: String) async -> TrustedHostKey?                         // B4 resolver pin, C9 HostsStore
    func isTrustedDevice(directKey: Data, onHost host: String?) async -> Bool         // B4 DirectAuthorizer (B5 on the Mac)
    func verifyFingerprint(_ cert: LinkCertificate, from install: String) async -> Bool // B2 DTLS check
}
public struct TrustStoreAuthorizer: DirectAuthorizer   // TrustedKeyLookup → B4's hook
public struct PairingClient { offer, claim, accept, decline, revoke, publish }   // ops over ControlPlaneClient
```

iOS: `CmuxiOSPairingCore` (`ControlPlaneDeviceRegistry: DeviceRegistry`, `PairingTicket` codec,
`PairingLinkHandler` for C16's `.pairing(URL)`), `CmuxiOSPairing` (`QRScannerView`, AVFoundation
`AVCaptureMetadataOutput` for `.qr`, replacing C10's placeholder in `CameraSheet`).

## 8. Tests

- vitest (`backend/apps/api/test`): `trust-domain.test.ts` (reducer: publish, rotate, revoke, limits,
  request expiry, guest/remote, redaction of codes), `pairing-offer.test.ts` (offer, claim binding,
  single use, expiry, same-account trusted, cross-account pending → accept → guest admission,
  decline, revoke closes admission, signature and freshness refusals).
- Swift Testing (`Packages/Shared/CmuxPairing`): link grammar (round trip, versions, bad fields,
  expiry, https and bundle schemes), certificate chain (sign with a P-256 key, verify, wrong
  environment, tamper, expiry, lifetime cap, cross-check vector with the TS message), trust mirror
  (snapshot, events in order, revoke removes keys, lookup answers). `CmuxiOSPairingCore`: registry
  projection of the mirror and receipts.

## 9. Open

- Guest cert rotation: a guest's new `direct` cert reaches the host owner only through re-pairing;
  a `trust.remote` → owner push lands with B5 (TeamDO-free, UserDO to UserDO RPC, keyed by cert).
- A guest install revoked by its own account stays in the owner's `guests` until the owner revokes
  or the cert expires (90 days); socket admission is already refused by the guest's UserDO
  (registerSocket). The ssh KRL notice path (`ssh_revoke_pending`) can carry it to the owner later.
- Narrowing control-socket admission from "team member" to "paired device" (b1 open item) is not
  done: team members keep control access, and link keys need pairing.
- WireGuard (`wg`) certs are recorded and verified; TeamDO's `network.device.join` (transport.md 8)
  should consume the same cert instead of its own signature when the overlay lands.
