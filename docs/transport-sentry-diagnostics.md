# Transport Sentry diagnostics

Every iroh/transport failure a user can hit is diagnosable from Sentry alone,
on both macOS (host) and iOS (client). The pipeline turns the existing
`DiagnosticLog` ring (`Packages/Shared/CMUXMobileCore`) into three Sentry
surfaces without adding any new PII egress: the ring's vocabulary is fixed
integer codes (`DiagnosticEventCode`, `DiagnosticFailureKind`, ...), so the
bridge ships decoded case names and integers, never error strings, peers,
addresses, accounts, or terminal content.

## Pipeline

`DiagnosticLog.setEventTap(_:)` delivers each retained event (on the ring's
drain task) to a `TransportSentryReporter`
(`Packages/Shared/CmuxSentryTelemetry`, target `CmuxSentryReporting`), which
emits:

1. **Breadcrumbs** — every transport event, category `transport`, decoded via
   `DiagnosticEventPresentation`. These ride on ALL Sentry events, including
   crashes and hangs, so any report carries the recent connection timeline.
2. **Structured logs** — the same decoded events as searchable Sentry logs
   (`options.enableLogs`), rate-limited by a sliding hourly budget so retry
   storms cannot flood the quota.
3. **Error events** — failures that cross `TransportIncidentPolicy`
   (`CMUXMobileCore`, pure and unit-tested) become Sentry events fingerprinted
   by `code/failureKind/transportKind` signature, with the compact diagnostic
   ring export attached (`cmux-transport-diag.txt`, the same `cmuxdiag v1`
   blob the `iroh_diag` socket verb and iOS Settings export produce).

The policy suppresses what an operator can already attribute (cancelled or
superseded dials, offline failures while reachability reports no network,
idle timeouts while backgrounded), coalesces repeats behind a 10-minute
per-signature cooldown, caps failure captures per hour, and escalates a
sustained no-success failure streak into one error-severity
`transport-outage` event. Environment (reachability, app lifecycle phase,
seconds since last success, consecutive-failure count) rides on every capture.

## Wiring

- iOS: `AppCompositionRoot` sets the tap on the injected `DiagnosticLog`
  (role `mobileClient`). Consent is the same
  `AnalyticsConsentProviding` gate crash reporting uses; the SDK's
  `beforeSend`/`beforeSendLog` re-check it per envelope, and every outgoing
  event, breadcrumb, and log is scrubbed by `SentryEventScrubber`
  (target `CmuxSentryReporting`, pure core in `CmuxSentryScrubbing`).
- macOS: `AppDelegate` sets the tap on
  `MobileHostIrohRuntime.hostDiagnosticLog` (role `macHost`) after
  `SentrySDK.start`, gated by `MacSentryStartupPolicy` as before.

## Reading an issue

A transport issue's title is the policy signature (e.g.
`Transport failure: transportDialFailed/policyUnavailable/iroh`). Tags:
`transport.event`, `transport.failure`, `transport.kind`, `transport.role`,
`transport.incident` (`failure` | `outage`). The `cmux.transport` context
holds streak counts and suppression counters. The attachment holds the full
ring in `cmuxdiag v1` compact form (`tNanos,code,surface,ms,a,b,c` rows); the
breadcrumb trail holds the same events decoded, in order.
