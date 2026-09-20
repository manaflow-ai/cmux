# Cloud startup and Local Network permission (#13070)

Observed on macOS 26.4.1 (25E253), main `6b4fe2303ff5afbde92aca843fd7a75cb3e29166`,
tag `main-20260919-gcp`, 2026-09-19. The app used a private per-tag Next.js
GCP development backend through Tailscale. The VM provider was Freestyle,
not GCP. The running user app, backend, machine and privacy settings were not
changed by this investigation.

## Answer to Austin: what changed?

There are two independent changes in the history, and three costs in this run:

- [#10887](https://github.com/manaflow-ai/cmux/pull/10887), merged 2026-08-27
  (`f7f61ef720`), introduced the Cloud surface/remote-daemon path and both
  device-name helpers that call `ProcessInfo.processInfo.hostName`. Previously
  the CLI used the Go daemon's WebSocket/SSH attach path. Both paths needed
  connection setup; `cmux_remote_info` alone is not evidence of a new handshake.
- [#11602](https://github.com/manaflow-ai/cmux/pull/11602) and
  [#11789](https://github.com/manaflow-ai/cmux/pull/11789), merged September 2
  and 5, added per-account private networks and the shared userspace WireGuard
  carrier. A fresh tag has its own tunnel identity/config and pays first-use
  enrollment. Existing tags normally reuse their saved config.
  [#12042](https://github.com/manaflow-ai/cmux/pull/12042), merged September 6,
  subsequently removed the remote daemon's invitation/approval enrollment from
  the private-carrier path. Current first-use preparation is not that retired
  invitation handshake.
- The Local Network prompt came after tunnel readiness, alongside **56 PTR
  hostname queries from the Mac app process itself**. The Cloud link computes
  a cosmetic device label through `ProcessInfo.hostName`. A runtime probe
  confirms this calls `NSHost.name`, a network-resolving API. The label does not
  need any network information. The fix reads the kernel hostname instead.

The old device-name code is from August, not a newly added September handshake.
A fresh bundle identity has no prior Local Network decision, so a previously
hidden dependency can surface again. The evidence does not establish which
permission state or DNS cache Austin's earlier builds had.

Provenance: the blamed helpers are authored by Austin Wang in `f7f61ef720`;
#10887's PR author and merger are both `@austinywang`. The privacy description
was independently added by Lawrence Chen in [#10901](https://github.com/manaflow-ai/cmux/pull/10901)
(`38b16b0436`, August 27 UTC). The two plist entries and their text describe the
permission; they do not cause network traffic or identify the triggering API.

## Observed phase timings

The CLI's `complete` and `attach_info` clocks start **after** create. They also
include workspace/catalog work. Total create plus attach was **62.357 s**,
not 58.948 s. This measures CLI completion, not the exact first painted prompt.

| Phase | Client time | Server evidence / attribution |
| --- | ---: | --- |
| Create | 3.409 s | HTTP create: about 3.0 s |
| Capability/status request | 4.675 s | 4.1 s, including 3.5 s Next.js cold compilation |
| First attach-endpoint | 8.039 s | 7.1 s, including 5.1 s Next.js cold compilation and 2.0 s application work |
| Tunnel enrollment attempt 1 | 33.460 s | 33.4 s, including 32.3 s application work; Freestyle `/v5/tunnels` returned 503 `INTERNAL_ERROR`, mapped to HTTP 502 |
| Enrollment recovery delay | about 1.215 s | Existing hub startup recovery, not a permission wait |
| Tunnel enrollment attempt 2 | 0.958 s | HTTP 200 in 0.502 s |
| Hub readiness and route probe after enrollment | about 0.17 s | AF_UNIX hub connections; `cloud.link.wireguardHub` at 22:43:22.707Z |
| Device label / link startup | 8.320 s | PTR queries begin 22:43:22.729Z; permission UI starts at 22:43:22.870Z; user action at 22:43:30.867Z; link connected at 22:43:31.027Z |
| Catalog/projection completion after link | about 1.1 s | `surface_new_terminal` aggregate ends at 22:43:32Z |

These are nested/overlapping observations, not rows to sum. A background link
also called attach-endpoint (1.721 s client / 1.666 s server), overlapping the
shared tunnel enrollment. `cmux_remote_info`'s 49.540 s aggregates status,
attach-endpoint, enrollment and route readiness. `surface_new_terminal`'s
9.327 s includes waiting for the link/catalog and projecting an existing terminal;
it does not prove that terminal allocation itself took nine seconds.

The 33-second provider failure was already underway before the prompt appeared.
The prompt cannot explain that server-side failure or the cold Next.js compiler
cost. The source of the provider's internal failure is not present in these logs;
changing retry intervals or exposing a public fallback would not repair it.

## Permission attribution

- `mDNSResponder` records the 56 PTR requests under app PID 96305. They begin
  immediately after `CloudMachineLink.connect` reaches the call to
  `CloudTuiClientPaths.deviceName()`. The `cmux-tui wg hub` child (PID 44605)
  had just resolved its provider endpoint with A/AAAA queries and become ready.
- A process-local Objective-C probe replaces `NSHost.name` with a sentinel.
  Calling `NSProcessInfo.hostName` returns that sentinel. The probe runs with
  networking denied by a subprocess sandbox, so it sends no LAN traffic and
  does not change an OS permission. The executable regression applies the same
  tripwire to the real `vm tui` path; the old CLI forwards the sentinel as its
  device name and fails the assertion.
- No Cloud operation invokes the Iroh Bonjour browser/publisher. Its private
  IPs are carried inside userspace WireGuard through a Unix socket. The
  Tailscale backend requests completed throughout the incident, before the
  prompt. This evidence implicates Foundation's hostname resolution, not
  Bonjour service discovery, the WireGuard child, or private backend routing.
- macOS may attribute a helper's network request to its parent app; the wording
  “A program running within cmux” is static metadata, not proof of child
  attribution. Here the DNS requests identify the app PID directly.

Apple documents that local DNS resolution can require Local Network permission,
that helper access can be attributed to the responsible app, and that VPN
interfaces are not broadcast LANs in
[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
[NSHost](https://developer.apple.com/documentation/foundation/host) explicitly
uses network name/address discovery services. `gethostname` reads local kernel
state and needs neither DNS nor LAN access.

## Fix and proof

`RemoteClientDeviceName` owns the app/CLI derivation and uses `gethostname` with
a bounded buffer. Missing hostnames retain `cmux-mac`. Existing sanitization,
prefix and 40-character limit are preserved. The label may now reflect the
configured local hostname rather than a DNS canonical name; it is not an
authentication key, grant, machine ID or persistent connection identity.

The subprocess regression substitutes an unavailable hostname resolver. Cloud
naming must never call it, so pending/denied name resolution cannot gate the
connection. It tests the actual CLI attach path with an isolated home/socket,
and the app's production naming caller in a small Foundation-only fixture.
Swift Testing separately checks the existing label format and bounds. No
production debug hook, permission bypass, or privacy reset is added.

The fixed app caller's isolated fixture measured **0.082 ms cold / 0.016 ms
warm** on the reporting Mac, with `NSHost.name` intercepted. A separate
sandboxed API probe confirms `NSHost.localizedName` (used for the friendly
enrollment name) does not call that resolver; the problematic API is
`NSProcessInfo.hostName` used to label the daemon connection.

Commands:

```sh
CMUX_CLI_BIN=<built-cli> python3 tests/test_cli_cloud_hostname.py
python3 scripts/swift_file_length_budget.py
```

The regression-only commit `b0b56530a4` fails against the reported main CLI:
`cmux-resolver-must-not-run` instead of the kernel hostname. Hosted baseline CI:
https://github.com/manaflow-ai/cmux/actions/runs/35475513195.

## Independent live transport baseline

`web/scripts/cloud-vm/bench-private-link.ts --trials 2` used the reported app's
bundled cmux-tui client (`cbe279df124f8ba930b0252364dcf293a409d794`) and the current
md image `sh-0b6a5ee6edfd490795e0e5d556f5adf5`, daemon `f3b652d8dcfb`.
It created its own network, tunnel and machines and cleaned them up. The
hostname is supplied explicitly, so there is no Foundation hostname lookup.

| Scope / phase | Cold run | Subsequent run, hub warm |
| --- | ---: | ---: |
| Network creation (once) | 115.4 ms | reused |
| Tunnel enrollment (once) | 98.4 ms | reused |
| Hub readiness (once) | 338.2 ms | reused |
| New VM create → visible shell prompt | 3989.8 ms | 4607.8 ms |
| Reconnect link | 323.5 ms | 79.3 ms |

These are headless transport measurements, **not** a before/after GUI claim.
They exclude Stack auth, the GCP Next.js/DB layer and Mac UI. The provider image
is current at measurement time, not proven identical to the reported VM's image.
The first full sequence including network/tunnel/hub setup is about 4.54 s.

## Dogfood follow-up: prepare the carrier when Cloud is enabled

Austin tested the authenticated local tag at `baa85c9101` against its own GCP
backend on port 4280. He confirmed the permission prompt was gone, but first
creation still felt slow. The new trace separates the remaining cost:

| Phase | Time |
| --- | ---: |
| Create | 2.901 s |
| `cmux_remote_info` | 49.770 s |
| `surface_new_terminal` | 0.824 s |
| Post-create completion | 50.730 s |
| Create plus completion | 53.631 s |

The first tunnel POST again returned 502: 34.8 s total, including 4.0 s of
Next.js compilation and 30.8 s of application/provider work. The provider's
503 was `INTERNAL_ERROR`. A read-only provider query found the resulting tunnel's
`createdAt` was `2026-09-20T00:29:26.628077Z`, about 30 s before the error response
at `00:29:57.210Z`. The retry succeeded in 443 ms. The resource record therefore
existed during the failed request; that timestamp alone does not prove the
data plane was usable then. The account network had 45 tunnel attachments.

Isolated probes created and cleaned up their own networks and tunnels. Fresh
networks enrolled in 150/167 ms from the Mac and 144/194 ms from the GCP backend
using its actual runtime provider credential. Device-name labels did not
reproduce the failure. A further owned-network trial created and prepared a VM
before enrolling its tunnel: enrollment was 114 ms, and the subsequent measured
VM reached a shell in 3.684 s. These results do not reproduce the account
network's delayed provider response and are not a before/after GUI claim.

The app already had a coalesced `CloudWireGuardHub.prewarm()` API, but no
production activation path called it. Fleet discovery now schedules preparation
after a successful authenticated list, including an empty list, while both
Cloud gates permit background work. It returns without awaiting enrollment.
The shared hub owns the preparation task, startup/recovery and one account
claim; the first terminal joins that same startup. Cloud disable/sign-out stop
the hub, cancel preparation and invalidate stale completions. No NetworkExtension
configuration or LAN discovery is involved.

The deliberate resource trade-off is one resident userspace helper and an
enrolled private-network identity for signed-in Cloud users even before they
own a VM. A create immediately after enabling Cloud can still wait for unfinished
preparation; the provider response delay and development-route compilation are
not eliminated. Regression coverage exercises empty-fleet preparation,
nonblocking discovery, startup sharing, disable/sign-out cancellation and
unavailable/signed-out gating. Its separate test-only baseline is
[`bf6742b5de`](https://github.com/manaflow-ai/cmux/actions/runs/35479850124).

The independent workspace-rename CI failure was corrected in `adf2252439`:
the provider's accepted graph retains the old name while the catalog's
presentation snapshot intentionally overlays the pending rename. The test now
checks both rather than expecting the accepted name from the optimistic view.

## Remaining verification limits

The current cloud-mac provisioner has no controller scheduling path and still
uses the retired fleet tooling. No clean Mac was allocated and no OS permission
was clicked/reset. A real fresh-bundle GUI denial/pending experiment remains
unverified; the deterministic proof removes the DNS dependency rather than
simulating the OS privacy database. Independent terminal/browser features can
still legitimately request LAN access.

The repeated 30–33-second provider error and private development route compilation
remain independent performance limits. The changes remove hostname resolution
and move carrier preparation ahead of first machine use; they do not claim to
repair the provider's delayed response.
