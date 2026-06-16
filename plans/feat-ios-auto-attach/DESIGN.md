# iOS registry-driven auto-attach

## Goal

A signed-in phone auto-connects to its team's online Mac with no QR scan or manual host entry. The onboarding becomes "sign in → connected" whenever the team has exactly one reachable Mac, with the existing pair screen as the fallback.

## The gap

Today, a fresh install (or a re-install with no SQLite paired-Mac row) lands on the pair/QR screen after sign-in. `reconnectStoredMacIfNeeded()` only reconnects when `MobilePairedMacStore` already has an active row, which only exists after a prior QR/manual pairing. The device registry (`GET /api/devices`, team-scoped) already knows every Mac the signed-in user's team owns and their current attach routes, but nothing consults it on the cold-start path. So a brand-new phone with a perfectly reachable team Mac still dead-ends on "scan a QR".

## KEY FINDING: can the phone mint from a registry route without prior QR pairing?

**YES.** Confirmed in code. The attach ticket is route-discovery + workspace-selection only; it carries no authorization secret. The Mac authorizes the mobile data plane *solely* on same-Stack-account matching, not on any pairing record.

- `Sources/Mobile/MobileHostService.swift` `MobileHostAuthorizationPolicy.authorizeStackUser(localUserID:remoteUserID:)`:
  ```swift
  guard localUserID == remoteUserID else {
      throw MobileHostAuthorizationError.accountMismatch
  }
  ```
- `mobile.attach_ticket.create` requires authorization (`requiresAuthorization` returns true for everything except the unauthenticated `mobile.host.status` probe), and authorization is the same-account Stack check above. No pairing secret is consulted.
- `Sources/Mobile/MobileAttachTicketStore.swift` `createTicket(workspaceID:terminalID:routes:ttl:)` mints from routes + a freshly generated bearer token; it needs no prior pairing.
- `CmxAttachTicketInput.decode(_:)` only parses a *scanned/pasted* QR/URL. The `mobile.attach_ticket.create` RPC path bypasses it entirely.
- Tests prove it: `cmuxTests/MobileHostAuthorizationTests.swift` `testStackUserAuthorizationRequiresMatchingUser` (matching user passes, mismatch throws) and `testMobileAttachTicketCreateRequiresAuthorization`.

Consequence for this feature: the existing `connectToRegistryInstance(device:instance:)` already does the full thing — pick the best route, `connectManualHost` (which mints the ticket Stack-authenticated on the Mac), then persist into `MobilePairedMacStore`. Auto-attach is therefore *target selection + reuse of that connect path*, not a new connect path. The same-account guarantee means we can never connect to a different-account Mac: the registry is team-scoped by the Stack token, and even a stray cross-account route would be rejected at mint by `account_mismatch`.

## Design

### Feature flag

`MobileAutoAttachFlag` — a tiny value type read from `UserDefaults` with a `#if DEBUG` default of `true`, Release default `false`. Key `cmux.mobile.autoAttach.enabled`. There is no existing iOS settings/flag package, and a full `CmuxSettings`/`DefaultsKey` import into the mobile shell would pull macOS-only catalog machinery, so this is a minimal injected struct on `MobileShellComposite` (`autoAttachEnabled: Bool`), defaulted from the flag at the composition root. Injecting the bool keeps the composite testable without UserDefaults.

### Target selection (pure function)

`MobileAutoAttachTargetSelector.selectTarget(devices:presenceOnline:now:)` → `(RegistryDevice, RegistryAppInstance)?`. Pure, no I/O, fully unit-testable.

