# V2 inbound admission verification

The shared Mac admission authority accepts only explicit `directory.inboundPeers` permissions for the requesting Mac's team, environment and Stack project. The ordinary outbound computers list grants no inbound access. The IROH connection's authenticated public key must match the permission, and the returned admission receipt includes the record ID, device ID, build tag and identity generation.

`V2InboundAdmissionAuthority` owns the complete current permission map under one lock. `judgment()` provides the synchronous admission check; `recheck(_:)` checks the exact receipt again before registry insertion. `invalidate()` permanently stops that authority before account, team or installation teardown. The fixed host descriptor also prevents an observation for another local key or generation from silently changing the owner.

`restore(_:)` installs one v2 cache before the service starts. The service's initial empty publication preserves restored permission, while later empty snapshots clear it. Complete snapshots replace the map. Sequence, revision and issuance checks reject stale observations; identical snapshots retain their original expiry. Partial directories, duplicate keys or tuples, wrong cache formats, and known revocations cannot establish authority. Revoked records remain denied for this owner's lifetime.

The earlier of each peer's expiry and the directory expiry becomes a monotonic deadline. A wall-clock rollback cannot extend it. `nextExpiration` gives the Mac runtime one next deadline for closing expired sessions; no backend heartbeat or expiry timer is introduced. Admission lookup is constant time, and snapshot work is bounded to 4,096 inbound peers.

The actual `CmuxIrxTransport` package compiled remotely with the latest `V2ControlService.start` cancellation guard. All 30 focused tests in six suites passed, including 12 inbound-authority tests, canonical signing fixtures, control recovery and two real direct-only QUIC tests. All 72 package source and fixture hashes match the local workspace. Commands, compiler, base revision and limits are recorded in `verification.json`; complete output is in `shared-tests.log`.

This verifies the shared authority and control package. Full Mac application integration and live Mac/iOS backend acceptance remain with the parent task. The fleet lease remains available for those checks.
