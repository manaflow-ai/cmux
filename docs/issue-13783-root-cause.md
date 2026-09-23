# Issue #13783 root cause: a current Mac version is lost during pooled reconnect

## Customer impact

A customer can update the Mac to a supported cmux release and still have the iOS app report that the Mac is too old. The failure is most severe when iOS reuses a background (secondary) Mac connection: that connection has already read the Mac's current authenticated version, but promotion discards the value, substitutes the version from a synthetic ticket, and rejects the Mac as if its version were missing. The same failed attempt also leaves an update-required warning and error behind until a later foreground authentication succeeds.

This matches issue #13783: iOS required Mac 0.64.23 or later, the Mac was updated to 0.64.25, and reconnect still surfaced the old gate.

## Observed flow

1. The Mac answers authenticated `mobile.host.status` with the version of the running app. `MobileHostService.authenticatedStatusPayload` reads `MobileHostBuildIdentity.current()` and emits `mac_app_version` (`Sources/Mobile/MobileHostService.swift:349-354`). iOS decodes that field as `MobileHostStatusResponse.macAppVersion` (`Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileHostStatusResponse.swift:38-41, 83-85`). Updating and reopening the Mac therefore makes 0.64.25 available to a new status request; the Mac does not intentionally persist 0.64.23 as its live status.
2. A normal foreground dial passes the live status version to `authenticatedMacBuildAdmission` (`MobileShellComposite.swift:10488-10504`). `MobileMacCompatPolicy.violation` compares the reported stable or Nightly version with the floor for the current iOS build (`MobileMacCompatPolicy.swift:119-150`). On success, the foreground path stores the live version and clears the pairing's update-required marker (`MobileShellComposite.swift:10505-10510`). The numeric comparison itself admits 0.64.25 against a 0.64.23 floor.
3. Before this fix, a background Mac connection also fetched a live `MobileHostStatusResponse` in `makeSecondaryClient(for:)`, but only identity and capabilities survived into `SecondaryClientHandle` and `SecondaryMacSubscription`; `status.macAppVersion` was discarded.
4. Promotion then assigned `authenticatedMacAppVersion` from the attach ticket. Stored reconnects use `storedMacTicket`, a synthetic ticket with no `macAppVersion`, so the promoted version became `nil` even if the status request had just returned 0.64.25.
5. Promotion marks the connection connected and immediately calls `revalidateActiveMacCompatibilityPolicy()` (`MobileShellComposite+SecondaryPromotion.swift:759-768`). A missing stable version fails closed under an active floor (`MobileMacVersionCompatibility.swift:62-72`), so revalidation records the pairing as update-required, disconnects the valid live client, and surfaces the version error (`MobileShellComposite+BuildCompatibility.swift:49-77`).
6. Separately, a rejected foreground attempt inserted the pairing ID into `macVersionUpdateRequiredPairingIDs`. The only positive clearing edge was a successful foreground status path. A successful secondary authentication could therefore have current evidence without clearing the old marker.
7. The row warning is the OR of the sticky gate marker and current directory compatibility (`MacComputerRow.swift:169-182`). Therefore a fresh directory entry showing 0.64.25 can become compatible while the old marker keeps “Mac update required” visible. Stored reconnect also begins without clearing the prior `connectionError`/`connectionErrorGuidance`; only a later successful foreground adoption clears it (`MobileShellComposite.swift:10729-10734`). A new attempt can consequently display the previous gate while it is retrying or if it fails for a different reason.

## Root cause

There are two related state-lifecycle defects.

The connection blocker is loss of authenticated version provenance across the secondary-client pipeline:

```text
live mobile.host.status (0.64.25)
    -> SecondaryClientHandle (version omitted)
    -> SecondaryMacSubscription (version omitted)
    -> promotion reads synthetic ticket version (nil)
    -> policy revalidation treats nil as outdated
    -> disconnect + "update required"
```

The supporting stale-UI defect is that version-gate failure state has only one positive clearing edge: a successful foreground host-status admission. It is not reconciled when an exact, fresh, unambiguous account-directory entry reports that the same Mac app instance now satisfies the same policy, and a stored reconnect does not reset the prior error before collecting new evidence.