Rules:
1. Consider only `device.isControllableHost` devices that have at least one instance with `hasRoutes` and at least one route whose kind is supported (route-priority via the existing `firstReconnectHostPortRoute`). For each candidate device, pick its best instance = the one whose best route sorts first (lowest `route.priority`, id tiebreak); among a device's instances prefer the most-recently-seen instance that has a usable route.
2. Partition candidates into **online** (deviceId ∈ `presenceOnline`) and **the rest**.
   - If presence info is available and exactly one device is online → pick it.
   - If presence info is available and multiple devices are online → **ambiguous**, return `nil` (fall through to pair screen; never guess between two live Macs).
   - If presence info is available and zero are online → fall to recency rule below (a recently-active Mac may still be reachable; the connect attempt is bounded and rolls back on failure).
   - If presence info is unavailable (presence service not present — it is NOT merged yet, #5792) → recency rule over all candidates.
3. Recency rule: if exactly one candidate exists → pick it. If multiple → pick the single most-recently-seen **only if** it is strictly more recent than the next (no tie); on a tie, return `nil` (ambiguous). This keeps "one obvious Mac" auto-attaching while never silently choosing between equally-stale Macs.

Presence is passed as a `Set<String>` of online deviceIds plus a `Bool presenceAvailable`. Because PresenceClient (#5792) is not in this worktree, the composite passes `presenceAvailable: false` for now; the selector already handles the recency-only path, and wiring presence later is a one-line change at the call site. This is called out as residual work, not a blocker — single-Mac teams (the overwhelming onboarding case) auto-attach correctly on recency alone.

### Orchestration on the composite (final concurrency model)

Auto-attach is strictly the *no prior pairing* path: it chains from the no-stored-Mac branch of `reconnectActiveMacIfAvailable`. If a stored Mac exists, the normal reconnect owns it and auto-attach never runs.

Three methods, with a clean per-attempt ownership model (a boolean proved insufficient across sign-out/account-switch boundaries):

- `runAutoAttachOwningRestoringGate(stackUserID:)` — the gate-owning wrapper. Claims a per-attempt `autoAttachGeneration` (`beginAutoAttachGeneration`), holds `isReconnectingStoredMac`/`autoAttachOwnsRestoringGate`, starts a bounded restoring deadline keyed on the generation, runs the flow, then resolves the gate keyed on still owning the generation. It is the authoritative determiner for the no-stored-Mac path, so it clears `hasKnownPairedMac` itself on a miss (not via the caller's stored-mac-generation-guarded write, which a concurrent trigger could supersede).
- `attemptAutoAttachIfEligible(stackUserID:)` — public/test entry that does not own the gate. Dedupes via `autoAttachInFlight` (returns false immediately if an attempt is running), then runs the shared flow.
- `performAutoAttach(stackUserID:generation:)` — the shared flow. Decides from a **freshly-confirmed `.ok`** registry list (`deviceRegistry.listDevices()` directly, NOT the store-wide cache, which `loadRegistryDevices` keeps on transient failure), so a registry outage degrades to manual. After every await it re-checks `stillCurrent()` = same generation + signed-in + disconnected + same account, so a stale task can never resume under a different account or a newer attempt. On a candidate, calls `connectToRegistryInstance(..., rejectLoopback: isPhysicalDevice, supersedeAutoAttach: false)`.

Cancellation / supersession (the hard part, resolved with explicit per-call intent + generation, never shared mutable markers):

- `cancelAutoAttach()` bumps `autoAttachGeneration`, clears the running marker, and resolves the gate if a gate-owning attempt held it. Called on sign-out (BEFORE the gate-flag resets, so sign-out's resets are final) and via `supersedeInFlightAutoAttach`.
- `supersedeInFlightAutoAttach()` (user-initiated pairings only) additionally invalidates the pairing attempt AND bumps `connectionGeneration` + cancels remote work when an attempt is in flight, so an auto-attach already inside its own `connect()` (which installs the client guarded by `connectionGeneration`) discards its result instead of landing over the user's explicit pairing.
- Every user-initiated pairing entry point supersedes auto-attach BEFORE its own early-returns: `connectManualHost` (top, before validation), `connectPairingURLResult`/`beginPairingAttempt`, and `connectToRegistryInstance` (top, before the no-route guard). Auto-attach's OWN connect passes `supersedeAutoAttach: false` (an explicit per-call parameter on the stack, not a shared flag), so it never cancels itself while a concurrent user pairing on its own call still supersedes it.

Loopback safety (physical device): `selectTarget(rejectLoopback:)` and `firstReachableHostPort(rejectLoopback:)` skip loopback routes, and `connectToRegistryInstance` strips loopback from the routes it persists into `MobilePairedMacStore`, so the next stored-Mac reconnect can never pick a `127.0.0.1` route that names the phone itself. The simulator (where `127.0.0.1` IS the host Mac) keeps loopback.

### Lifecycle wiring (root view)

In `Packages/CmuxMobileShellUI/.../CMUXMobileRootView.swift`, where `reconnectStoredMacIfNeeded()` is called (`.onAppear`, `.onChange(of: isAuthenticated)`, foreground), after the stored-mac reconnect resolves to "no known paired Mac", trigger auto-attach. Concretely: extend `reconnectActiveMacIfAvailable` so that when it finds no stored Mac (the `guard let mac = saved else` branch) AND auto-attach is enabled AND not connected, it chains into `attemptAutoAttachIfEligible`. This keeps a single entrypoint and one generation counter, so foreground/sign-in re-entries can't double-connect. The root scene's existing `RestoringSessionView` gate (`isReconnectingStoredMac` / `hasKnownPairedMac`) covers the auto-attach attempt window too, so the user sees "Restoring session…" briefly instead of a QR flash, then either the workspaces (success) or the pair screen (no candidate / failure).

### Multi-Mac / ambiguity / outage

- Multiple online Macs → ambiguous → pair screen (user picks in the device tree).
- Zero candidates / registry down / not signed in → pair screen.
- Different-account Mac → impossible to connect (same-account mint check); and the registry is team-scoped so it won't even appear.
- Bounded: one attempt per generation, cancellable, reuses the 6s restoring deadline. Registry/presence outage degrades to manual.

## Tests (behavior, via injected seams)

Pure selector tests in `CmuxMobileShellModel` (or shell tests):
- online-preferred: one online + one more-recently-seen offline → picks online.
- single candidate (recency, presence unavailable) → picks it.
- no candidate (no devices / no routes / no supported kind) → nil.
- ambiguous: two online → nil; two equally-recent (no presence) → nil.
- same-account is structural (registry team-scoped) — covered by existing `MobileHostAuthorizationTests`; selector never emits a cross-account target because it only sees team devices.

Composite behavior tests (in-memory registry + paired-mac store doubles + scripted transport like the liveness tests):
- eligible + single candidate → connects, persists active paired Mac, second invocation is a no-op (stored path owns it).
- no candidate → returns false, no persistence, falls through.
- one attempt per generation: two rapid calls in the same generation → one connect.
- flag off → never attempts.
- not signed in / already connected / has stored Mac → never attempts.

## Localization

Auto-attach adds no new user-facing strings — it reuses the existing connect path and the `RestoringSessionView` copy. If a "Connecting to <Mac>…" status string is added, it gets en+ja entries in `Resources/Localizable.xcstrings`. Localization audit in the handoff will state this explicitly.

## Files

- New: `Packages/CmuxMobileShellModel/.../MobileAutoAttachTargetSelector.swift` (pure selector) + `MobileAutoAttachFlag.swift`.
- Edit: `Packages/CmuxMobileShell/.../MobileShellComposite.swift` (flag field, `attemptAutoAttachIfEligible`, chain from reconnect).
- Edit: `Packages/CmuxMobileShellUI/.../CMUXMobileRootView.swift` only if a separate trigger is needed; preferred is chaining inside the composite so the root view is unchanged.
- New tests under `Packages/CmuxMobileShellModel/Tests` and `Packages/CmuxMobileShell/Tests`.
