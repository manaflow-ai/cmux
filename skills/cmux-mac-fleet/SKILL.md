---
name: cmux-mac-fleet
description: "Maintainer-only rules for the shared cmux Mac fleet: leasing general-purpose slots for builds, archives, tests, and remote agent verification. Requires a cmuxterm-hq checkout. Use when a build or verification should run on the fleet instead of the local Mac. Contributors without fleet access build and verify locally and do not need this skill."
---

# cmux Mac Fleet

This applies to maintainers working from a `cmuxterm-hq` checkout. Without one, none of the tooling below exists; build with `./scripts/reload.sh --tag <tag>` and verify locally.

## Shared Mac fleet capacity

Every healthy slot in the canonical Mac fleet is general-purpose. Builds, iOS archives, tests, profiling, simulator and UI verification, and any other resource-intensive workload may use any available slot. Do not wait for an AWS-only builder or infer capacity from a workload label. Use the shared lease state and slot-isolated paths supplied by the fleet tooling.

## All fleet slots are general-purpose

Agent verification, macOS/iOS builds, archives, tests, profiling, and any other work too resource-intensive for the local Mac use the same Mac fleet. A slot is not a "build slot" or a "verify slot". From the cmuxterm-hq checkout that owns this worktree, every workload leases the canonical `~/.config/macfleet/hosts.json` inventory and shared `maclease` state.

Before waiting for a builder, run `scripts/macfleet-doctor.sh report --probe` from that hq checkout. If it reports `needs-sync`, run `scripts/macfleet-doctor.sh sync --apply`; it backs up the canonical manifest and merges legacy `hosts-verify.json` entries by SSH endpoint. Refresh the hq checkout before diagnosing capacity. Do not infer capacity from a stale checkout, one pool tag, or a remembered host list.

Agent verification runs on the fleet, not on the local Mac. `scripts/verify-remote.sh` leases a general-purpose slot, pushes the tagged build to the leased Mac, drives it there (per-lease uniquely named simulator for iOS; console launch with debug-socket and computer-use evidence for macOS), and fetches screenshots, recordings, and logs back into the hq `artifacts/verify-remote/` directory:

```bash
scripts/verify-remote.sh ios --tag <tag>
scripts/verify-remote.sh mac --tag <tag>
scripts/verify-remote.sh capacity             # all-purpose slots
```

Boot a local simulator only when all-purpose `capacity` reports no free slot, and keep at most 3 local sims booted. Scripted XCUITests go through the hosted `test-e2e.yml` lane when appropriate. The physical-iPhone signing/install leg stays local via the install queue; its archive build may use any healthy fleet slot. Verify leases carry a description and TTL, so a crashed agent frees its slot automatically; see `skills/infra/macfleet/references/verify-remote.md` in cmuxterm-hq for the shared-pool contract and host onboarding.
