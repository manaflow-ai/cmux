# Cloud carrier

Leo, 2026-11-06:

> Wait, but isn't this kind of stupid? Like, still? How do you PROPERLY do this?

> Like there's obviously one clear and obvious design. [...] just, yeah, just throw away the bullshit.
> [...] Like be willing to rewrite, rework, remove, cut, cut, cut.

NEXT reaches a Cloud machine one way: an end-to-end Noise session between the device (a Mac or a phone)
and the machine's session daemon, through a relay that only forwards bytes. Chat, files, secrets and
auth all go over it. Nothing else reaches the machine.

## How it works

1. **The machine connects out.** At boot, the session host (`cmux-host`) asks cmux-platform for a
   Register ticket with its install token (`POST /v1/cloud/machines/{id}/carrier`). It then registers its
   daemon on the machine's slot in the relay (`cmux-tui/relays/cloudflare-do`). That Register is the
   readiness event, and nobody polls for it. After a pause, the machine registers again on resume.
2. **The device connects out.** The device asks the same route for a Connect ticket and a carrier grant,
   then connects to the slot. If the machine isn't registered yet, the slot holds the connect (`Parked`)
   and pairs the two as soon as the machine registers. A client says it understands `Parked` in its
   Connect; an older client is never sent the frame, since an unknown control frame ends its connection. If the machine is paused, the route starts it.
3. **One Noise session, end to end.** The two sides run `Noise_XX_25519_ChaChaPoly_BLAKE2s` (the `snow`
   library, `cmux-remote/src/crypto.rs`).
   - The device pins the daemon's static key from the machine record.
   - The daemon admits the device on a carrier grant: an Ed25519 JWS (`cmux-carrier+jwt`) that names the
     machine, the team, the person, the services and the SHA-256 of the device's Noise key. The daemon
     verifies it locally against the platform keyset. It refuses the grant unless all of these hold:
     - `aud` is the daemon's own bound machine id and `team` is its team, so a grant for one machine
       can't open another;
     - `nk` matches the key that just finished the handshake;
     - its `jti` hasn't been seen.
   - Every connect and every reconnect fetches a fresh grant. When the platform can't mint one, a session
     that is already up resumes on its resume lease, because resume needs no grant. A new session waits,
     with backoff, until the connect deadline.
   - The relay only ever sees ciphertext.
4. **Everything rides the session** as cmux-remote services:
   - chat and terminals on `MuxControl`;
   - files and folder copy on `WorkspaceRpc` and the `Bulk` lane;
   - SSH on `TcpTunnel`.
5. **Secrets are sealed to the machine.** The device seals each secret, and each harness login, to the
   daemon's static X25519 key with HPKE (RFC 9180, `DHKEM(X25519)`/`HKDF-SHA256`/`ChaCha20Poly1305`, the
   `hpke` crate). Only the machine can open them. They ride the session as a `secrets-v1` request, and
   the machine writes them to a 0600 file. A sealed secret can also wait on the platform for a machine
   the device isn't connected to, and the platform still can't read it.
6. **One deadline.** A connect gets 180 s from send, with full-jitter reconnect inside it. When it fails,
   the error names the step it didn't get past. Once up, the session's resume lease carries it across a
   network change or a pause.

## What was deleted

These are NEXT paths only. Classic `web/` and `/api` are untouched.

- **The plaintext chat relay:** `MachineRelay` and `/chat` in cmux-platform, `cmux-host/src/cloud/relay.rs`,
  `CloudRelayChat.swift` and `CloudStartSession+RelayChat.swift`.
- **The login copy over Freestyle exec,** the terminal-typing secrets receiver, and `machine-io`'s part in
  both.
- **The native link and its fallback:** the nested WireGuard route (`link/native_*`, `link/mesh_cloud.rs`,
  the Cloud mesh in `cmux-wg`, including the 1 s handshake resend), the per-device mesh access list,
  `CloudNativeFirstLauncher`, and the plain `cmux link` route.
- **The waits the old paths needed:** `ConnectWait.ts`, the receiver's policy reads, and the 180 s link
  wait with its redial loop.

## Where the pieces are

| Piece | Code |
|---|---|
| Relay slot and circuit | `cmux-tui/relays/cloudflare-do` |
| Tickets, grants, slot ids, relay deploy | cmux-platform `src/server/cloud/Carrier*.ts`, `.github/workflows/carrier-relay.yml` |
| Session, lanes, resume | `cmux-tui/crates/cmux-remote` |
| Grant check on the machine | `cmux-remote` (the `Grant` client auth mode) and `cmux-link` (the keyset) |
| Device side | `cmux carrier dial --machine <id>`, the stdio bridge the Cloud app server spawns (`first-party-apps/cloud/server/src/link/dial.rs`) |

## Proof

The start matrix (`cmuxterm-hq` `goals/cloud-start-matrix.md`) has a carrier row that runs create, then
the first reply, then a pause and resume, then a second reply. It fails if any step used a route other
than the carrier.