These defects are not caused by the version comparator or by the Mac continuing to report its old installed version. The foreground path consumes the current status correctly. The stale result appears because the pooled path replaces current authenticated evidence with a versionless ticket, while the UI retains the earlier negative evidence.

## Why updating the Mac did not clear the gate

The update changed the Mac's live `mobile.host.status` and its next control-plane hello. Neither transition is sufficient in the affected iOS paths:

- The secondary connection reads the updated live version but does not retain it through promotion. Revalidation sees `nil`, not 0.64.25, and fails closed.
- The control-plane directory can publish a fresh 0.64.25 entry, but `macVersionUpdateRequiredPairingIDs` is independent state and is not reconciled from that entry.
- A stored reconnect retains the previous error until a foreground connection reaches its success block. If promotion rejects the versionless synthetic ticket first, that success block never runs.

The fail-closed behavior for missing or malformed versions is correct. The bug is that iOS creates a missing version after it already obtained a valid authenticated one.

## Implemented fix

1. Authenticated version provenance now travels with `SecondaryClientHandle`, `SecondaryMacSubscription`, and `MacConnection`. Secondary publication, promotion, warm Iroh focus, and foreground-to-control demotion retain the version that the live host-status response proved; synthetic ticket metadata is no longer substituted for it.
2. Secondary clients now run the same build admission immediately after authenticated identity validation. Missing, malformed, and older live versions still fail closed before entering the pool. Promotion also revalidates the retained value in case policy became stricter while the connection was pooled.
3. Every successful live authentication records a per-pairing version overlay in `MobileMacListAuthState` and clears that pairing's sticky update-required marker. The overlay is deliberately based on authenticated host status, not directory metadata, so cached or ambiguous directory facts cannot bypass live admission. It is cleared at the account boundary.
4. Authoritative stored reconnect attempts clear the previous pairing error before dialing, so a new attempt does not continue presenting the previous process's version failure while collecting current evidence.

## Regression coverage

The patch adds behavioral package coverage for the two state-transfer seams that caused the report:

- `MobileSecondaryInstanceAuthorityTests.promotionTransfersAuthenticatedIdentityFromSecondaryClient` promotes a versionless synthetic ticket whose secondary subscription carries authenticated Mac 0.64.25 under the 0.64.23 Internal floor. It asserts the shell remains connected and that 0.64.25 survives both promotion and future demotion.
- `MobileMacConnectionPoolTests.tailscaleOnlySecondaryMacStillConnectsOverAuthorizedRoute` now asserts that the live 0.64.25 status value enters `SecondaryClientHandle` rather than disappearing at the first pipeline boundary.
- `MobileMacListAuthStateTests.authenticatedVersionOverridesStaleDirectoryVersion` starts with cached 0.64.22 directory metadata, records authenticated 0.64.25 for the same pairing, and asserts the presented compatibility state is current.

Existing compatibility-policy tests continue to cover fail-closed behavior for older, missing, and malformed versions.

The tests should use Swift Testing and runtime behavior, not source-text assertions. Package tests avoid the direct `cmuxTests` project-wiring hazard; if any regression is added directly under `cmuxTests/`, run `./scripts/sync-test-wiring` and build the `cmux-unit` scheme as required by `skills/cmux-testing/SKILL.md`.

## Verification gaps

- This analysis is source-trace evidence, not a physical-iPhone reproduction from the reporter's saved pairing. No customer logs were attached, so it is not yet proven whether the failing attempt used pooled promotion, foreground stored reconnect, or both.
- The focused Swift package test command was attempted, but this host only has Command Line Tools while the repository pins Xcode 26.0. Its PackageDescription API does not provide `swiftLanguageMode(.v6)`, so the manifest cannot compile here. The failure occurs before source compilation or test execution.
- The affected change touches mobile connectivity and lifecycle. Before release, run the focused package regressions with Xcode 26, compile the iOS targets, install the authenticated build on both an isolated Simulator and a physical iPhone, and execute the new Mac-version-boundary recovery scenario in `docs/ios-connectivity-soak.md`. That scenario is specified but has not been run here.
- The soak does not establish suspended-app recovery, cellular handoff, or physical-device reliability. Record those as separate dogfood evidence rather than inferring them from simulator transport success.
