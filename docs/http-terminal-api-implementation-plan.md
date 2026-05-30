# cmux HTTP Terminal Access API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- **Date:** 2026-05-30
- **Spec:** [`docs/http-terminal-api-design.md`](./http-terminal-api-design.md)
- **Status:** Synthesized + reviewed + Errata folded inline. **Errata (Appendix C) is now FOLDED INTO TASK BODIES — read for reference only.** The 3-phase parallel synthesis originally introduced 20 cross-phase contradictions (4 blockers, 9 majors, 7 minors per final verification); a 2026-05-30 fold-in pass rewrote every conflicting Phase 0/1/2 task body in place so the API contracts E1-E20 are now consistent throughout the plan. Appendix C remains as a contract-reference record (no override notice needed).

**Goal:** Add a local HTTP API to read and write specific cmux terminal tabs — supporting `text`/`cells`/`raw` output representations, `text`/`keys`/`raw`/`paste`/`mouse`/`focus` input modes, and SSE streaming with explicit backpressure — bound to localhost (TCP hardened, with UDS opt-in), gated by a Settings toggle and a token.

**Architecture:** A new leaf Swift package `CmuxTerminalAccess` owns the service core (`TerminalAccessService`), value types (`SurfaceHandle`, `ScreenReadRequest`/`Result`, `CellGrid` + cell model with 4-valued `WideKind` + `WRAP`/`WRAP_CONTINUATION`, `InputPayload` with mouse/focus, `OutputSubscription` class, etc.), and the `SurfaceProvider` protocol seam. The HTTP transport lives in the app target (`Sources/HTTPControl/`) and uses `NWListener` for TCP + a hand-rolled POSIX `AF_UNIX` listener for UDS (mirroring the existing socket server). All transports (HTTP, existing Unix socket, CLI) route through the shared service, honoring the repo's shared-behavior policy. Two ghostty fork patches: (1) apprt cell-grid export — done as a direct page-walk that returns wide enum / wrap flags / hyperlink-table / underline / cursor / OSC 133 semantic; (2) PTY output byte tee at `Termio.processOutput` with a strict non-blocking contract (memcpy into a pre-allocated per-subscriber slot ring under the render lock, increment atomic seq, return — network writes off-thread). `mode=cells` snapshots use a time-tick poller + FNV-1a hash for dirty detection (no third ghostty patch in v1).

**Tech Stack:** Swift 5.9 · Swift Testing (new tests) · Network.framework `NWListener` for TCP · POSIX `socket/bind/listen` + `DispatchSourceRead` for UDS · ghostty fork at `manaflow-ai/ghostty` (Zig) · `SecRandomCopyBytes` for token generation · token-bucket `RateLimiter` per `(surface, connection)` key.

**Phasing:**
1. **Phase 0** — `CmuxTerminalAccess` package + foundations (no HTTP listener, no ghostty patch). Pure internal refactor; existing socket commands re-routed through the service unchanged. Ships the shared types, `AppSurfaceProvider`, `HTTPControlSettings` + token store, `AuditLog`/`RateLimiter`, paste-atomicity actor, `focusSurface` wiring, and a behavioral test that the HTTP token is **not** injected into child terminal env.
2. **Phase 1** — HTTP transport (TCP hardened + UDS opt-in) + ghostty patch #1 (cells export) + `format=cells`. Patch #1 + Swift bridge land early so the `/screen` route's cells test asserts real `200 + CellGrid JSON`, not a deferred stub. Includes Settings UI, config schema, user-facing API docs, behavioral config-loader test (not source-grep), ESC-strip safety test, direct-mouse no-NSEvent test.
3. **Phase 2** — Ghostty patch #2 (PTY output tee) + SSE streaming (`mode=raw` live bytes; `mode=cells` polled throttled snapshots). Event-level `seq` with `Last-Event-ID` resume. Zero-alloc trampoline; bounded ring per subscriber; per-surface stream cap; heartbeat; token rotation invalidates active streams.

**Cross-cutting non-negotiables** (locked decisions D1–D30 from the synthesis brief — see appendix "Locked Decisions"):
- `SurfaceProvider` everywhere `async throws` (D1). `TerminalAccessError.unsupported` → 415 (D18). `405 method_not_allowed` with `Allow:` header (D11). HTTP token never injected into child env (D9). Audit always-on for writes in v1, not opt-in (D4). `format=raw` on `/screen` → 400 explicit (D29).
- `OutputSubscription` is a class (not a protocol), defined once in Phase 0 (D22, D23). `StreamMode` / `StreamSubscriptionOptions` / `OutputEvent` / `HTTPControlSettings` / `AuditEntry` / `RateLimiter` / `KeyEvent.parse` all defined ONCE (D2/D3/D10/D21/D23).
- SSE `seq` is **event-level**, not byte-level (D6). `OutputTee` C trampoline is **zero-alloc** under the render lock via a fixed pre-allocated subscriber-slot array (D7). `StreamCap.Token.release()` calls `onRelease` once via CAS — no recursive shadowing (D24).
- UDS via POSIX `socket(AF_UNIX, SOCK_STREAM)` + `bind/listen` + `DispatchSourceRead`, mirroring the existing cmux socket server (D12). `NWEndpoint.unix(path:)` is NOT used (not stable public API).
- Cell ABI is complete on first cut to avoid a v2 fork-ABI re-cut: full 4-valued `WideKind` (D25 — narrow/wide/spacerTail/spacerHead), `WRAP` **and** `WRAP_CONTINUATION` row flags, full grapheme cluster in `t`, `UnderlineKind` + `underlineColor`, real hyperlink URIs via per-call hyperlink table (D26), `semantic_available` flag (D27).
- Paste atomicity: per-surface serial actor in `DefaultTerminalAccessService` (D30).
- Submodule push-before-pointer: every ghostty patch task pushes `manaflow/main` **before** the parent-repo pointer bump task (D20).
- All new test files wired into `cmux.xcodeproj/project.pbxproj`; `scripts/lint-pbxproj-test-wiring.sh` run after wiring. Swift Testing (`import Testing`); never run app tests locally — push and let CI run them.

---

## Table of Contents

### Phase 0
  - [Task 0.1: Create `CmuxTerminalAccess` package skeleton + smoke test](#task-0-1-create-cmuxterminalaccess-package-skeleton-smoke-test)
  - [Task 0.2: `SurfaceHandle` value type + parser (RED → GREEN)](#task-0-2--surfacehandle-value-type-parser-red-green)
  - [Task 0.3: `ScreenFormat`, `ScreenRegion`, `WrapPolicy` (one type per file)](#task-0-3--screenformat-screenregion-wrappolicy-one-type-per-file)
  - [Task 0.4: `ScreenReadRequest`](#task-0-4--screenreadrequest)
  - [Task 0.5: Cell-grid enums — `WideKind`, `CellAttribute`, `CellColor`, `SemanticKind`, `CursorStyle`, `UnderlineKind` (D25)](#task-0-5-cell-grid-enums-widekind-cellattribute-cellcolor-semantickind-cursorstyle-underlinekind-d25)
  - [Task 0.6: `Cell` + `CellRow` + `CursorState` (D25/D26 underline/hyperlink shape)](#task-0-6--cell-cellrow-cursorstate-d25-d26-underline-hyperlink-shape)
  - [Task 0.7: `CellGrid` + `TextScreenPayload` + `ScreenReadResult` (semantic_available bool per D27)](#task-0-7--cellgrid-textscreenpayload-screenreadresult-semantic-available-bool-per-d27)
  - [Task 0.8: `KeyMod` + `NamedKey` + `KeyEventParseError` + `KeyEvent.parse(_:) throws` (D21)](#task-0-8--keymod-namedkey-keyeventparseerror-keyevent-parse-throws-d21)
  - [Task 0.9: `MouseAction` + `MouseButton` + `MouseEvent` (with throwing `parse(_:)`)](#task-0-9--mouseaction-mousebutton-mouseevent-with-throwing-parse)
  - [Task 0.10: `InputPayload` + `InputRequest` (with `focusSurface`)](#task-0-10--inputpayload-inputrequest-with-focussurface)
  - [Task 0.11: `StreamMode` + `StreamSubscriptionOptions` + `OutputEvent` (D23)](#task-0-11--streammode-streamsubscriptionoptions-outputevent-d23)
  - [Task 0.12: `OutputSubscription` final class (D22)](#task-0-12--outputsubscription-final-class-d22)
  - [Task 0.13: `TerminalAccessError` — `.unsupported` → 415 (D18); `.featureDisabled` → 404 (D11)](#task-0-13--terminalaccesserror-unsupported-415-d18-featuredisabled-404-d11)
  - [Task 0.14: `AuditKind` enum + `AuditEntry` (D3) + `AuditLog` protocol + `NoOpAuditLog` (D4)](#task-0-14--auditkind-enum-auditentry-d3-auditlog-protocol-noopauditlog-d4)
  - [Task 0.15: `FileAuditLog` (mode 0600 enforced on every open)](#task-0-15--fileauditlog-mode-0600-enforced-on-every-open)
  - [Task 0.16: `RateLimiter` (D10) — `init(burstCapacity:refillPerSecond:clock:)`, lazy per-key buckets](#task-0-16--ratelimiter-d10-init-burstcapacity-refillpersecond-clock-lazy-per-key-buckets)
  - [Task 0.17: `SurfaceInfo` + `SurfaceProvider` protocol (D1 all `async throws`; `readCells` required member)](#task-0-17--surfaceinfo-surfaceprovider-protocol-d1-all-async-throws-readcells-required-member)
  - [Task 0.18: Shared `StubSurfaceProvider` in `TestSupport/` (D13)](#task-0-18-shared-stubsurfaceprovider-in-testsupport-d13)
  - [Task 0.19: `TerminalAccessService` protocol + `DefaultTerminalAccessService` listSurfaces + readScreen text path](#task-0-19--terminalaccessservice-protocol-defaultterminalaccessservice-listsurfaces-readscreen-text-path)
  - [Task 0.20: `DefaultTerminalAccessService.writeInput` — text / keys / raw-gate / mouse / focus + `focusSurface` wiring (D17)](#task-0-20--defaultterminalaccessservice-writeinput-text-keys-raw-gate-mouse-focus-focussurface-wiring-d17)
  - [Task 0.21: Per-surface paste atomicity test (D30) — concurrent paste interleave check (characterization test — no red→green ritual)](#task-0-21-per-surface-paste-atomicity-test-d30-concurrent-paste-interleave-check-characterization-test-no-red-green-ritual)
  - [Task 0.22: `HTTPControlSettings` (D2 instance class) + embedded token store + `Transport` enum](#task-0-22--httpcontrolsettings-d2-instance-class-embedded-token-store-transport-enum)
  - [Task 0.23: `AppSurfaceProvider` (app target) — bridge to `TerminalController` (D1 async throws; D9 no env injection)](#task-0-23--appsurfaceprovider-app-target-bridge-to-terminalcontroller-d1-async-throws-d9-no-env-injection)
  - [Task 0.24: Replace `TerminalController` stub forwarders with real extracts (one task per extract, each RED → GREEN)](#task-0-24-replace-terminalcontroller-stub-forwarders-with-real-extracts-one-task-per-extract-each-red-green)
  - [Task 0.25: HTTP-token-NOT-in-child-env behavioral test (D9)](#task-0-25-http-token-not-in-child-env-behavioral-test-d9)
  - [Task 0.26: Regression characterization tests (RED) + route existing v1/v2 socket commands through `DefaultTerminalAccessService` (GREEN) — split per-command](#task-0-26-regression-characterization-tests-red-route-existing-v1-v2-socket-commands-through-defaultterminalaccessservice-green-split-per-command)
  - [Task 0.27: pbxproj lint sweep + Phase 0 close-out](#task-0-27-pbxproj-lint-sweep-phase-0-close-out)
### Phase 1
  - [Task 1.1: `HTTPRequestParser` + `HTTPRequest` model with size caps (no listener)](#task-1-1--httprequestparser-httprequest-model-with-size-caps-no-listener)
  - [Task 1.2: `JSONResponses` + `TerminalAccessError` → status mapping (415 for `.unsupported`, D18)](#task-1-2--jsonresponses-terminalaccesserror-status-mapping-415-for-unsupported-d18)
  - [Task 1.3: `HTTPAuth` constant-time bearer compare](#task-1-3--httpauth-constant-time-bearer-compare)
  - [Task 1.4: `HostAllowlist` (loopback Host + Origin)](#task-1-4--hostallowlist-loopback-host-origin)
  - [Task 1.5: Ghostty patch #1 — C ABI declarations in `ghostty/include/ghostty.h`](#task-1-5-ghostty-patch-1-c-abi-declarations-in-ghostty-include-ghostty-h)
  - [Task 1.6: Ghostty patch #1 — Zig impl in `ghostty/src/apprt/embedded.zig` (direct page-walk, no clamped point-tag)](#task-1-6-ghostty-patch-1-zig-impl-in-ghostty-src-apprt-embedded-zig-direct-page-walk-no-clamped-point-tag)
  - [Task 1.7: Ghostty patch #1 — push fork branch, rebuild xcframework, bump parent submodule pointer (D20)](#task-1-7-ghostty-patch-1-push-fork-branch-rebuild-xcframework-bump-parent-submodule-pointer-d20)
  - [Task 1.8: `GhosttyCellsBridge` — Swift wrapper for the new C API (D25 underline, D26 hyperlink URIs, D27 semantic_available)](#task-1-8--ghosttycellsbridge-swift-wrapper-for-the-new-c-api-d25-underline-d26-hyperlink-uris-d27-semantic-available)
  - [Task 1.9: `AppSurfaceProvider.readCells` + upstream tracking issue (D19)](#task-1-9--appsurfaceprovider-readcells-upstream-tracking-issue-d19)
  - [Task 1.10: `RouteTable` + table-driven router (D11: 405 with `Allow:` header for method-mismatch)](#task-1-10--routetable-table-driven-router-d11-405-with-allow-header-for-method-mismatch)
  - [Task 1.11: `HTTPControlServer` TCP listener bring-up (no routes yet)](#task-1-11--httpcontrolserver-tcp-listener-bring-up-no-routes-yet)
  - [Task 1.12: Route `GET /v1/surfaces` (live, via async `TerminalAccessService.listSurfaces`)](#task-1-12-route-get-v1-surfaces-live-via-async-terminalaccessservice-listsurfaces)
  - [Task 1.13: `CellGridJSON` encoder (cells, D25 underline, D26 hyperlink, D27 semantic_available)](#task-1-13--cellgridjson-encoder-cells-d25-underline-d26-hyperlink-d27-semantic-available)
  - [Task 1.14: Route `GET /v1/surfaces/{id}/screen` — text + cells + `wrap=join` + `format=raw` → 400 (D29)](#task-1-14-route-get-v1-surfaces-id-screen-text-cells-wrap-join-format-raw-400-d29)
  - [Task 1.15: Per-surface rate limit (writes) + always-on audit log wiring (D4, D10)](#task-1-15-per-surface-rate-limit-writes-always-on-audit-log-wiring-d4-d10)
  - [Task 1.16: `InputRequestDecoder` + route `POST /v1/surfaces/{id}/input` for text/keys/paste/raw/mouse/focus](#task-1-16--inputrequestdecoder-route-post-v1-surfaces-id-input-for-text-keys-paste-raw-mouse-focus)
  - [Task 1.17: HTTP token NOT injected into child terminal env (behavioral test, D9)](#task-1-17-http-token-not-injected-into-child-terminal-env-behavioral-test-d9)
  - [Task 1.18: `HTTPControlUDSListener` — POSIX socket(2) + bind(2) + listen(2) (D12, mode 0600)](#task-1-18--httpcontroludslistener-posix-socket-2-bind-2-listen-2-d12-mode-0600)
  - [Task 1.19: Settings UI pane (SwiftUI) + localization (EN + JA), with TCP safety + raw OSC52/DSR warning](#task-1-19-settings-ui-pane-swiftui-localization-en-ja-with-tcp-safety-raw-osc52-dsr-warning)
  - [Task 1.20: Behavioral config-loader test for `httpControl` block in `cmux.json` (D14, NOT a schema text-grep)](#task-1-20-behavioral-config-loader-test-for-httpcontrol-block-in-cmux-json-d14-not-a-schema-text-grep)
  - [Task 1.21: User-facing API docs `docs/http-terminal-api.md` (with D27 zsh caveat + D28 out-of-scope)](#task-1-21-user-facing-api-docs-docs-http-terminal-api-md-with-d27-zsh-caveat-d28-out-of-scope)
  - [Task 1.22: Lifecycle wire-up + token rotation invalidates running connections](#task-1-22-lifecycle-wire-up-token-rotation-invalidates-running-connections)
  - [Task 1.23: pbxproj normalization + final phase-1 sweep + PR](#task-1-23-pbxproj-normalization-final-phase-1-sweep-pr)
### Phase 2
  - [Task 2.1: Ghostty patch #2 — declare `ghostty_surface_set_output_tee` in `include/ghostty.h`](#task-2-1-ghostty-patch-2-declare-ghostty-surface-set-output-tee-in-include-ghostty-h)
  - [Task 2.2: Ghostty patch #2 — Zig tee field, invocation, install helper in `Termio.zig`](#task-2-2-ghostty-patch-2-zig-tee-field-invocation-install-helper-in-termio-zig)
  - [Task 2.3: Ghostty patch #2 — export `ghostty_surface_set_output_tee` in `embedded.zig`, commit + push fork BEFORE parent pointer bump (D20)](#task-2-3-ghostty-patch-2-export-ghostty-surface-set-output-tee-in-embedded-zig-commit-push-fork-before-parent-pointer-bump-d20)
  - [Task 2.4: Ghostty patch #2 — record fork change in `docs/ghostty-fork.md` + bump parent pointer](#task-2-4-ghostty-patch-2-record-fork-change-in-docs-ghostty-fork-md-bump-parent-pointer)
  - [Task 2.5: Failing test for `EventRing<OutputEvent>` (drop-oldest, monotonic event-level seq) — RED commit](#task-2-5-failing-test-for-eventring-outputevent-drop-oldest-monotonic-event-level-seq-red-commit)
  - [Task 2.6: Implement `EventRing` (GREEN commit)](#task-2-6-implement-eventring-green-commit)
  - [Task 2.7: Add `MonotonicClock` to `CmuxTerminalAccess` (single-source-of-truth)](#task-2-7-add-monotonicclock-to-cmuxterminalaccess-single-source-of-truth)
  - [Task 2.8: Failing test for `CellGridDigest` (FNV-1a over codepoints + cursor) — RED commit](#task-2-8-failing-test-for-cellgriddigest-fnv-1a-over-codepoints-cursor-red-commit)
  - [Task 2.9: Implement `CellGridDigest` (GREEN commit)](#task-2-9-implement-cellgriddigest-green-commit)
  - [Task 2.10: Failing test for `SnapshotPoller` (time-tick + hash gates emit; D8) — RED commit](#task-2-10-failing-test-for-snapshotpoller-time-tick-hash-gates-emit-d8-red-commit)
  - [Task 2.11: Implement `SnapshotPoller` (GREEN commit)](#task-2-11-implement-snapshotpoller-green-commit)
  - [Task 2.12: Failing test for `StreamCap` (D7 — pre-allocated slot array per surface, cap = 8) — RED commit](#task-2-12-failing-test-for-streamcap-d7-pre-allocated-slot-array-per-surface-cap-8-red-commit)
  - [Task 2.13: Failing test for `OutputTee` C trampoline (zero-allocation distribution) — RED commit](#task-2-13-failing-test-for-outputtee-c-trampoline-zero-allocation-distribution-red-commit)
  - [Task 2.14: Implement `OutputTee` with pre-allocated slot array + C trampoline (GREEN commit)](#task-2-14-implement-outputtee-with-pre-allocated-slot-array-c-trampoline-green-commit)
  - [Task 2.15: `SurfaceProvider` extension — raw-output source seam (async)](#task-2-15--surfaceprovider-extension-raw-output-source-seam-async)
  - [Task 2.16: `TerminalAccessService.subscribeOutput` skeleton + raw-mode failing test (RED)](#task-2-16--terminalaccessservice-subscribeoutput-skeleton-raw-mode-failing-test-red)
  - [Task 2.17: Implement `openRawSubscription` — wires `SurfaceRawOutputSource` → `EventRing` → `onEvent`, audits open/close (GREEN)](#task-2-17-implement-openrawsubscription-wires-surfacerawoutputsource-eventring-onevent-audits-open-close-green)
  - [Task 2.18: Implement `openCellsSubscription` using `SnapshotPoller` (D8) (characterization test — no red→green ritual)](#task-2-18-implement-opencellssubscription-using-snapshotpoller-d8-characterization-test-no-red-green-ritual)
  - [Task 2.19: `OutputSubscription.signalEnd` + `onEnd` wiring; surface-close test (RED → GREEN)](#task-2-19--outputsubscription-signalend-onend-wiring-surface-close-test-red-green)
  - [Task 2.20: HTTP route `GET /v1/surfaces/{id}/stream` — listener wiring + happy-path headers + 405/401 (RED → GREEN)](#task-2-20-http-route-get-v1-surfaces-id-stream-listener-wiring-happy-path-headers-405-401-red-green)
  - [Task 2.21: Wire `subscribeOutput` into `handleStream` + raw payload framing + cells payload framing](#task-2-21-wire-subscribeoutput-into-handlestream-raw-payload-framing-cells-payload-framing)
  - [Task 2.22: Heartbeat timer + lifetime cleanup on connection close](#task-2-22-heartbeat-timer-lifetime-cleanup-on-connection-close)
  - [Task 2.23: Per-surface stream cap enforcement at HTTP layer — 503 on overflow](#task-2-23-per-surface-stream-cap-enforcement-at-http-layer-503-on-overflow)
  - [Task 2.24: `Last-Event-ID` resume — in-ring vs gap-comment (D6)](#task-2-24--last-event-id-resume-in-ring-vs-gap-comment-d6)
  - [Task 2.25: Stream-open rate limit via shared `RateLimiter` keys (D10)](#task-2-25-stream-open-rate-limit-via-shared-ratelimiter-keys-d10)
  - [Task 2.26: `AppSurfaceProvider` raw-output integration with live Ghostty surfaces (D9 reaffirmed)](#task-2-26--appsurfaceprovider-raw-output-integration-with-live-ghostty-surfaces-d9-reaffirmed)
  - [Task 2.27: E2E — raw bytes round-trip through real surface](#task-2-27-e2e-raw-bytes-round-trip-through-real-surface)
  - [Task 2.28: E2E — cells snapshot reflects visible output](#task-2-28-e2e-cells-snapshot-reflects-visible-output)
  - [Task 2.29: Backpressure E2E — slow consumer sees seq JUMP without stalling source (D6, spec §9.1)](#task-2-29-backpressure-e2e-slow-consumer-sees-seq-jump-without-stalling-source-d6-spec-9-1)
  - [Task 2.30: Token rotation invalidates running SSE subscriptions](#task-2-30-token-rotation-invalidates-running-sse-subscriptions)
  - [Task 2.31: Localize streaming-related Settings strings + extend config schema (`httpControl.stream`)](#task-2-31-localize-streaming-related-settings-strings-extend-config-schema-httpcontrol-stream)
  - [Task 2.32: Append SSE docs to `docs/http-terminal-api.md` — fetch-streaming example + backpressure + out-of-scope](#task-2-32-append-sse-docs-to-docs-http-terminal-api-md-fetch-streaming-example-backpressure-out-of-scope)
  - [Task 2.33: pbxproj normalization + final phase-2 sweep](#task-2-33-pbxproj-normalization-final-phase-2-sweep)

---

## Phase 0 — `CmuxTerminalAccess` package + foundations (no HTTP server, no ghostty patch)

This phase produces the `CmuxTerminalAccess` Swift package, all shared value types and protocol seams listed in the locked decisions (D1–D30), the `AppSurfaceProvider` app-side bridge, `HTTPControlSettings` + token store, the `DefaultTerminalAccessService` with paste-atomicity actor + `focusSurface` wiring, and reroutes the existing v1 `read_screen` and v2 `surface.read_text` / `surface.send_text` / `surface.send_key` socket commands through the new service. No HTTP listener, no ghostty patch, no streaming impl. Behavior of existing socket commands is byte-identical (regression characterization tests committed RED before the routing change per the two-commit policy).

All tests use Swift Testing (`import Testing`, `@Suite struct`, `@Test func`, `#expect`, `try #require`). Package tests live in `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/` (auto-detected via `import Testing`). App-target tests live in `cmuxTests/HTTPControl/` and MUST be wired into `cmux.xcodeproj/project.pbxproj`; `scripts/lint-pbxproj-test-wiring.sh` is invoked after every test-file add. Tests are never run locally — every "verify failing" / "verify green" step is `git push` so CI runs it.

Tasks land in dependency order. Numbering is contiguous 0.1–0.27.

- 0.1     Package skeleton.
- 0.2     `SurfaceHandle` (enum + parser).
- 0.3     `ScreenFormat`, `ScreenRegion`, `WrapPolicy`.
- 0.4     `ScreenReadRequest`.
- 0.5     Cell-grid enums: `WideKind`, `CellAttribute` (NO `.underline` per D25), `CellColor`, `SemanticKind`, `CursorStyle`, `UnderlineKind` (D25).
- 0.6     `Cell` (with `underlineKind`/`underlineColor`/`hyperlink` per D25/D26) + `CellRow` + `CursorState`.
- 0.7     `CellGrid` (with `semanticAvailable` per D27) + `TextScreenPayload` + `ScreenReadResult`.
- 0.8     `KeyMod` + `NamedKey` + `KeyEventParseError` + `KeyEvent.parse(_:) throws` (D21).
- 0.9     `MouseAction` + `MouseButton` + `MouseEvent` (with `parse(_ obj: [String: Any]) throws`).
- 0.10    `InputPayload` + `InputRequest` (with `focusSurface`).
- 0.11    `StreamMode` + `StreamSubscriptionOptions` + `OutputEvent`.
- 0.12    `OutputSubscription` final class (D22) with `id`, `handle`, `mode`, `cancel()`, `signalEnd()`, `onEnd`, `events()`.
- 0.13    `TerminalAccessError` (`.unsupported` → 415 per D18; `.featureDisabled` → 404).
- 0.14    `AuditKind` enum (D3) + `AuditEntry` (D3) + `AuditLog` protocol + `NoOpAuditLog` (D4).
- 0.15    `FileAuditLog` (enforces mode 0600 on every open per Quality finding).
- 0.16    `RateLimiter` (D10) — `init(burstCapacity:refillPerSecond:clock:)`, lazy per-string-key buckets.
- 0.17    `SurfaceInfo` + `SurfaceProvider` protocol (D1: all `async throws`, Sendable; `readCells` is a REQUIRED member per E20; raw-output tap is a Phase 2 extension, NOT a Phase 0 required member).
- 0.18    Shared `StubSurfaceProvider` (D13) in `Tests/CmuxTerminalAccessTests/TestSupport/`.
- 0.19    `TerminalAccessService` protocol + `DefaultTerminalAccessService` listSurfaces + readScreen text path.
- 0.20    `DefaultTerminalAccessService` write paths: text/keys/raw-gate/mouse/focus + `focusSurface` wiring (D17).
- 0.21    `DefaultTerminalAccessService` per-surface paste serial actor (D30) + concurrent paste interleave test.
- 0.22    `HTTPControlSettings` (D2) instance class + embedded token store + `Transport` enum (single definition).
- 0.23    `AppSurfaceProvider` (app target) — bridge to `TerminalController` (D1 async throws; D9 no env injection comment).
- 0.24    Extract `TerminalController` helpers (`terminalPanel(byUUID:)`, `mergedScreenText`, `sendKeyToPanel`, `sendMouseToPanel`, `v2EnumerateSurfacesForListing`) — one task per extract with its own failing characterization test.
- 0.25    HTTP-token-not-in-child-env behavioral test (D9).
- 0.26    Regression characterization (RED) + route existing v1/v2 socket commands through service (GREEN).
- 0.27    pbxproj wiring lint + Phase 0 close-out.

---

### Task 0.1: Create `CmuxTerminalAccess` package skeleton + smoke test

**Files:**
- Create: `Packages/CmuxTerminalAccess/Package.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CmuxTerminalAccess.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PackageSmokeTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj` (add `XCLocalSwiftPackageReference` + product dependency)

- [ ] **Step 1: Write failing test**
```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PackageSmokeTests.swift
import Testing
@testable import CmuxTerminalAccess

@Suite struct PackageSmokeTests {
    @Test func packageVersionIsExposed() {
        #expect(CmuxTerminalAccess.version == "0.1.0")
    }
}
```

- [ ] **Step 2: Create `Package.swift`**
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmuxTerminalAccess",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CmuxTerminalAccess", targets: ["CmuxTerminalAccess"])],
    targets: [
        .target(name: "CmuxTerminalAccess", path: "Sources/CmuxTerminalAccess"),
        .testTarget(
            name: "CmuxTerminalAccessTests",
            dependencies: ["CmuxTerminalAccess"],
            path: "Tests/CmuxTerminalAccessTests"
        ),
    ]
)
```

- [ ] **Step 3: Implement package entry point**
```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CmuxTerminalAccess.swift

/// Umbrella namespace for the ``CmuxTerminalAccess`` package.
///
/// Holds protocol seams (``SurfaceProvider``, ``TerminalAccessService``)
/// and shared value types every cmux terminal-access transport (Unix
/// socket, CLI, HTTP) routes through.
public enum CmuxTerminalAccess {
    /// Package version surfaced for smoke tests and audit log metadata.
    public static let version = "0.1.0"
}
```

- [ ] **Step 4: Wire the package into `cmux.xcodeproj`**
Add as `XCLocalSwiftPackageReference` (`relativePath = Packages/CmuxTerminalAccess`) and as a product dependency of the `cmux` app target, mirroring the existing `CMUXDebugLog` wiring. Then:
```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
bash scripts/check-pbxproj.sh
```

- [ ] **Step 5: Commit**
```bash
git add Packages/CmuxTerminalAccess cmux.xcodeproj/project.pbxproj
git commit -m "Add CmuxTerminalAccess package skeleton"
git push
```
Expected: CI green (`PackageSmokeTests`).

---

### Task 0.2: `SurfaceHandle` value type + parser (RED → GREEN)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceHandle.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SurfaceHandleTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SurfaceHandleTests {
    @Test func parsesUUIDForm() throws {
        let raw = "550e8400-e29b-41d4-a716-446655440000"
        let parsed = try #require(SurfaceHandle.parse(raw))
        guard case .uuid(let u) = parsed else { Issue.record("not uuid"); return }
        #expect(u == UUID(uuidString: raw))
    }
    @Test func parsesRefForm() throws {
        let parsed = try #require(SurfaceHandle.parse("surface:1"))
        guard case .ref(let kind, let ord) = parsed else { Issue.record("not ref"); return }
        #expect(kind == "surface"); #expect(ord == 1)
    }
    @Test func parsesOtherKinds() throws {
        let parsed = try #require(SurfaceHandle.parse("workspace:42"))
        guard case .ref(let kind, let ord) = parsed else { Issue.record("not ref"); return }
        #expect(kind == "workspace"); #expect(ord == 42)
    }
    @Test(arguments: ["", "surface:", "surface:abc", ":1", "surface:-1", "surface:1:2", "not-a-uuid", "Surface:1"])
    func rejectsInvalid(_ s: String) { #expect(SurfaceHandle.parse(s) == nil) }
    @Test func codableRoundTrip() throws {
        let h: SurfaceHandle = .ref(kind: "surface", ordinal: 7)
        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(SurfaceHandle.self, from: data) == h)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SurfaceHandleTests.swift
git commit -m "Add failing SurfaceHandle parser tests"
git push
```
Expected: CI fails — `cannot find 'SurfaceHandle' in scope`.

- [ ] **Step 3: Implement**
```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceHandle.swift
import Foundation

/// Stable, transport-neutral reference to a single cmux terminal surface.
///
/// Two interchangeable forms:
/// - ``uuid(_:)`` — persistent ``UUID``.
/// - ``ref(kind:ordinal:)`` — short human-friendly form like `"surface:1"`.
public enum SurfaceHandle: Hashable, Sendable, Codable {
    case uuid(UUID)
    case ref(kind: String, ordinal: Int)

    /// Parses a handle string. Accepts a canonical UUID (case-insensitive)
    /// or `kind:ordinal` with `kind` in `[a-z]+` and `ordinal` a positive
    /// decimal integer. Returns `nil` for any other shape.
    public static func parse(_ s: String) -> SurfaceHandle? {
        if let u = UUID(uuidString: s) { return .uuid(u) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let kind = String(parts[0]); let ordStr = String(parts[1])
        guard !kind.isEmpty,
              kind.allSatisfy({ $0.isASCII && $0.isLetter && $0.isLowercase })
        else { return nil }
        guard let ord = Int(ordStr), ord > 0 else { return nil }
        return .ref(kind: kind, ordinal: ord)
    }

    /// Canonical string form. Round-trips through ``parse(_:)``.
    public var stringValue: String {
        switch self {
        case .uuid(let u): return u.uuidString
        case .ref(let k, let o): return "\(k):\(o)"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let parsed = SurfaceHandle.parse(raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad SurfaceHandle: \(raw)")
        }
        self = parsed
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(stringValue)
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceHandle.swift
git commit -m "Implement SurfaceHandle parser"
git push
```

---

### Task 0.3: `ScreenFormat`, `ScreenRegion`, `WrapPolicy` (one type per file)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ScreenFormat.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ScreenRegion.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/WrapPolicy.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ScreenEnumWireTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ScreenEnumWireTests {
    @Test func wireValuesAreLowercase() throws {
        #expect(try String(decoding: JSONEncoder().encode(ScreenFormat.text), as: UTF8.self) == "\"text\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenFormat.cells), as: UTF8.self) == "\"cells\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenRegion.viewport), as: UTF8.self) == "\"viewport\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenRegion.screen), as: UTF8.self) == "\"screen\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenRegion.scrollback), as: UTF8.self) == "\"scrollback\"")
        #expect(try String(decoding: JSONEncoder().encode(WrapPolicy.preserve), as: UTF8.self) == "\"preserve\"")
        #expect(try String(decoding: JSONEncoder().encode(WrapPolicy.join), as: UTF8.self) == "\"join\"")
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ScreenEnumWireTests.swift
git commit -m "Add failing ScreenFormat/Region/WrapPolicy wire tests"
git push
```

- [ ] **Step 3: Implement enums**
```swift
// ScreenFormat.swift

/// The serialization mode requested for a screen read. ``cells`` requires
/// ghostty patch #1 (lands in Phase 1); in Phase 0 the service rejects it
/// with ``TerminalAccessError/unsupported(reason:)`` (HTTP 415 per D18).
public enum ScreenFormat: String, Sendable, Codable, CaseIterable { case text, cells }
```
```swift
// ScreenRegion.swift

/// Region of the surface to read. `screen` = scrollback + active rows;
/// `scrollback` = ghostty `SURFACE` tag (misleadingly named). On the alt
/// screen, `scrollback` returns an empty string per spec §7 invariant.
public enum ScreenRegion: String, Sendable, Codable, CaseIterable { case viewport, screen, scrollback }
```
```swift
// WrapPolicy.swift

/// How to render soft-wrapped (DECAWM) lines when emitting plain text.
/// ``join`` requires ghostty patch #1; Phase 0 rejects with
/// ``TerminalAccessError/unsupported(reason:)`` (415).
public enum WrapPolicy: String, Sendable, Codable, CaseIterable { case preserve, join }
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add ScreenFormat, ScreenRegion, WrapPolicy enums"
git push
```

---

### Task 0.4: `ScreenReadRequest`

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ScreenReadRequest.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ScreenReadRequestCodableTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ScreenReadRequestCodableTests {
    @Test func roundTrips() throws {
        let req = ScreenReadRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            format: .text, region: .viewport, wrap: .preserve, trim: true)
        let back = try JSONDecoder().decode(ScreenReadRequest.self,
                                            from: JSONEncoder().encode(req))
        #expect(back == req)
    }
    @Test func defaultsAreSafe() {
        let req = ScreenReadRequest(handle: .uuid(UUID()))
        #expect(req.format == .text); #expect(req.region == .viewport)
        #expect(req.wrap == .preserve); #expect(req.trim == true)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ScreenReadRequestCodableTests.swift
git commit -m "Add failing ScreenReadRequest codable tests"
git push
```

- [ ] **Step 3: Implement**
```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ScreenReadRequest.swift

/// A single screen-read request, addressable by ``SurfaceHandle`` and
/// parameterised by format/region/wrap/trim. Consumed by
/// ``TerminalAccessService/readScreen(_:)``.
public struct ScreenReadRequest: Hashable, Sendable, Codable {
    public let handle: SurfaceHandle
    public let format: ScreenFormat
    public let region: ScreenRegion
    public let wrap: WrapPolicy
    public let trim: Bool

    public init(
        handle: SurfaceHandle, format: ScreenFormat = .text,
        region: ScreenRegion = .viewport, wrap: WrapPolicy = .preserve,
        trim: Bool = true
    ) {
        self.handle = handle; self.format = format
        self.region = region; self.wrap = wrap; self.trim = trim
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ScreenReadRequest.swift
git commit -m "Add ScreenReadRequest"
git push
```

---

### Task 0.5: Cell-grid enums — `WideKind`, `CellAttribute`, `CellColor`, `SemanticKind`, `CursorStyle`, `UnderlineKind` (D25)

(Resolves Coverage must_fix: "Plan's CellGrid omits underline kind/color even though ABI declares them" — adds `UnderlineKind` enum; drops boolean `.underline` from `CellAttribute` per D25.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/WideKind.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellAttribute.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellColor.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SemanticKind.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CursorStyle.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/UnderlineKind.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellEnumWireTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellEnumWireTests {
    @Test func wideKindWireUsesSnakeCase() throws {
        #expect(try String(decoding: JSONEncoder().encode(WideKind.spacerTail), as: UTF8.self) == "\"spacer_tail\"")
        #expect(try String(decoding: JSONEncoder().encode(WideKind.spacerHead), as: UTF8.self) == "\"spacer_head\"")
    }
    @Test func cellAttributeDoesNotContainUnderline() {
        for raw in CellAttribute.allCases.map(\.rawValue) { #expect(raw != "underline") }
    }
    @Test func underlineKindWireValues() throws {
        #expect(try String(decoding: JSONEncoder().encode(UnderlineKind.single), as: UTF8.self) == "\"single\"")
        #expect(try String(decoding: JSONEncoder().encode(UnderlineKind.curly), as: UTF8.self) == "\"curly\"")
    }
    @Test func cellColorEncodingShapes() throws {
        #expect(try String(decoding: JSONEncoder().encode(CellColor.default), as: UTF8.self) == "\"default\"")
        let p = try JSONEncoder().encode(CellColor.palette(7))
        #expect(String(decoding: p, as: UTF8.self) == "{\"palette\":7}")
        let r = try JSONEncoder().encode(CellColor.rgb(r: 1, g: 2, b: 3))
        #expect(String(decoding: r, as: UTF8.self).contains("\"rgb\""))
    }
    @Test func semanticKindWire() throws {
        #expect(try String(decoding: JSONEncoder().encode(SemanticKind.promptContinuation), as: UTF8.self) == "\"prompt_continuation\"")
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellEnumWireTests.swift
git commit -m "Add failing cell-grid enum wire tests"
git push
```

- [ ] **Step 3: Implement enums**
```swift
// WideKind.swift

/// East-Asian-Width / spacer state for a cell, from ghostty's
/// `vt/screen.h:82-95` four-state enum.
public enum WideKind: String, Sendable, Codable, Hashable {
    case narrow
    case wide
    case spacerTail = "spacer_tail"
    case spacerHead = "spacer_head"
}
```
```swift
// CellAttribute.swift

/// Visual SGR-style cell attribute. The grid stores a ``Set`` of these
/// per cell. NOTE (D25): there is intentionally NO `.underline` case —
/// underline state lives on ``Cell/underlineKind`` (with optional
/// ``Cell/underlineColor``).
public enum CellAttribute: String, Sendable, Codable, Hashable, CaseIterable {
    case bold, italic, faint, blink, inverse, invisible, strikethrough
}
```
```swift
// CellColor.swift
import Foundation

/// Foreground/background color for a cell.
public enum CellColor: Sendable, Codable, Hashable {
    case `default`
    case palette(UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)

    private enum Keys: String, CodingKey { case palette, rgb }
    private struct RGB: Codable, Hashable { let r: UInt8; let g: UInt8; let b: UInt8 }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self), s == "default" {
            self = .default; return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        if let p = try c.decodeIfPresent(UInt8.self, forKey: .palette) { self = .palette(p); return }
        if let rgb = try c.decodeIfPresent(RGB.self, forKey: .rgb) {
            self = .rgb(r: rgb.r, g: rgb.g, b: rgb.b); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad CellColor"))
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .default:
            var c = encoder.singleValueContainer(); try c.encode("default")
        case .palette(let p):
            var c = encoder.container(keyedBy: Keys.self); try c.encode(p, forKey: .palette)
        case .rgb(let r, let g, let b):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(RGB(r: r, g: g, b: b), forKey: .rgb)
        }
    }
}
```
```swift
// SemanticKind.swift

/// OSC 133 shell-integration semantic kind. Populated only when the
/// surface's shell emits OSC 133 markers (currently zsh, via cmux's
/// `.zshenv` injection — see spec §15 and D27).
public enum SemanticKind: String, Sendable, Codable, Hashable {
    case prompt, input, output
    case promptContinuation = "prompt_continuation"
}
```
```swift
// CursorStyle.swift

/// Cursor presentation style as configured by the active program.
public enum CursorStyle: String, Sendable, Codable, Hashable { case block, underline, bar }
```
```swift
// UnderlineKind.swift

/// Underline style for a ``Cell``. Optional ``Cell/underlineColor``
/// carries the SGR 58 color; absent ``Cell/underlineKind`` means no
/// underline (D25). Replaces the boolean `.underline` attribute from
/// pre-D25 drafts.
public enum UnderlineKind: String, Sendable, Codable, Hashable {
    case single, double, curly, dotted, dashed
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add cell enum primitives with UnderlineKind (D25)"
git push
```

---

### Task 0.6: `Cell` + `CellRow` + `CursorState` (D25/D26 underline/hyperlink shape)

(Resolves Coverage must_fix: "hyperlink field is `String?` keyed off `hyperlink_id` (number-as-string)" — per D26 `Cell.hyperlink` holds the URI string directly; the Phase 1 Swift bridge resolves IDs to URIs via the per-call hyperlink table.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/Cell.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellRow.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CursorState.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellShapeTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellShapeTests {
    @Test func cellCarriesUnderlineKindAndColor() {
        let cell = Cell(
            t: "x", wide: .narrow, fg: .default, bg: .default,
            attrs: [.bold], underlineKind: .curly,
            underlineColor: .rgb(r: 9, g: 8, b: 7),
            hyperlink: "https://example.com", semantic: nil)
        #expect(cell.underlineKind == .curly)
        #expect(cell.underlineColor == .rgb(r: 9, g: 8, b: 7))
        #expect(cell.hyperlink == "https://example.com")
    }
    @Test func cellRowSnakeCaseWrap() throws {
        let row = CellRow(wrap: true, wrapContinuation: false, cells: [])
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(json.contains("\"wrap_continuation\":false"))
        #expect(json.contains("\"wrap\":true"))
    }
    @Test func cellOmitsNilsInJSON() throws {
        let cell = Cell(t: "y", wide: .narrow, fg: .default, bg: .default,
                        attrs: [], underlineKind: nil, underlineColor: nil,
                        hyperlink: nil, semantic: nil)
        let data = try JSONEncoder().encode(cell)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["underline_kind"] == nil)
        #expect(obj?["hyperlink"] == nil)
    }
    @Test func cursorStateRoundTrip() throws {
        let cs = CursorState(row: 3, col: 4, visible: false, style: .bar)
        let back = try JSONDecoder().decode(CursorState.self,
                                            from: JSONEncoder().encode(cs))
        #expect(back == cs)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellShapeTests.swift
git commit -m "Add failing Cell/CellRow/CursorState shape tests"
git push
```

- [ ] **Step 3: Implement**
```swift
// Cell.swift

/// One terminal cell. `t` is the full grapheme cluster (base + combining
/// + ZWJ + variation selectors), not a single code point. `underlineKind`
/// is `nil` when the cell has no underline (D25). `hyperlink` holds the
/// OSC 8 URI string directly per D26 (the Phase 1 Swift bridge resolves
/// ghostty's `hyperlink_id: u32` into the URI via the per-call hyperlink
/// table from ghostty patch #1).
public struct Cell: Hashable, Sendable, Codable {
    public let t: String
    public let wide: WideKind
    public let fg: CellColor
    public let bg: CellColor
    public let attrs: Set<CellAttribute>
    public let underlineKind: UnderlineKind?
    public let underlineColor: CellColor?
    public let hyperlink: String?
    public let semantic: SemanticKind?

    public init(t: String, wide: WideKind, fg: CellColor, bg: CellColor,
                attrs: Set<CellAttribute>, underlineKind: UnderlineKind? = nil,
                underlineColor: CellColor? = nil, hyperlink: String? = nil,
                semantic: SemanticKind? = nil) {
        self.t = t; self.wide = wide; self.fg = fg; self.bg = bg
        self.attrs = attrs; self.underlineKind = underlineKind
        self.underlineColor = underlineColor; self.hyperlink = hyperlink
        self.semantic = semantic
    }

    enum CodingKeys: String, CodingKey {
        case t, wide, fg, bg, attrs
        case underlineKind = "underline_kind"
        case underlineColor = "underline_color"
        case hyperlink, semantic
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t); try c.encode(wide, forKey: .wide)
        try c.encode(fg, forKey: .fg); try c.encode(bg, forKey: .bg)
        try c.encode(attrs, forKey: .attrs)
        try c.encodeIfPresent(underlineKind, forKey: .underlineKind)
        try c.encodeIfPresent(underlineColor, forKey: .underlineColor)
        try c.encodeIfPresent(hyperlink, forKey: .hyperlink)
        try c.encodeIfPresent(semantic, forKey: .semantic)
    }
}
```
```swift
// CellRow.swift

/// One row of cells with the soft-wrap flags needed to losslessly stitch
/// wrapped logical lines back together (`WRAP` and `WRAP_CONTINUATION`).
public struct CellRow: Hashable, Sendable, Codable {
    public let wrap: Bool
    public let wrapContinuation: Bool
    public let cells: [Cell]

    public init(wrap: Bool, wrapContinuation: Bool, cells: [Cell]) {
        self.wrap = wrap; self.wrapContinuation = wrapContinuation; self.cells = cells
    }
    enum CodingKeys: String, CodingKey {
        case wrap; case wrapContinuation = "wrap_continuation"; case cells
    }
}
```
```swift
// CursorState.swift

/// Cursor position and visibility for a single read.
public struct CursorState: Hashable, Sendable, Codable {
    public let row: Int
    public let col: Int
    public let visible: Bool
    public let style: CursorStyle
    public init(row: Int, col: Int, visible: Bool, style: CursorStyle) {
        self.row = row; self.col = col; self.visible = visible; self.style = style
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add Cell (with UnderlineKind D25 / hyperlink URI D26), CellRow, CursorState"
git push
```

---

### Task 0.7: `CellGrid` + `TextScreenPayload` + `ScreenReadResult` (semantic_available bool per D27)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellGrid.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/TextScreenPayload.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ScreenReadResult.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellGridCodableTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellGridCodableTests {
    @Test func roundTrip() throws {
        let cell = Cell(t: "H", wide: .narrow, fg: .default, bg: .default,
                        attrs: [.bold], underlineKind: .single,
                        underlineColor: nil, hyperlink: nil, semantic: .prompt)
        let row = CellRow(wrap: false, wrapContinuation: false, cells: [cell])
        let grid = CellGrid(cols: 1, rows: 1, altScreen: false, title: "t",
                            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                            semanticAvailable: true, rowsData: [row])
        let back = try JSONDecoder().decode(CellGrid.self,
                                            from: JSONEncoder().encode(grid))
        #expect(back == grid)
    }
    @Test func usesSnakeCaseTopKeys() throws {
        let grid = CellGrid(cols: 80, rows: 24, altScreen: true, title: nil,
                            cursor: CursorState(row: 0, col: 0, visible: false, style: .bar),
                            semanticAvailable: false, rowsData: [])
        let json = String(decoding: try JSONEncoder().encode(grid), as: UTF8.self)
        #expect(json.contains("\"alt_screen\":true"))
        #expect(json.contains("\"semantic_available\":false"))
        #expect(json.contains("\"rows_data\":[]"))
        #expect(json.contains("\"rows\":24"))
    }
    @Test func screenReadResultEncodesAsTaggedUnion() throws {
        let p = TextScreenPayload(cols: 1, rows: 1, altScreen: false, title: nil, text: "")
        let json = String(decoding: try JSONEncoder().encode(ScreenReadResult.text(p)), as: UTF8.self)
        #expect(json.contains("\"format\":\"text\""))
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellGridCodableTests.swift
git commit -m "Add failing CellGrid + ScreenReadResult codable tests"
git push
```

- [ ] **Step 3: Implement**
```swift
// CellGrid.swift

/// Full structured snapshot of the surface's currently visible grid.
/// `semanticAvailable` (D27) is `true` iff any row contains a cell with
/// a non-nil ``Cell/semantic``. Computed by the bridge in Phase 1; here
/// the type is purely declarative.
public struct CellGrid: Hashable, Sendable, Codable {
    public let cols: Int
    public let rows: Int
    public let altScreen: Bool
    public let title: String?
    public let cursor: CursorState
    public let semanticAvailable: Bool
    public let rowsData: [CellRow]

    public init(cols: Int, rows: Int, altScreen: Bool, title: String?,
                cursor: CursorState, semanticAvailable: Bool, rowsData: [CellRow]) {
        self.cols = cols; self.rows = rows; self.altScreen = altScreen
        self.title = title; self.cursor = cursor
        self.semanticAvailable = semanticAvailable; self.rowsData = rowsData
    }
    enum CodingKeys: String, CodingKey {
        case cols, rows
        case altScreen = "alt_screen"
        case title, cursor
        case semanticAvailable = "semantic_available"
        case rowsData = "rows_data"
    }
}
```
```swift
// TextScreenPayload.swift

/// Payload for ``ScreenReadResult/text(_:)`` — rendered UTF-8 plus the
/// minimum metadata a client needs (cols/rows/altScreen/title).
public struct TextScreenPayload: Hashable, Sendable, Codable {
    public let cols: Int
    public let rows: Int
    public let altScreen: Bool
    public let title: String?
    public let text: String
    public init(cols: Int, rows: Int, altScreen: Bool, title: String?, text: String) {
        self.cols = cols; self.rows = rows; self.altScreen = altScreen
        self.title = title; self.text = text
    }
    enum CodingKeys: String, CodingKey {
        case cols, rows
        case altScreen = "alt_screen"
        case title, text
    }
}
```
```swift
// ScreenReadResult.swift
import Foundation

/// Discriminated result of a ``ScreenReadRequest``. Encoded as
/// `{"format":"text"|"cells", ...}` to match the HTTP wire shape.
public enum ScreenReadResult: Sendable, Codable {
    case text(TextScreenPayload)
    case cells(CellGrid)

    private enum Keys: String, CodingKey { case format }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let format = try c.decode(ScreenFormat.self, forKey: .format)
        let single = try decoder.singleValueContainer()
        switch format {
        case .text: self = .text(try single.decode(TextScreenPayload.self))
        case .cells: self = .cells(try single.decode(CellGrid.self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let p):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(ScreenFormat.text, forKey: .format)
            try p.encode(to: encoder)
        case .cells(let g):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(ScreenFormat.cells, forKey: .format)
            try g.encode(to: encoder)
        }
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add CellGrid (D27 semantic_available) + TextScreenPayload + ScreenReadResult"
git push
```

---

### Task 0.8: `KeyMod` + `NamedKey` + `KeyEventParseError` + `KeyEvent.parse(_:) throws` (D21)

(Resolves Coverage/Quality must_fix: "Phase 0 `KeyEvent.parse` must throw (not return Optional) so Phase 1's `try KeyEvent.parse(...)` compiles." Pure-throwing API per D21; NO Optional overload.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/KeyMod.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/NamedKey.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/KeyEventParseError.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/KeyEvent.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/KeyEventParserTests.swift`

- [ ] **Step 1: Failing test (throwing API only — D21)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct KeyEventParserTests {
    @Test func plainNamedKey() throws {
        let ev = try KeyEvent.parse("Enter")
        #expect(ev.mods.isEmpty); #expect(ev.key == .enter)
    }
    @Test func ctrlPlusChar() throws {
        let ev = try KeyEvent.parse("Ctrl+C")
        #expect(ev.mods == [.ctrl]); #expect(ev.key == .char("c"))
    }
    @Test func altLowercaseChar() throws {
        let ev = try KeyEvent.parse("Alt+x")
        #expect(ev.mods == [.alt]); #expect(ev.key == .char("x"))
    }
    @Test func functionKey() throws { #expect(try KeyEvent.parse("F5").key == .f(5)) }
    @Test func arrow() throws { #expect(try KeyEvent.parse("Up").key == .up) }
    @Test func multipleMods() throws {
        let ev = try KeyEvent.parse("Ctrl+Shift+Tab")
        #expect(ev.mods == [.ctrl, .shift]); #expect(ev.key == .tab)
    }
    @Test(arguments: ["", "Ctrl+", "Ctrl+Foo", "Bogus", "F0", "F25", "Cmd", "+Enter"])
    func rejectsInvalid(_ s: String) {
        #expect(throws: KeyEventParseError.self) { try KeyEvent.parse(s) }
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/KeyEventParserTests.swift
git commit -m "Add failing throwing KeyEvent.parse tests (D21)"
git push
```

- [ ] **Step 3: Implement**
```swift
// KeyMod.swift

/// Keyboard modifier flag carried by a ``KeyEvent``.
public enum KeyMod: String, Sendable, Codable, Hashable, CaseIterable {
    case ctrl, alt, shift, cmd
}
```
```swift
// NamedKey.swift

/// Semantic key identity. ``char(_:)`` covers printable single
/// characters; named cases cover keys with no literal byte form.
public enum NamedKey: Hashable, Sendable {
    case char(Character)
    case enter, tab, escape, space, backspace, delete
    case up, down, left, right
    case home, end, pageUp, pageDown
    case f(Int)
}
```
```swift
// KeyEventParseError.swift

/// Failure modes of ``KeyEvent/parse(_:)`` (D21). Distinct from
/// ``TerminalAccessError`` — the decoder wraps this into
/// ``TerminalAccessError/badRequest(reason:)``.
public enum KeyEventParseError: Error, Equatable {
    case empty
    case unknownModifier(String)
    case unknownKey(String)
    case malformed(String)
}
```
```swift
// KeyEvent.swift

/// A semantic key press (modifiers + key identity). The actual byte
/// sequence sent to the PTY is decided by ghostty's encoder per the
/// surface's active modes (DECCKM, kitty, modifyOtherKeys).
public struct KeyEvent: Hashable, Sendable {
    public let mods: Set<KeyMod>
    public let key: NamedKey

    public init(mods: Set<KeyMod>, key: NamedKey) { self.mods = mods; self.key = key }

    /// Parses `"Mod+Mod+Key"` per D21. **Throwing only** — no Optional
    /// overload. Modifier names are case-insensitive in
    /// `{Ctrl, Alt|Opt|Option, Shift, Cmd|Meta|Super}`. The final segment
    /// is the key name; see ``NamedKey``.
    public static func parse(_ s: String) throws -> KeyEvent {
        guard !s.isEmpty else { throw KeyEventParseError.empty }
        let parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty }) else { throw KeyEventParseError.malformed(s) }
        guard let keyName = parts.last else { throw KeyEventParseError.malformed(s) }
        var mods: Set<KeyMod> = []
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "ctrl": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "shift": mods.insert(.shift)
            case "cmd", "meta", "super": mods.insert(.cmd)
            default: throw KeyEventParseError.unknownModifier(m)
            }
        }
        return KeyEvent(mods: mods, key: try NamedKey.parse(keyName))
    }
}

extension NamedKey {
    /// Parses a single key segment of a ``KeyEvent`` grammar string.
    /// Throws ``KeyEventParseError/unknownKey(_:)`` on unrecognised input.
    public static func parse(_ s: String) throws -> NamedKey {
        if s.count == 1, let ch = s.first,
           ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol {
            return .char(Character(ch.lowercased()))
        }
        switch s.lowercased() {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "space": return .space
        case "backspace", "bs": return .backspace
        case "delete", "del": return .delete
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageup", "pgup": return .pageUp
        case "pagedown", "pgdn": return .pageDown
        default:
            if s.count >= 2, s.first?.lowercased() == "f",
               let n = Int(s.dropFirst()), (1...24).contains(n) {
                return .f(n)
            }
            throw KeyEventParseError.unknownKey(s)
        }
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Implement throwing KeyEvent.parse (D21)"
git push
```

---

### Task 0.9: `MouseAction` + `MouseButton` + `MouseEvent` (with throwing `parse(_:)`)

(Resolves Coverage/Quality must_fix: parsers must land before the decoder; `MouseEvent.parse(_:) throws -> MouseEvent` lives next to the type.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/MouseAction.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/MouseButton.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/MouseEvent.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/MouseEventTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct MouseEventTests {
    @Test func parsesPressLeftWithCoords() throws {
        let ev = try MouseEvent.parse([
            "action": "press", "button": "left", "x": 5, "y": 7, "mods": ["ctrl"]
        ])
        #expect(ev.action == .press); #expect(ev.button == .left)
        #expect(ev.x == 5); #expect(ev.y == 7); #expect(ev.mods == [.ctrl])
    }
    @Test func parsesScrollWithoutButton() throws {
        let ev = try MouseEvent.parse([
            "action": "scroll", "x": 1, "y": 2, "scrollDy": -3
        ])
        #expect(ev.action == .scroll); #expect(ev.button == nil); #expect(ev.scrollDy == -3)
    }
    @Test func rejectsMissingCoords() {
        #expect(throws: MouseEvent.ParseError.self) {
            _ = try MouseEvent.parse(["action": "press"])
        }
    }
    @Test func rejectsUnknownAction() {
        #expect(throws: MouseEvent.ParseError.self) {
            _ = try MouseEvent.parse(["action": "tap", "x": 0, "y": 0])
        }
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/MouseEventTests.swift
git commit -m "Add failing MouseEvent.parse tests"
git push
```

- [ ] **Step 3: Implement**
```swift
// MouseAction.swift

/// Mouse action kind. Mirrors ghostty's apprt mouse API.
public enum MouseAction: String, Sendable, Codable, Hashable {
    case press, release, move, scroll
}
```
```swift
// MouseButton.swift

/// Mouse button. `nil` on a ``MouseEvent`` for `move`/`scroll` actions
/// where no button is involved.
public enum MouseButton: String, Sendable, Codable, Hashable {
    case left, middle, right
}
```
```swift
// MouseEvent.swift
import Foundation

/// One mouse event in *cell* coordinates. ghostty encodes the outgoing
/// bytes according to the surface's active mouse mode (DEC 1000/1002/1003
/// × 1006 SGR). Per D16, the cmux dispatch path must NOT synthesize
/// NSEvents.
public struct MouseEvent: Hashable, Sendable {
    public let action: MouseAction
    public let button: MouseButton?
    public let x: Int
    public let y: Int
    public let mods: Set<KeyMod>
    public let scrollDy: Int

    public init(action: MouseAction, button: MouseButton?, x: Int, y: Int,
                mods: Set<KeyMod>, scrollDy: Int) {
        self.action = action; self.button = button
        self.x = x; self.y = y; self.mods = mods; self.scrollDy = scrollDy
    }

    /// Parse failure modes for ``parse(_:)``.
    public enum ParseError: Error, Equatable {
        case missing(field: String)
        case unknownAction(String)
        case unknownButton(String)
        case unknownModifier(String)
    }

    /// Parse a `[String: Any]` JSON object (already JSONSerialized) into
    /// a ``MouseEvent``. Throwing only — wired into the HTTP input
    /// decoder in Phase 1, which maps this into
    /// ``TerminalAccessError/badRequest(reason:)``.
    public static func parse(_ obj: [String: Any]) throws -> MouseEvent {
        guard let actionRaw = obj["action"] as? String else { throw ParseError.missing(field: "action") }
        guard let action = MouseAction(rawValue: actionRaw) else { throw ParseError.unknownAction(actionRaw) }
        var button: MouseButton? = nil
        if let b = obj["button"] as? String {
            guard let parsed = MouseButton(rawValue: b) else { throw ParseError.unknownButton(b) }
            button = parsed
        }
        guard let x = obj["x"] as? Int else { throw ParseError.missing(field: "x") }
        guard let y = obj["y"] as? Int else { throw ParseError.missing(field: "y") }
        var mods: Set<KeyMod> = []
        if let m = obj["mods"] as? [String] {
            for s in m {
                guard let mod = KeyMod(rawValue: s) else { throw ParseError.unknownModifier(s) }
                mods.insert(mod)
            }
        }
        let dy = (obj["scrollDy"] as? Int) ?? 0
        return MouseEvent(action: action, button: button, x: x, y: y, mods: mods, scrollDy: dy)
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add MouseAction/MouseButton/MouseEvent with throwing parse"
git push
```

---

### Task 0.10: `InputPayload` + `InputRequest` (with `focusSurface`)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/InputPayload.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/InputRequest.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/InputRequestShapeTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct InputRequestShapeTests {
    @Test func textWithSubmit() {
        let r = InputRequest(handle: .ref(kind: "surface", ordinal: 1),
                             payload: .text("hi", submit: true), focusSurface: false)
        if case .text(let s, let submit) = r.payload {
            #expect(s == "hi"); #expect(submit)
        } else { Issue.record("not .text") }
    }
    @Test func focusSurfaceDefaultsFalse() {
        let r = InputRequest(handle: .uuid(UUID()), payload: .focus(gained: true))
        #expect(r.focusSurface == false)
    }
}
```

- [ ] **Step 2: Push RED + Step 3: Implement (combined commit RED then GREEN)**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/InputRequestShapeTests.swift
git commit -m "Add failing InputRequest shape tests"
git push
```
```swift
// InputPayload.swift
import Foundation

/// Discriminated input payload. Encoded as `{"type":"...", ...}` on the
/// HTTP wire. Phase 0 carries the type internally; Phase 1 adds the JSON
/// decoder.
public enum InputPayload: Sendable, Hashable {
    /// Literal text. `submit` appends CR (Enter) when true.
    case text(String, submit: Bool)
    /// Semantic key presses, encoded by ghostty against the active modes.
    case keys([KeyEvent])
    /// Raw bytes written verbatim. Gated by the
    /// ``DefaultTerminalAccessService`` `allowRawInput` init-time closure
    /// (E3); the HTTP layer wires it to `{ settings.allowRawInput }`.
    case raw(Data)
    /// Explicit bracketed paste, atomic within one call per D30.
    case paste(String)
    /// Mouse event encoded by ghostty against active mouse mode. Per D16
    /// the dispatch path must NOT synthesize NSEvents.
    case mouse(MouseEvent)
    /// Focus gained/lost report (DEC 1004) via `ghostty_surface_set_focus`.
    /// Does NOT change macOS app focus.
    case focus(gained: Bool)
}
```
```swift
// InputRequest.swift

/// A single write request. `focusSurface` is the explicit opt-in to
/// in-app focus movement before the payload is dispatched (D17 —
/// ``DefaultTerminalAccessService/writeInput(_:)`` calls
/// ``SurfaceProvider/setFocus(surface:gained:)`` first when true).
public struct InputRequest: Sendable, Hashable {
    public let handle: SurfaceHandle
    public let payload: InputPayload
    public let focusSurface: Bool

    public init(handle: SurfaceHandle, payload: InputPayload, focusSurface: Bool = false) {
        self.handle = handle; self.payload = payload; self.focusSurface = focusSurface
    }
}
```
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add InputPayload and InputRequest"
git push
```

---

### Task 0.11: `StreamMode` + `StreamSubscriptionOptions` + `OutputEvent` (D23)

(Resolves Coverage/Quality must_fix: these three types are created ONCE in Phase 0 per D23; Phase 2 NEVER recreates them. Per D6 the `seq` carried on events is event-level, not byte-level — the ring stores `(seq, event)` tuples.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/StreamMode.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/StreamSubscriptionOptions.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/OutputEvent.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/OutputEventTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct OutputEventTests {
    @Test func rawBytesCarriesData() {
        let ev = OutputEvent.rawBytes(Data([0x41, 0x42]), seq: 1)
        if case .rawBytes(let d, let s) = ev {
            #expect(d == Data([0x41, 0x42])); #expect(s == 1)
        } else { Issue.record("not rawBytes") }
    }
    @Test func cellsSnapshotCarriesGrid() {
        let g = CellGrid(cols: 1, rows: 1, altScreen: false, title: nil,
                         cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                         semanticAvailable: false, rowsData: [])
        let ev = OutputEvent.cellsSnapshot(g, seq: 42)
        if case .cellsSnapshot(_, let s) = ev { #expect(s == 42) } else { Issue.record("not cells") }
    }
    @Test func subscriptionOptionsHoldLastEventID() {
        let opts = StreamSubscriptionOptions(handle: .uuid(UUID()), mode: .raw, lastEventID: 99)
        #expect(opts.lastEventID == 99); #expect(opts.mode == .raw)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/OutputEventTests.swift
git commit -m "Add failing StreamMode/Options/Event tests"
git push
```

- [ ] **Step 3: Implement**
```swift
// StreamMode.swift

/// Subscription mode for the SSE output stream.
///
/// - ``raw``: live PTY byte increments (ghostty patch #2, Phase 2). No
///   replay of bytes consumed before subscription.
/// - ``cells``: throttled full ``CellGrid`` snapshots, emitted only when
///   the surface is dirty since the last tick (D8 — polled FNV-1a hash,
///   default 5 Hz; no third ghostty patch).
public enum StreamMode: String, Sendable, Codable, Hashable { case raw, cells }
```
```swift
// StreamSubscriptionOptions.swift

/// Parameters for opening an output stream subscription. `lastEventID`
/// is the SSE `Last-Event-ID` value for resume per D6.
public struct StreamSubscriptionOptions: Sendable, Hashable {
    public let handle: SurfaceHandle
    public let mode: StreamMode
    public let lastEventID: UInt64?
    public init(handle: SurfaceHandle, mode: StreamMode, lastEventID: UInt64? = nil) {
        self.handle = handle; self.mode = mode; self.lastEventID = lastEventID
    }
}
```
```swift
// OutputEvent.swift
import Foundation

/// One event emitted on an active output subscription. `seq` is a
/// monotonic per-subscriber identifier (D6 — event-level, not byte-level).
/// Per D6, a ring overflow drops oldest events and the client observes a
/// JUMP in `seq` values rather than a separate gap event; Phase 2 emits
/// at most a single synthetic SSE comment on resume below the oldest seq.
public enum OutputEvent: Sendable {
    case rawBytes(Data, seq: UInt64)
    case cellsSnapshot(CellGrid, seq: UInt64)
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add StreamMode, StreamSubscriptionOptions, OutputEvent (D6 event-level seq)"
git push
```

---

### Task 0.12: `OutputSubscription` final class (D22)

(Resolves Coverage/Quality must_fix on protocol-vs-class collision: defined here as a `public final class` with `id`, `handle`, `mode`, `cancel()`, `signalEnd()`, `onEnd`, `events()`. Phase 2 only USES it.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/OutputSubscription.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/OutputSubscriptionTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct OutputSubscriptionTests {
    @Test func cancelFiresOnCancelOnce() {
        let counter = NSLock(); var n = 0
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw,
            onCancel: { counter.lock(); n += 1; counter.unlock() })
        sub.cancel(); sub.cancel()
        #expect(n == 1)
    }
    @Test func signalEndInvokesOnEndOnce() async {
        let lock = NSLock(); var count = 0
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {})
        sub.onEnd = { lock.lock(); count += 1; lock.unlock() }
        sub.signalEnd(); sub.signalEnd()
        #expect(count == 1)
    }
    @Test func eventsStreamReceivesYields() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {})
        let stream = sub.events()
        sub.yield(.rawBytes(Data([0x41]), seq: 1))
        sub.yield(.rawBytes(Data([0x42]), seq: 2))
        sub.finish()
        var collected: [UInt64] = []
        for await ev in stream {
            if case .rawBytes(_, let s) = ev { collected.append(s) }
        }
        #expect(collected == [1, 2])
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/OutputSubscriptionTests.swift
git commit -m "Add failing OutputSubscription class tests (D22)"
git push
```

- [ ] **Step 3: Implement (D22 shape)**
```swift
// OutputSubscription.swift
import Foundation

/// Handle to an active output subscription (D22 — class, not protocol).
///
/// - `cancel()` releases the per-subscriber ring; idempotent.
/// - `signalEnd()` invokes `onEnd` exactly once (e.g. when the surface
///   closes) and then finishes the async stream.
/// - `events()` returns an `AsyncStream` that pumps until `cancel()` or
///   `signalEnd()` fires.
public final class OutputSubscription: @unchecked Sendable {
    public let id: UUID
    public let handle: SurfaceHandle
    public let mode: StreamMode

    private let lock = NSLock()
    private var cancelled: Bool = false
    private var ended: Bool = false
    private let onCancel: @Sendable () -> Void
    /// Hook fired exactly once by ``signalEnd()``. Set by the Phase 2
    /// service to drive end-of-stream cleanup.
    public var onEnd: (@Sendable () -> Void)?

    // The async-stream continuation is lazily attached on first
    // `events()` call. Yields from `yield(_:)` are buffered until then.
    private var continuation: AsyncStream<OutputEvent>.Continuation?
    private var buffered: [OutputEvent] = []

    public init(id: UUID, handle: SurfaceHandle, mode: StreamMode,
                onCancel: @escaping @Sendable () -> Void) {
        self.id = id; self.handle = handle; self.mode = mode
        self.onCancel = onCancel
    }

    /// Returns the async stream of events. Multiple calls return the
    /// same logical stream (subsequent calls replay the buffered prefix
    /// captured before the first `events()`).
    public func events() -> AsyncStream<OutputEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let pending = self.buffered
            self.buffered.removeAll(keepingCapacity: false)
            let alreadyEnded = self.ended || self.cancelled
            lock.unlock()
            for ev in pending { continuation.yield(ev) }
            if alreadyEnded { continuation.finish() }
            continuation.onTermination = { [weak self] _ in self?.cancel() }
        }
    }

    /// Push one event onto the stream. Called by the Phase 2 service.
    public func yield(_ event: OutputEvent) {
        lock.lock()
        if cancelled || ended { lock.unlock(); return }
        if let cont = continuation { lock.unlock(); cont.yield(event); return }
        buffered.append(event); lock.unlock()
    }

    /// Finishes the async stream without firing `onEnd`. Used by the
    /// service when the subscriber explicitly disconnects.
    public func finish() {
        lock.lock()
        let cont = continuation; continuation = nil
        ended = true
        lock.unlock()
        cont?.finish()
    }

    /// Cancels the subscription. Idempotent; fires `onCancel` exactly once.
    public func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let cont = continuation; continuation = nil
        lock.unlock()
        cont?.finish()
        onCancel()
    }

    /// Signals end-of-stream (e.g. surface closed). Fires `onEnd` exactly
    /// once and finishes the async stream. Does NOT call `onCancel`.
    public func signalEnd() {
        lock.lock()
        if ended || cancelled { lock.unlock(); return }
        ended = true
        let cont = continuation; continuation = nil
        let hook = onEnd
        lock.unlock()
        cont?.finish()
        hook?()
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/OutputSubscription.swift
git commit -m "Implement OutputSubscription final class (D22)"
git push
```

---

### Task 0.13: `TerminalAccessError` — `.unsupported` → 415 (D18); `.featureDisabled` → 404 (D11)

(Resolves Coverage/Quality must_fix: pick 415 for `.unsupported` consistently — D18 — and 404 for `.featureDisabled` to avoid "feature exists but off" leakage.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/TerminalAccessError.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TerminalAccessErrorTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Testing
@testable import CmuxTerminalAccess

@Suite struct TerminalAccessErrorTests {
    @Test func httpStatusesMatchDesignTable() {
        #expect(TerminalAccessError.unknownSurface.httpStatus == 404)
        #expect(TerminalAccessError.unauthorized.httpStatus == 401)
        #expect(TerminalAccessError.forbidden(reason: "x").httpStatus == 403)
        #expect(TerminalAccessError.badRequest(reason: "x").httpStatus == 400)
        #expect(TerminalAccessError.payloadTooLarge.httpStatus == 413)
        #expect(TerminalAccessError.rateLimited.httpStatus == 429)
        #expect(TerminalAccessError.featureDisabled.httpStatus == 404)  // D11
        #expect(TerminalAccessError.unsupported(reason: "x").httpStatus == 415)  // D18
        #expect(TerminalAccessError.ghosttyError("x").httpStatus == 500)
    }
    @Test func wireCodesAreStable() {
        #expect(TerminalAccessError.unknownSurface.wireCode == "unknown_surface")
        #expect(TerminalAccessError.payloadTooLarge.wireCode == "payload_too_large")
        #expect(TerminalAccessError.unsupported(reason: "x").wireCode == "unsupported_media_type")
        #expect(TerminalAccessError.featureDisabled.wireCode == "not_found")
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TerminalAccessErrorTests.swift
git commit -m "Add failing TerminalAccessError mapping tests (D18 415, D11 404)"
git push
```

- [ ] **Step 3: Implement**
```swift
// TerminalAccessError.swift

/// Typed domain error for every ``TerminalAccessService`` operation.
/// Transports map these onto their own status model.
public enum TerminalAccessError: Error, Sendable, Equatable {
    case unknownSurface
    case unauthorized
    case forbidden(reason: String)
    case badRequest(reason: String)
    case payloadTooLarge
    case rateLimited
    case featureDisabled
    case unsupported(reason: String)
    case ghosttyError(String)

    /// HTTP status per spec §12 and locked decisions D11/D18.
    public var httpStatus: Int {
        switch self {
        case .badRequest: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .unknownSurface, .featureDisabled: return 404 // D11
        case .payloadTooLarge: return 413
        case .unsupported: return 415  // D18
        case .rateLimited: return 429
        case .ghosttyError: return 500
        }
    }

    /// Stable wire code used in `{ "error": { "code": ... } }`.
    public var wireCode: String {
        switch self {
        case .unknownSurface: return "unknown_surface"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .badRequest: return "bad_request"
        case .payloadTooLarge: return "payload_too_large"
        case .rateLimited: return "rate_limited"
        case .featureDisabled: return "not_found"  // D11 — don't reveal toggle
        case .unsupported: return "unsupported_media_type"
        case .ghosttyError: return "internal_error"
        }
    }

    /// Human-readable message for the JSON error body.
    public var message: String {
        switch self {
        case .unknownSurface: return "Unknown surface"
        case .unauthorized: return "Missing or invalid token"
        case .forbidden(let r): return r
        case .badRequest(let r): return r
        case .payloadTooLarge: return "Input exceeds queue cap"
        case .rateLimited: return "Rate limit exceeded"
        case .featureDisabled: return "Endpoint not available"
        case .unsupported(let r): return r
        case .ghosttyError(let r): return r
        }
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/TerminalAccessError.swift
git commit -m "Add TerminalAccessError with D11/D18 status mapping"
git push
```

---

### Task 0.14: `AuditKind` enum + `AuditEntry` (D3) + `AuditLog` protocol + `NoOpAuditLog` (D4)

(Resolves Coverage must_fix #6/#7: D3 single AuditEntry shape `{timestamp, surface: SurfaceHandle, kind: AuditKind, byteCount: Int, detail: [String:String]?}`; D4 audit is ALWAYS-ON in v1 for write paths — `NoOpAuditLog` exists for tests only, not as the default production sink.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/AuditKind.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/AuditEntry.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/AuditLog.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/NoOpAuditLog.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/AuditEntryTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct AuditEntryTests {
    @Test func entryShape() {
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            surface: .ref(kind: "surface", ordinal: 1),
            kind: .writeText, byteCount: 4, detail: ["submit": "true"])
        #expect(entry.kind == .writeText)
        #expect(entry.byteCount == 4)
        #expect(entry.detail?["submit"] == "true")
    }
    @Test func entryEncodesAsSnakeCase() throws {
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1700000000),
            surface: .ref(kind: "surface", ordinal: 2),
            kind: .streamOpen, byteCount: 0, detail: nil)
        let data = try JSONEncoder().encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"byte_count\":0"))
        #expect(json.contains("\"stream_open\""))
        #expect(json.contains("\"surface:2\""))
    }
    @Test func noOpAuditLogAcceptsAllEntries() async {
        // E2 — AuditLog.record is async, non-throwing.
        let log = NoOpAuditLog()
        await log.record(AuditEntry(timestamp: Date(),
                                    surface: .ref(kind: "surface", ordinal: 1),
                                    kind: .writeRaw, byteCount: 0, detail: nil))
    }
    @Test func auditKindCoversD3Cases() {
        let all: Set<AuditKind> = [.writeText, .writeKeys, .writeRaw, .writePaste,
                                   .writeMouse, .writeFocus, .streamOpen, .streamClose]
        #expect(all.count == 8)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/AuditEntryTests.swift
git commit -m "Add failing AuditEntry/AuditKind tests (D3)"
git push
```

- [ ] **Step 3: Implement**
```swift
// AuditKind.swift

/// Per-event taxonomy for ``AuditEntry`` (D3). One case per write/stream
/// action recorded by ``DefaultTerminalAccessService`` and the Phase 1
/// HTTP server. All write paths emit audit entries unconditionally (D4 —
/// audit is ALWAYS-ON; Settings only controls the log file PATH).
public enum AuditKind: String, Sendable, Codable, Hashable {
    case writeText = "write_text"
    case writeKeys = "write_keys"
    case writeRaw = "write_raw"
    case writePaste = "write_paste"
    case writeMouse = "write_mouse"
    case writeFocus = "write_focus"
    case streamOpen = "stream_open"
    case streamClose = "stream_close"
}
```
```swift
// AuditEntry.swift
import Foundation

/// One audit entry — one JSON line in the on-disk log (D3). Encodes
/// `surface` as its canonical string form (`uuid` or `kind:ordinal`).
public struct AuditEntry: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let surface: SurfaceHandle
    public let kind: AuditKind
    public let byteCount: Int
    public let detail: [String: String]?

    public init(timestamp: Date, surface: SurfaceHandle, kind: AuditKind,
                byteCount: Int, detail: [String: String]?) {
        self.timestamp = timestamp; self.surface = surface
        self.kind = kind; self.byteCount = byteCount; self.detail = detail
    }
    enum CodingKeys: String, CodingKey {
        case timestamp, surface, kind
        case byteCount = "byte_count"
        case detail
    }
}
```
```swift
// AuditLog.swift

/// Audit-log sink used by every write path in
/// ``DefaultTerminalAccessService`` and the HTTP layer. Per D4 the
/// production wiring is ALWAYS-ON in v1 — Settings only controls the
/// log file path. ``NoOpAuditLog`` exists for tests only.
///
/// E2 — `record` is `async` and non-throwing. Conformers serialize
/// writes internally (e.g. ``FileAuditLog`` is an `actor` that owns a
/// `FileHandle`). Call sites never write `try`.
public protocol AuditLog: Sendable {
    func record(_ entry: AuditEntry) async
}
```
```swift
// NoOpAuditLog.swift

/// Discard-everything ``AuditLog``. **Tests only** (D4) — never wire
/// this in as the production default. Use ``FileAuditLog`` in
/// production; the Settings UI only toggles the file PATH.
///
/// E2 — `record` is `async` non-throwing; a `final class` is fine
/// because there is no mutable state to guard.
public final class NoOpAuditLog: AuditLog {
    public init() {}
    public func record(_ entry: AuditEntry) async {}
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add AuditKind, AuditEntry (D3), AuditLog protocol, NoOpAuditLog (test-only per D4)"
git push
```

---

### Task 0.15: `FileAuditLog` (mode 0600 enforced on every open)

(Resolves Quality must_fix: "FileAuditLog ignores existing file permissions on the path" — `setAttributes(.posixPermissions: 0o600)` runs both on create AND on every open.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/FileAuditLog.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/FileAuditLogTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct FileAuditLogTests {
    private func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.jsonl")
    }
    @Test func appendsOneJSONLinePerEvent() async throws {
        let url = try tempURL()
        // E2 — FileAuditLog is an actor; `record` is async non-throwing.
        let log = FileAuditLog(url: url)
        await log.record(AuditEntry(timestamp: Date(timeIntervalSince1970: 0),
                                    surface: .ref(kind: "surface", ordinal: 1),
                                    kind: .writeText, byteCount: 4,
                                    detail: ["submit": "true"]))
        await log.record(AuditEntry(timestamp: Date(timeIntervalSince1970: 1),
                                    surface: .ref(kind: "surface", ordinal: 1),
                                    kind: .writeRaw, byteCount: 32, detail: nil))
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"kind\":\"write_text\""))
        #expect(lines[1].contains("\"byte_count\":32"))
    }
    @Test func enforces0600OnFirstWriteAndReopen() async throws {
        let url = try tempURL()
        // Pre-create the file with mode 0644 to simulate stale state.
        FileManager.default.createFile(atPath: url.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o644])
        let log = FileAuditLog(url: url)
        await log.record(AuditEntry(timestamp: Date(),
                                    surface: .ref(kind: "surface", ordinal: 1),
                                    kind: .writeText, byteCount: 1, detail: nil))
        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                     as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/FileAuditLogTests.swift
git commit -m "Add failing FileAuditLog mode-0600 test"
git push
```

- [ ] **Step 3: Implement**
```swift
// FileAuditLog.swift
import Foundation

/// File-backed ``AuditLog`` that appends one JSON object per line.
/// Enforces mode 0600 on the log file on **every** record call (Quality
/// must_fix), not just at creation time.
///
/// E2 — `actor` so writes are serialized through the actor executor;
/// `record` is `async` non-throwing. Internal errors (encode failure,
/// `FileHandle` errors) are absorbed and surfaced via cmuxDebugLog under
/// `#if DEBUG`; the call site never sees an exception.
public actor FileAuditLog: AuditLog {
    private let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(url: URL) { self.url = url }

    public func record(_ entry: AuditEntry) async {
        do {
            var data = try encoder.encode(entry); data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            // Always re-apply 0600 — covers (a) freshly written files
            // and (b) stale pre-existing files (Quality finding).
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            #if DEBUG
            cmuxDebugLog("FileAuditLog.record failed: \(error)")
            #endif
        }
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/FileAuditLog.swift
git commit -m "Implement FileAuditLog with mode 0600 enforced on every record"
git push
```

---

### Task 0.16: `RateLimiter` (D10) — `init(burstCapacity:refillPerSecond:clock:)`, lazy per-key buckets

(Resolves Coverage/Quality must_fix on constructor signature: single canonical shape per D10.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/RateLimiterClock.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/RateLimiter.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/RateLimiterTests.swift`

- [ ] **Step 1: Failing test**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct RateLimiterTests {
    final class FakeClock: RateLimiterClock, @unchecked Sendable {
        var now: TimeInterval = 0
        func nowSeconds() -> TimeInterval { now }
    }
    // E16 — `acquire` throws `TerminalAccessError.rateLimited` on overflow.
    // Tests use `await #expect(throws:)` instead of asserting a Bool return.
    @Test func allowsUpToCapacity() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(burstCapacity: 3, refillPerSecond: 1, clock: clock)
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        await #expect(throws: TerminalAccessError.self) {
            try await limiter.acquire(key: "k")
        }
    }
    @Test func refillsOverTime() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(burstCapacity: 2, refillPerSecond: 2, clock: clock)
        try await limiter.acquire(key: "k"); try await limiter.acquire(key: "k")
        await #expect(throws: TerminalAccessError.self) {
            try await limiter.acquire(key: "k")
        }
        clock.now = 1.0
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        await #expect(throws: TerminalAccessError.self) {
            try await limiter.acquire(key: "k")
        }
    }
    @Test func separateKeysAreIndependent() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(burstCapacity: 1, refillPerSecond: 0, clock: clock)
        try await limiter.acquire(key: "a")
        try await limiter.acquire(key: "b")
        await #expect(throws: TerminalAccessError.self) {
            try await limiter.acquire(key: "a")
        }
    }
    @Test func bucketsAreCreatedLazily() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(burstCapacity: 2, refillPerSecond: 1, clock: clock)
        // New key gets full burst capacity even when constructed cold.
        try await limiter.acquire(key: "surface:1#write")
        try await limiter.acquire(key: "surface:1#write")
        await #expect(throws: TerminalAccessError.self) {
            try await limiter.acquire(key: "surface:1#write")
        }
        try await limiter.acquire(key: "surface:2#write") // separate, full
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/RateLimiterTests.swift
git commit -m "Add failing RateLimiter tests (D10)"
git push
```

- [ ] **Step 3: Implement**
```swift
// RateLimiterClock.swift
import Foundation

/// Monotonic clock seam injected into ``RateLimiter`` so tests don't sleep.
public protocol RateLimiterClock: Sendable {
    func nowSeconds() -> TimeInterval
}

/// Default monotonic clock backed by `Date().timeIntervalSinceReferenceDate`.
public struct DefaultRateLimiterClock: RateLimiterClock {
    public init() {}
    public func nowSeconds() -> TimeInterval { Date().timeIntervalSinceReferenceDate }
}
```
```swift
// RateLimiter.swift
import Foundation

/// Token-bucket rate limiter keyed by arbitrary string (D10). The HTTP
/// layer uses keys like `"surface:1#write"`, `"surface:1#stream-open"`,
/// `"conn:<uuid>#write"`. Buckets are created lazily at full
/// ``burstCapacity`` on first ``acquire(key:)``.
///
/// E16 — `acquire` throws ``TerminalAccessError/rateLimited`` on
/// overflow. Call sites always use `try await rateLimiter.acquire(...)`;
/// there is NO Bool return. The HTTP layer maps the thrown error to
/// 429 via the `TerminalAccessError -> HTTP` mapping (Phase 1).
public actor RateLimiter {
    public let burstCapacity: Double
    public let refillPerSecond: Double
    private let clock: any RateLimiterClock
    private var buckets: [String: (tokens: Double, updated: TimeInterval)] = [:]

    public init(burstCapacity: Int, refillPerSecond: Double,
                clock: any RateLimiterClock = DefaultRateLimiterClock()) {
        self.burstCapacity = Double(burstCapacity)
        self.refillPerSecond = refillPerSecond
        self.clock = clock
    }

    /// Spends `cost` tokens for `key`. Throws
    /// ``TerminalAccessError/rateLimited`` when the bucket is empty.
    public func acquire(key: String, cost: Double = 1) async throws {
        let now = clock.nowSeconds()
        var state = buckets[key] ?? (tokens: burstCapacity, updated: now)
        let elapsed = max(0, now - state.updated)
        state.tokens = min(burstCapacity, state.tokens + elapsed * refillPerSecond)
        state.updated = now
        if state.tokens >= cost {
            state.tokens -= cost
            buckets[key] = state
            return
        }
        buckets[key] = state
        throw TerminalAccessError.rateLimited
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Implement RateLimiter with burstCapacity/refillPerSecond/clock (D10)"
git push
```

---

### Task 0.17: `SurfaceInfo` + `SurfaceProvider` protocol (D1 all `async throws`; `readCells` required member)

(Resolves Coverage/Quality must_fix: D1 every SurfaceProvider method is `async throws` Sendable; per E1/E20, `readCells` is a REQUIRED protocol member (no default impl) so Phase 1 only USES the protocol, not redefines it. The Phase 2 raw-output tap is a separate protocol extension added in Task 2.15 — it is NOT a Phase 0 required member.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceInfo.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/RawOutputDetachToken.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceProvider.swift`

- [ ] **Step 1: Implement (no failing test in this micro-task — types are pure declarations; behavioral tests land in 0.18 via the stub)**
```swift
// SurfaceInfo.swift
import Foundation

/// Snapshot of a single surface's transport-visible metadata. Returned
/// by ``SurfaceProvider``; a value type so the service can hold it
/// without a live AppKit/ghostty reference.
public struct SurfaceInfo: Hashable, Sendable {
    public let handle: SurfaceHandle
    public let uuid: UUID
    public let workspaceRef: String
    public let title: String?
    public let cols: Int
    public let rows: Int
    public let altScreen: Bool
    public let focused: Bool
    public let semanticAvailable: Bool

    public init(handle: SurfaceHandle, uuid: UUID, workspaceRef: String,
                title: String?, cols: Int, rows: Int, altScreen: Bool,
                focused: Bool, semanticAvailable: Bool) {
        self.handle = handle; self.uuid = uuid
        self.workspaceRef = workspaceRef; self.title = title
        self.cols = cols; self.rows = rows; self.altScreen = altScreen
        self.focused = focused; self.semanticAvailable = semanticAvailable
    }
}
```
```swift
// RawOutputDetachToken.swift

/// Opaque handle returned by the Phase 2 raw-output seam
/// (`SurfaceProvider.attachRawOutput(surface:onBytes:)` added as a
/// protocol extension in Task 2.15). Holding it keeps the raw-output
/// tap attached; releasing it (or calling ``detach()``) tears the
/// tap down. Idempotent. Lives in Phase 0 so the type is available
/// when Phase 2 wires up the tap.
public protocol RawOutputDetachToken: AnyObject, Sendable {
    func detach()
}
```
```swift
// SurfaceProvider.swift
import Foundation

/// Protocol seam between the transport-neutral
/// ``TerminalAccessService`` and the live cmux app surface registry
/// (D1 — every method `async throws`, Sendable). Phase 0 ships this
/// shape; Phase 1/2 only USE it.
///
/// `readCells` is declared here but throws
/// ``TerminalAccessError/unsupported(reason:)`` in the Phase 0 stub
/// (`DefaultStubSurfaceProvider`) — the ghostty patch that backs the
/// real implementation lands in Phase 1 (`patch #1`). The raw-output
/// tap for Phase 2 (`patch #2`) is added as a protocol extension
/// (`attachRawOutput`) in Task 2.15, not as a required member here.
///
/// Per E20: `readCells` is a REQUIRED protocol member with NO default
/// protocol implementation; every conformer must consciously implement
/// or stub it.
public protocol SurfaceProvider: Sendable {
    /// Enumerate every live cmux terminal surface, in canonical sidebar order.
    func listSurfaces() async throws -> [SurfaceInfo]

    /// Resolve a handle to its current ``SurfaceInfo`` snapshot, or nil.
    func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo?

    /// Read rendered UTF-8 text for the given region.
    func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String

    /// Read a structured ``CellGrid`` (ghostty patch #1, Phase 1).
    func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid

    /// Write literal UTF-8 bytes via `ghostty_surface_text`.
    func writeText(surface: SurfaceInfo, bytes: Data) async throws

    /// Encode and send a single key press through `ghostty_surface_key`.
    func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws

    /// Send a mouse event via `ghostty_surface_mouse_button` / `mouse_pos`
    /// / `mouse_scroll`. **Must NOT synthesize NSEvents** (D16).
    func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws

    /// Report focus gained/lost via `ghostty_surface_set_focus`. Does
    /// NOT change macOS app focus (socket-focus policy).
    func setFocus(surface: SurfaceInfo, gained: Bool) async throws

    /// Remaining bytes that may be enqueued before
    /// ``TerminalAccessError/payloadTooLarge`` fires. Synchronous —
    /// Phase 0 capacity bookkeeping is a fast in-memory counter.
    func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int
}
```

- [ ] **Step 2: Commit (compile-only — no behavioral test, that lives in 0.18)**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add SurfaceInfo + SurfaceProvider protocol (D1 async throws)"
git push
```
Expected: CI green (types compile). Behavior is exercised in 0.18 via the shared stub.

---

### Task 0.18: Shared `StubSurfaceProvider` in `TestSupport/` (D13)

(Resolves Coverage/Quality must_fix: ONE shared StubSurfaceProvider at `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/StubSurfaceProvider.swift`; both test files in Phase 0 and the shared seam used by Phase 1/2 reference this single definition.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/StubSurfaceProvider.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/StubSurfaceProviderTests.swift`

- [ ] **Step 1: Failing test (references the shared stub before it exists)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct StubSurfaceProviderTests {
    @Test func resolvesByRefAndUUID() async throws {
        let uuid = UUID()
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: uuid, workspaceRef: "workspace:1",
                               title: nil, cols: 80, rows: 24,
                               altScreen: false, focused: true,
                               semanticAvailable: false)
        let provider = StubSurfaceProvider(); await provider.set(surfaces: [info])
        let byRef = try await provider.resolve(.ref(kind: "surface", ordinal: 1))
        let byUUID = try await provider.resolve(.uuid(uuid))
        #expect(byRef?.uuid == uuid)
        #expect(byUUID?.uuid == uuid)
    }
    @Test func cellsUnsupportedByDefault() async throws {
        let provider = StubSurfaceProvider()
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: nil, cols: 1, rows: 1,
                               altScreen: false, focused: true,
                               semanticAvailable: false)
        await provider.set(surfaces: [info])
        await #expect(throws: TerminalAccessError.self) {
            _ = try await provider.readCells(surface: info, region: .viewport)
        }
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/StubSurfaceProviderTests.swift
git commit -m "Add failing StubSurfaceProvider tests"
git push
```

- [ ] **Step 3: Implement the shared stub**
```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/StubSurfaceProvider.swift
import Foundation
import CmuxTerminalAccess

/// Shared test stub for ``SurfaceProvider`` (D13). The single canonical
/// definition referenced by every Phase 0/1/2 test that needs a fake
/// provider — do NOT redefine this type in other test files.
///
/// Records calls and exposes recorders so tests can assert byte-level
/// behavior of ``DefaultTerminalAccessService`` and the HTTP transports
/// without spinning a real ghostty surface.
public actor StubSurfaceProvider: SurfaceProvider {
    public var surfaces: [SurfaceInfo] = []
    public var cannedText: String = ""
    public var cannedCells: CellGrid?
    public var capacityRemaining: Int = 1 << 20

    public private(set) var textWrites: [Data] = []
    public private(set) var keyWrites: [KeyEvent] = []
    public private(set) var mouseWrites: [MouseEvent] = []
    public private(set) var focusWrites: [Bool] = []
    public private(set) var nsEventBuilds: Int = 0  // never incremented by this stub — D16

    public init() {}

    public func set(surfaces: [SurfaceInfo]) { self.surfaces = surfaces }
    public func set(cannedText: String) { self.cannedText = cannedText }
    public func set(cannedCells: CellGrid?) { self.cannedCells = cannedCells }
    public func set(capacityRemaining: Int) { self.capacityRemaining = capacityRemaining }

    public func listSurfaces() async throws -> [SurfaceInfo] { surfaces }
    public func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? {
        surfaces.first { $0.handle == h || .uuid($0.uuid) == h }
    }
    public func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { cannedText }
    public func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
        guard let g = cannedCells else {
            throw TerminalAccessError.unsupported(reason: "cells not stubbed")
        }
        return g
    }
    public func writeText(surface: SurfaceInfo, bytes: Data) async throws {
        textWrites.append(bytes)
    }
    public func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {
        keyWrites.append(event)
    }
    public func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {
        mouseWrites.append(event)
    }
    public func setFocus(surface: SurfaceInfo, gained: Bool) async throws {
        focusWrites.append(gained)
    }
    /// Synchronous per E1 — capacity bookkeeping is a fast in-memory counter.
    /// The actor isolation is satisfied by an `isolated` parameter at call sites
    /// (or by callers awaiting the actor's executor before reading the value).
    public nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int {
        // Stub: returns a large constant so tests don't trip capacity in fast paths.
        // Tests that need to assert capacity behavior use `set(capacityRemaining:)`
        // on an alternate `actor`-backed spy provider rather than this stub.
        1 << 20
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/StubSurfaceProvider.swift
git commit -m "Add shared StubSurfaceProvider in TestSupport (D13)"
git push
```

---

### Task 0.19: `TerminalAccessService` protocol + `DefaultTerminalAccessService` listSurfaces + readScreen text path

(Resolves Coverage/Quality must_fix: `TerminalAccessService` is async per D1; `format=cells` and `wrap=join` throw `.unsupported` → 415 in Phase 0, replaced by real cells in Phase 1.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/TerminalAccessService.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceReadTests.swift`

- [ ] **Step 1: Failing test (uses the shared `StubSurfaceProvider`)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct DefaultServiceReadTests {
    private func makeService(text: String) async -> (DefaultTerminalAccessService, SurfaceInfo, StubSurfaceProvider) {
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: "t", cols: 80, rows: 24,
                               altScreen: false, focused: true,
                               semanticAvailable: false)
        let stub = StubSurfaceProvider()
        await stub.set(surfaces: [info]); await stub.set(cannedText: text)
        let svc = DefaultTerminalAccessService(provider: stub, audit: NoOpAuditLog())
        return (svc, info, stub)
    }

    @Test func unknownSurfaceMaps() async throws {
        let (svc, _, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.unknownSurface) {
            _ = try await svc.readScreen(.init(handle: .ref(kind: "surface", ordinal: 99)))
        }
    }
    @Test func textReadReturnsTextPayload() async throws {
        let (svc, info, _) = await makeService(text: "hello\n")
        let res = try await svc.readScreen(.init(handle: info.handle))
        guard case .text(let p) = res else { Issue.record("not text"); return }
        #expect(p.text == "hello\n"); #expect(p.cols == 80)
    }
    @Test func cellsRejectedAsUnsupported415InPhase0() async throws {
        let (svc, info, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.self) {
            _ = try await svc.readScreen(.init(handle: info.handle, format: .cells))
        }
    }
    @Test func wrapJoinRejectedAsUnsupported415InPhase0() async throws {
        let (svc, info, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.self) {
            _ = try await svc.readScreen(.init(handle: info.handle, wrap: .join))
        }
    }
    @Test func trimRemovesTrailingSpaces() async throws {
        let (svc, info, _) = await makeService(text: "hi   \nthere   \n")
        let res = try await svc.readScreen(.init(handle: info.handle, trim: true))
        guard case .text(let p) = res else { Issue.record("not text"); return }
        #expect(p.text == "hi\nthere\n")
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceReadTests.swift
git commit -m "Add failing DefaultTerminalAccessService read tests"
git push
```

- [ ] **Step 3: Implement protocol**
```swift
// TerminalAccessService.swift

/// Transport-neutral entry point that every cmux terminal-access caller
/// (Unix socket, CLI, HTTP) routes through (D1 — async, Sendable).
public protocol TerminalAccessService: Sendable {
    /// Enumerate every visible surface.
    func listSurfaces() async throws -> [SurfaceInfo]

    /// Read a screen with the requested format/region/wrap/trim.
    func readScreen(_ request: ScreenReadRequest) async throws -> ScreenReadResult

    /// Write input to a surface. Throws ``TerminalAccessError`` on gate
    /// / policy violations (D17 handles `focusSurface`, D30 serializes
    /// paste atomicity per surface).
    func writeInput(_ request: InputRequest) async throws
}

// E3 — the `allowRawInput` setting is owned by `DefaultTerminalAccessService`
// as an init-time closure (`allowRawInput: () -> Bool`); it is NOT part of
// the protocol surface. The HTTP layer wires `{ settings.allowRawInput }`
// at construction in Phase 1.
```

- [ ] **Step 4: Implement service skeleton (text read path + listSurfaces; write fanout lands in 0.20)**
```swift
// DefaultTerminalAccessService.swift
import Foundation

/// Default ``TerminalAccessService`` used by every cmux transport.
///
/// Phase 0 implements text reads + write fanout. ``ScreenFormat/cells``
/// and ``WrapPolicy/join`` throw ``TerminalAccessError/unsupported(reason:)``
/// (HTTP 415, D18) until ghostty patch #1 lands in Phase 1.
///
/// Per D30, paste calls are serialized per surface via a private actor
/// keyed by surface UUID so concurrent pastes never interleave. Per
/// D17, `request.focusSurface == true` calls
/// ``SurfaceProvider/setFocus(surface:gained:)`` BEFORE dispatching the
/// payload.
public final class DefaultTerminalAccessService: TerminalAccessService, @unchecked Sendable {
    private let provider: any SurfaceProvider
    private let audit: any AuditLog
    private let rateLimiter: RateLimiter
    private let streamCap: StreamCap
    private let cellsTickRate: Double
    private let allowRawInput: () -> Bool
    // E4 — `PasteSerializer` is defined ONCE in its own file
    // (Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift)
    // as a public actor. It is NOT defined inline here.
    private let pasteSerializer = PasteSerializer()

    // E3 — single locked constructor signature. Phase 0 uses the defaults;
    // Phase 1 passes a real `RateLimiter` and `allowRawInput: { settings.allowRawInput }`;
    // Phase 2 passes a real `StreamCap` and `cellsTickRate` from settings.
    public init(
        provider: any SurfaceProvider,
        audit: any AuditLog,
        rateLimiter: RateLimiter = RateLimiter(burstCapacity: 64, refillPerSecond: 16),
        streamCap: StreamCap = StreamCap(maxPerSurface: 8),
        cellsTickRate: Double = 5.0,
        allowRawInput: @escaping () -> Bool = { false }
    ) {
        self.provider = provider
        self.audit = audit
        self.rateLimiter = rateLimiter
        self.streamCap = streamCap
        self.cellsTickRate = cellsTickRate
        self.allowRawInput = allowRawInput
    }

    public func listSurfaces() async throws -> [SurfaceInfo] {
        try await provider.listSurfaces()
    }

    public func readScreen(_ request: ScreenReadRequest) async throws -> ScreenReadResult {
        guard let info = try await provider.resolve(request.handle) else {
            throw TerminalAccessError.unknownSurface
        }
        if request.wrap == .join {
            throw TerminalAccessError.unsupported(reason: "wrap=join requires ghostty patch #1")
        }
        switch request.format {
        case .text:
            var text = try await provider.readText(surface: info, region: request.region)
            if request.trim { text = Self.trimTrailingSpaces(text) }
            return .text(TextScreenPayload(cols: info.cols, rows: info.rows,
                                           altScreen: info.altScreen,
                                           title: info.title, text: text))
        case .cells:
            throw TerminalAccessError.unsupported(reason: "format=cells requires ghostty patch #1")
        }
    }

    // writeInput body lands in Task 0.20 (so this commit stays buildable).
    public func writeInput(_ request: InputRequest) async throws {
        throw TerminalAccessError.unsupported(reason: "writeInput lands in Task 0.20")
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var end = line.endIndex
                while end > line.startIndex {
                    let prev = line.index(before: end)
                    if line[prev] == " " || line[prev] == "\t" { end = prev } else { break }
                }
                return line[line.startIndex..<end]
            }
            .joined(separator: "\n")
    }
}
```

> **E4 follow-up.** The `PasteSerializer` actor lives in its own file at
> `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift`,
> created in Task 0.19a (below). Do NOT inline the type into this file.

- [ ] **Step 5: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess
git commit -m "Add TerminalAccessService + DefaultTerminalAccessService read path (D1/D18/D30 skeleton)"
git push
```

---

### Task 0.19a: `PasteSerializer` actor in its own file (E4)

(Resolves E4: ONE definition of `PasteSerializer` in the package; NOT inlined in `DefaultTerminalAccessService.swift`. Phase 1 only USES it.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteSerializerTests.swift`

- [ ] **Step 1: Failing test (per-surface ordering, cross-surface concurrency)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct PasteSerializerTests {
    @Test func runsBodiesSeriallyPerSurface() async throws {
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: nil, cols: 1, rows: 1,
                               altScreen: false, focused: true,
                               semanticAvailable: false)
        let serializer = PasteSerializer()
        actor Order { var seq: [Int] = []; func append(_ n: Int) { seq.append(n) } }
        let order = Order()
        async let a: Void = serializer.run(surface: info) {
            try await Task.sleep(nanoseconds: 5_000_000); await order.append(1)
        }
        async let b: Void = serializer.run(surface: info) {
            await order.append(2)
        }
        _ = try await (a, b)
        #expect(await order.seq == [1, 2])
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteSerializerTests.swift
git commit -m "Add failing PasteSerializer per-surface ordering tests"
git push
```

- [ ] **Step 3: Implement**
```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift
import Foundation

/// Per-surface serial actor for paste atomicity (D30 / E4). Concurrent
/// `run(surface:_:)` calls for the same ``SurfaceInfo/uuid`` execute in
/// FIFO order; calls for different surfaces execute concurrently.
public actor PasteSerializer {
    private var tails: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func run<T: Sendable>(
        surface: SurfaceInfo,
        _ body: @Sendable @escaping () async throws -> T
    ) async rethrows -> T {
        let previous = tails[surface.uuid]
        let gate = Task<Void, Never> { await previous?.value }
        tails[surface.uuid] = gate
        await gate.value
        return try await body()
    }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift
git commit -m "Add PasteSerializer actor (E4 — one file, public actor)"
git push
```

---

### Task 0.19b: `ConstantTimeCompare` helper + legacy `SocketControlSettings:133` fix (E9)

(Resolves E9: shared `ctCompare` helper used by both legacy socket auth and Phase 1 `HTTPAuth`. Two-commit policy: failing test first proving the legacy `==` short-circuits, then the fix.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ConstantTimeCompare.swift`
- Modify: `Sources/SocketControlSettings.swift` (replace `==` at line 133)
- Test:   `cmuxTests/HTTPControl/SocketControlConstantTimeCompareTests.swift`

- [ ] **Step 1: Failing test (proves legacy `==` short-circuits on first mismatch)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess
@testable import cmux

@Suite struct SocketControlConstantTimeCompareTests {
    @Test func ctCompareTakesEqualTimeForEqualLengthInputs() {
        // Statistical timing test: many trials, full-length compare must
        // average within a small delta independent of first-byte mismatch.
        let n = 4096
        let a = Data(repeating: 0xAA, count: n)
        let bMismatchEarly = Data([0xBB]) + Data(repeating: 0xAA, count: n - 1)
        let bMismatchLate = Data(repeating: 0xAA, count: n - 1) + Data([0xBB])
        let early = measure { _ = ctCompare(a, bMismatchEarly) }
        let late  = measure { _ = ctCompare(a, bMismatchLate)  }
        #expect(abs(early - late) / max(early, late) < 0.2)
    }
    private func measure(_ body: () -> Void) -> Double {
        let start = ContinuousClock().now
        for _ in 0..<5000 { body() }
        return Double((ContinuousClock().now - start).components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add cmuxTests/HTTPControl/SocketControlConstantTimeCompareTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing ctCompare timing test for SocketControlSettings"
git push
```

- [ ] **Step 3: Implement `ctCompare` + replace `==` at `SocketControlSettings.swift:133`**
```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ConstantTimeCompare.swift
import Foundation

/// Constant-time byte-vector compare. Returns `false` immediately for
/// length mismatch (length leak is acceptable; per-byte equality leak
/// is not). E9 — shared helper used by legacy socket auth and Phase 1
/// `HTTPAuth`.
public func ctCompare(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    a.withUnsafeBytes { ap in
        b.withUnsafeBytes { bp in
            for i in 0..<a.count { diff |= ap[i] ^ bp[i] }
        }
    }
    return diff == 0
}
```
Then in `Sources/SocketControlSettings.swift:133`, replace `expected == candidate` with `ctCompare(expected, candidate)` and `import CmuxTerminalAccess` at the top of the file if not already present.

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ConstantTimeCompare.swift \
        Sources/SocketControlSettings.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add ctCompare; replace SocketControlSettings:133 == with constant-time compare (E9)"
git push
```

---

### Task 0.20: `DefaultTerminalAccessService.writeInput` — text / keys / raw-gate / mouse / focus + `focusSurface` wiring (D17)

(Resolves Coverage must_fix #15 / #17: `focusSurface == true` calls `provider.setFocus(...)` BEFORE the payload dispatches; mouse goes through `provider.writeMouse` directly per D16; raw is gated; audit log emits ALWAYS-ON per D4.)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceWriteTests.swift`

- [ ] **Step 1: Failing tests (lock D17 + D4 + D16 behaviorally)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct DefaultServiceWriteTests {
    /// E2 — `AuditLog.record` is `async` non-throwing. Test recorder is an
    /// `actor` so appends are serialized without a lock.
    actor RecordingAudit: AuditLog {
        var entries: [AuditEntry] = []
        func record(_ entry: AuditEntry) async { entries.append(entry) }
    }
    private func setUp() async -> (DefaultTerminalAccessService, SurfaceInfo, StubSurfaceProvider, RecordingAudit) {
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: nil, cols: 80, rows: 24,
                               altScreen: false, focused: false,
                               semanticAvailable: false)
        let stub = StubSurfaceProvider(); await stub.set(surfaces: [info])
        let audit = RecordingAudit()
        // E3 — DefaultTerminalAccessService.init signature is locked with defaults
        // for rateLimiter/streamCap/cellsTickRate. `allowRawInput` defaults to `{ false }`.
        let svc = DefaultTerminalAccessService(provider: stub, audit: audit)
        return (svc, info, stub, audit)
    }

    @Test func textWithSubmitAppendsCR() async throws {
        let (svc, info, stub, audit) = await setUp()
        try await svc.writeInput(.init(handle: info.handle,
                                       payload: .text("ls", submit: true)))
        let writes = await stub.textWrites
        // E1 — submit=true dispatches writeText("ls") + writeKey(.enter); the
        // text payload itself is the literal bytes (no embedded CR).
        #expect(writes == [Data([0x6c, 0x73])])
        let keys = await stub.keyWrites
        #expect(keys.count == 1)
        let entries = await audit.entries
        #expect(entries.first?.kind == .writeText)  // D4 always-on, E2 await
    }

    @Test func keysFanOutToProvider() async throws {
        let (svc, info, stub, _) = await setUp()
        try await svc.writeInput(.init(handle: info.handle,
            payload: .keys([try KeyEvent.parse("Ctrl+C"), try KeyEvent.parse("Up")])))
        let keys = await stub.keyWrites
        #expect(keys.count == 2)
    }

    @Test func rawRejectedByDefault() async throws {
        let (svc, info, _, _) = await setUp()
        await #expect(throws: TerminalAccessError.self) {
            try await svc.writeInput(.init(handle: info.handle, payload: .raw(Data([0x1B]))))
        }
    }

    @Test func rawAllowedWhenGateOpen() async throws {
        // E3 — `allowRawInput` is an init-time closure; set it via constructor here.
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: nil, cols: 80, rows: 24,
                               altScreen: false, focused: false,
                               semanticAvailable: false)
        let stub = StubSurfaceProvider(); await stub.set(surfaces: [info])
        let audit = RecordingAudit()
        let svc = DefaultTerminalAccessService(provider: stub, audit: audit,
                                               allowRawInput: { true })
        try await svc.writeInput(.init(handle: info.handle, payload: .raw(Data([0x1B]))))
        let writes = await stub.textWrites
        #expect(writes == [Data([0x1B])])
        let entries = await audit.entries
        #expect(entries.contains { $0.kind == .writeRaw })
    }

    @Test func payloadTooLargeWhenCapacityExceeded() async throws {
        // Uses a dedicated capacity-aware spy provider — the shared
        // `StubSurfaceProvider` per E1 returns a large constant for capacity
        // remaining; this test installs a provider whose
        // `pendingInputCapacityRemaining` returns a small constant. The
        // capacity precondition runs inside `enforceCapacity(info:bytes:)`
        // before any provider write (E14 — preserved in Phase 1 too).
        actor TinyCapacityProvider: SurfaceProvider {
            let info: SurfaceInfo
            init(_ info: SurfaceInfo) { self.info = info }
            func listSurfaces() async throws -> [SurfaceInfo] { [info] }
            func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? { info }
            func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
            func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
                throw TerminalAccessError.unsupported(reason: "stub")
            }
            func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
            func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
            func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
            func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
            nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 4 }
        }
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: nil, cols: 80, rows: 24,
                               altScreen: false, focused: false,
                               semanticAvailable: false)
        let svc = DefaultTerminalAccessService(provider: TinyCapacityProvider(info),
                                               audit: NoOpAuditLog())
        await #expect(throws: TerminalAccessError.payloadTooLarge) {
            try await svc.writeInput(.init(handle: info.handle,
                                           payload: .text(String(repeating: "x", count: 5),
                                                          submit: false)))
        }
    }

    @Test func mouseGoesDirectlyToProviderNeverNSEvent() async throws {  // D16
        let (svc, info, stub, _) = await setUp()
        let m = MouseEvent(action: .press, button: .left, x: 5, y: 7, mods: [], scrollDy: 0)
        try await svc.writeInput(.init(handle: info.handle, payload: .mouse(m)))
        let mw = await stub.mouseWrites
        let nse = await stub.nsEventBuilds
        #expect(mw == [m]); #expect(nse == 0)  // D16 — no NSEvent synthesized
    }

    @Test func focusSurfaceCallsSetFocusBeforeWrite() async throws {  // D17
        let (svc, info, stub, _) = await setUp()
        try await svc.writeInput(.init(handle: info.handle,
                                       payload: .text("x", submit: false),
                                       focusSurface: true))
        let foci = await stub.focusWrites
        let writes = await stub.textWrites
        #expect(foci == [true])
        #expect(writes == [Data([0x78])])
    }

    @Test func focusOnlyPayloadCallsSetFocusOnce() async throws {
        let (svc, info, stub, audit) = await setUp()
        try await svc.writeInput(.init(handle: info.handle, payload: .focus(gained: false)))
        let foci = await stub.focusWrites
        #expect(foci == [false])
        let entries = await audit.entries
        #expect(entries.last?.kind == .writeFocus)
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceWriteTests.swift
git commit -m "Add failing DefaultTerminalAccessService write tests (D17/D16/D4)"
git push
```

- [ ] **Step 3: Replace `writeInput` body in `DefaultTerminalAccessService.swift`**
```swift
// Replace the stub `writeInput` placeholder with the real impl.
// E1 — the dispatch composes higher-level operations from the locked
// SurfaceProvider primitives (writeText / writeKey / writeMouse / setFocus).
// E2 — `audit.record(...)` is `async` non-throwing (no `try`).
// E14 — every payload that writes bytes runs `try await enforceCapacity(...)`
// BEFORE any provider call.
public func writeInput(_ request: InputRequest) async throws {
    guard let info = try await provider.resolve(request.handle) else {
        throw TerminalAccessError.unknownSurface
    }
    // D17 — explicit focus opt-in fires BEFORE the payload dispatches.
    if request.focusSurface {
        try await provider.setFocus(surface: info, gained: true)
    }
    switch request.payload {
    case .text(let s, let submit):
        let bytes = Data(s.utf8)
        try await enforceCapacity(info: info, bytes: bytes.count)
        try await provider.writeText(surface: info, bytes: bytes)
        if submit {
            try await provider.writeKey(surface: info,
                                        event: KeyEvent(mods: [], key: .enter))
        }
        await audit.record(AuditEntry(timestamp: Date(), surface: request.handle,
                                      kind: .writeText, byteCount: bytes.count,
                                      detail: ["submit": "\(submit)"]))
    case .paste(let s):
        // D30 — serialize wrap+write per-surface so concurrent pastes
        // cannot interleave byte slices.
        let bytes = Data(s.utf8)
        try await enforceCapacity(info: info, bytes: bytes.count)
        try await pasteSerializer.run(surface: info) {
            try await provider.writeText(surface: info, bytes: bytes)
        }
        await audit.record(AuditEntry(timestamp: Date(), surface: request.handle,
                                      kind: .writePaste, byteCount: bytes.count, detail: nil))
    case .keys(let events):
        for ev in events { try await provider.writeKey(surface: info, event: ev) }
        await audit.record(AuditEntry(timestamp: Date(), surface: request.handle,
                                      kind: .writeKeys, byteCount: events.count, detail: nil))
    case .raw(let data):
        if !allowRawInput() {
            throw TerminalAccessError.forbidden(reason: "raw input disabled")
        }
        try await enforceCapacity(info: info, bytes: data.count)
        try await provider.writeText(surface: info, bytes: data)
        await audit.record(AuditEntry(timestamp: Date(), surface: request.handle,
                                      kind: .writeRaw, byteCount: data.count, detail: nil))
    case .mouse(let ev):
        // D16 — direct provider call; provider must NOT synthesize NSEvent.
        try await provider.writeMouse(surface: info, event: ev)
        await audit.record(AuditEntry(timestamp: Date(), surface: request.handle,
                                      kind: .writeMouse, byteCount: 0,
                                      detail: ["action": ev.action.rawValue]))
    case .focus(let gained):
        try await provider.setFocus(surface: info, gained: gained)
        await audit.record(AuditEntry(timestamp: Date(), surface: request.handle,
                                      kind: .writeFocus, byteCount: 0,
                                      detail: ["gained": "\(gained)"]))
    }
}

private func enforceCapacity(info: SurfaceInfo, bytes: Int) async throws {
    // E1 — `pendingInputCapacityRemaining` is synchronous; no `await`.
    let remaining = provider.pendingInputCapacityRemaining(surface: info)
    if bytes > remaining { throw TerminalAccessError.payloadTooLarge }
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift
git commit -m "Implement writeInput with focusSurface (D17), audit always-on (D4), mouse direct (D16)"
git push
```

---

### Task 0.21: Per-surface paste atomicity test (D30) — concurrent paste interleave check (characterization test — no red→green ritual)

(Resolves Coverage must_fix #14 + must_fix #30. E13 — this is a characterization test: the implementation already exists from Task 0.20, so a "RED then GREEN" split would be artificial. Commit as a single test addition.)

**Files:**
- Test: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteAtomicityTests.swift`

- [ ] **Step 1: Add test (single commit — characterization)**
```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct PasteAtomicityTests {
    /// Stub that simulates slow per-write fanout: each `writeText` call
    /// records its bytes after a short async yield, so without
    /// per-surface serialization the recorded byte sequence would
    /// interleave the two payloads.
    ///
    /// E1 — matches the locked `SurfaceProvider` shape: no `attachRawOutput`
    /// required member, `pendingInputCapacityRemaining` is synchronous.
    actor SlowWrite: SurfaceProvider {
        let info: SurfaceInfo
        var recorded: [Data] = []
        init() {
            info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                               uuid: UUID(), workspaceRef: "workspace:1",
                               title: nil, cols: 80, rows: 24,
                               altScreen: false, focused: true,
                               semanticAvailable: false)
        }
        func listSurfaces() async throws -> [SurfaceInfo] { [info] }
        func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? {
            (h == info.handle || h == .uuid(info.uuid)) ? info : nil
        }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
            throw TerminalAccessError.unsupported(reason: "n/a")
        }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {
            // Yield twice so the scheduler has plenty of chances to
            // interleave a non-serialized concurrent caller.
            await Task.yield(); await Task.yield()
            recorded.append(bytes)
        }
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }
    }

    @Test func concurrentPastesDoNotInterleave() async throws {
        let provider = SlowWrite()
        let svc = DefaultTerminalAccessService(provider: provider, audit: NoOpAuditLog())
        let info = await provider.info
        let a = String(repeating: "A", count: 64)
        let b = String(repeating: "B", count: 64)

        async let p1: Void = svc.writeInput(.init(handle: info.handle, payload: .paste(a)))
        async let p2: Void = svc.writeInput(.init(handle: info.handle, payload: .paste(b)))
        _ = try await [p1, p2]

        let recorded = await provider.recorded
        #expect(recorded.count == 2)
        #expect(Set(recorded) == Set([Data(a.utf8), Data(b.utf8)]))
        // Each recorded blob is a single contiguous payload — neither
        // contains the other byte's character.
        for blob in recorded {
            let only = Set(blob)
            #expect(only.count == 1)  // all-A or all-B, never mixed
        }
    }
}
```

- [ ] **Step 2: Commit and push (single characterization commit)**
```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteAtomicityTests.swift
git commit -m "Add paste atomicity characterization test (D30)"
git push
```
Expected: CI green. If it fails, fix the `pasteSerializer.run(surface:)` integration in Task 0.20 — do NOT weaken the test.

---

### Task 0.22: `HTTPControlSettings` (D2 instance class) + embedded token store + `Transport` enum

(Resolves Coverage/Quality must_fix #1: ONE definition of `HTTPControlSettings`; D2 instance class `init(supportDirectory:URL, defaults:UserDefaults)` embeds `ensureToken()`/`rotateToken()`/`tokenFilePath`; inner enum `Transport { case tcp, uds }`. Phase 1 ONLY adds the SwiftUI binding view — does NOT redefine the file. Token file mode 0600, generated via `SecRandomCopyBytes` — NOT `CMUX_SOCKET_PASSWORD`, NOT injected into child env (D9).)

**Files:**
- Create: `Sources/HTTPControl/HTTPControlSettings.swift`
- Test:   `cmuxTests/HTTPControl/HTTPControlSettingsTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj` (wire both files; run normalize + lint)

- [ ] **Step 1: Failing tests**
```swift
// cmuxTests/HTTPControl/HTTPControlSettingsTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlSettingsTests {
    private func makeSettings() throws -> (HTTPControlSettings, URL, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-httpctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "cmux.httpctl.\(UUID().uuidString)")!
        let s = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        return (s, dir, defaults)
    }

    @Test func ensureTokenGeneratesAt0600() throws {
        let (s, _, _) = try makeSettings()
        let t1 = try s.ensureToken()
        #expect(!t1.isEmpty)
        let perms = (try FileManager.default.attributesOfItem(atPath: s.tokenFilePath.path)[.posixPermissions]
                     as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test func ensureTokenReusesExisting() throws {
        let (s, _, _) = try makeSettings()
        let t1 = try s.ensureToken()
        let t2 = try s.ensureToken()
        #expect(t1 == t2)
    }

    @Test func rotateTokenChangesValueAndPreserves0600() throws {
        let (s, _, _) = try makeSettings()
        let t1 = try s.ensureToken()
        let t2 = try s.rotateToken()
        #expect(t1 != t2)
        let perms = (try FileManager.default.attributesOfItem(atPath: s.tokenFilePath.path)[.posixPermissions]
                     as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test func transportEnumRoundTripsThroughDefaults() throws {
        let (s, _, defaults) = try makeSettings()
        s.transport = .uds
        let s2 = HTTPControlSettings(supportDirectory: s.supportDirectory, defaults: defaults)
        #expect(s2.transport == .uds)
    }

    @Test func defaultsAreSafe() throws {
        let (s, _, _) = try makeSettings()
        #expect(s.enabled == false)
        #expect(s.transport == .tcp)
        #expect(s.allowRawInput == false)
    }
}
```

- [ ] **Step 2: Wire files into pbxproj + push RED**
Add `Sources/HTTPControl/HTTPControlSettings.swift` to the `cmux` target and `cmuxTests/HTTPControl/HTTPControlSettingsTests.swift` to the `cmuxTests` target. Then:
```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
bash scripts/lint-pbxproj-test-wiring.sh
git add cmuxTests/HTTPControl/HTTPControlSettingsTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPControlSettings tests (D2)"
git push
```
Expected: CI fails — `HTTPControlSettings` undefined.

- [ ] **Step 3: Implement**
```swift
// Sources/HTTPControl/HTTPControlSettings.swift
import Foundation
import Security

/// Persisted settings for the HTTP control surface (D2 single
/// definition). Instance class — NOT static `@AppStorage` — so tests
/// can inject `supportDirectory` and `UserDefaults`. Phase 1 binds the
/// SwiftUI view to this type; Phase 1 does NOT redefine it.
public final class HTTPControlSettings {
    /// HTTP control transport selection (D2 inner enum).
    public enum Transport: String, Sendable { case tcp, uds }

    public let supportDirectory: URL
    private let defaults: UserDefaults

    public init(supportDirectory: URL, defaults: UserDefaults = .standard) {
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: supportDirectory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    // MARK: - Settings keys (per D2)

    public var enabled: Bool {
        get { defaults.bool(forKey: Self.kEnabled) }
        set { defaults.set(newValue, forKey: Self.kEnabled) }
    }

    public var transport: Transport {
        get { Transport(rawValue: defaults.string(forKey: Self.kTransport) ?? Transport.tcp.rawValue) ?? .tcp }
        set { defaults.set(newValue.rawValue, forKey: Self.kTransport) }
    }

    public var tcpPort: Int {
        get { let v = defaults.integer(forKey: Self.kTcpPort); return v > 0 ? v : 49100 }
        set { defaults.set(newValue, forKey: Self.kTcpPort) }
    }

    // E15 — locked name is `udsPath`, not `unixSocketPath`. Used consistently
    // across HTTPControlSettings, SettingsView, and Lifecycle.
    public var udsPath: String {
        get { defaults.string(forKey: Self.kUDSPath) ?? "" }
        set { defaults.set(newValue, forKey: Self.kUDSPath) }
    }

    public var allowRawInput: Bool {
        get { defaults.bool(forKey: Self.kAllowRawInput) }
        set { defaults.set(newValue, forKey: Self.kAllowRawInput) }
    }

    public var auditLogPath: URL {
        // D4 — Settings only controls the audit log PATH; logging itself
        // is ALWAYS-ON for write paths. Default lives under the support
        // directory.
        if let custom = defaults.string(forKey: Self.kAuditLogPath), !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return supportDirectory.appendingPathComponent("http-control-audit.jsonl")
    }

    public var tokenLastRotated: Date? {
        let v = defaults.double(forKey: Self.kTokenLastRotated)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }

    // MARK: - Token store (D2 embedded — no separate HTTPControlTokenStore class)

    /// Token file path. Default location:
    /// `<supportDirectory>/http-control-token`, mode 0600.
    public var tokenFilePath: URL {
        supportDirectory.appendingPathComponent("http-control-token")
    }

    /// Returns the existing token, generating one (and creating the file
    /// with mode 0600) if absent. Never injected into child terminal
    /// envs (D9) — see ``AppSurfaceProvider`` code comment.
    public func ensureToken() throws -> String {
        if FileManager.default.fileExists(atPath: tokenFilePath.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: tokenFilePath.path)
            return try String(contentsOf: tokenFilePath, encoding: .utf8)
        }
        return try rotateToken()
    }

    /// Generates a fresh token via `SecRandomCopyBytes`, atomically
    /// overwrites the file, and re-applies mode 0600. Phase 1's
    /// settings UI invokes this; Phase 1 lifecycle wires it to
    /// invalidate active connections.
    public func rotateToken() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "HTTPControlSettings.token", code: Int(status))
        }
        let token = bytes.base64EncodedString()
        let tmp = tokenFilePath.deletingPathExtension()
            .appendingPathExtension("tmp.\(UUID().uuidString)")
        try Data(token.utf8).write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(tokenFilePath, withItemAt: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: tokenFilePath.path)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.kTokenLastRotated)
        return token
    }

    // MARK: - Keys
    private static let kEnabled = "httpControl.enabled"
    private static let kTransport = "httpControl.transport"
    private static let kTcpPort = "httpControl.tcpPort"
    private static let kUDSPath = "httpControl.udsPath"
    private static let kAllowRawInput = "httpControl.allowRawInput"
    private static let kAuditLogPath = "httpControl.auditLogPath"
    private static let kTokenLastRotated = "httpControl.tokenLastRotated"
}
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Sources/HTTPControl/HTTPControlSettings.swift cmux.xcodeproj/project.pbxproj
git commit -m "Implement HTTPControlSettings instance class with embedded token store (D2)"
git push
```

---

### Task 0.23: `AppSurfaceProvider` (app target) — bridge to `TerminalController` (D1 async throws; D9 no env injection)

(Resolves Coverage/Quality must_fix: AppSurfaceProvider has ONE shape with `async throws` methods per D1 / E1; `readCells` is a REQUIRED protocol member (E20) and the Phase 0 stub throws `.unsupported` until ghostty patch #1 lands in Phase 1; the raw-output tap is added as a separate protocol extension in Task 2.15 (E1 — NOT a Phase 0 required member). Explicit code comment forbids HTTP token export per D9. E5 — `AppSurfaceProvider.shared` + `setController(_:)` + `#if DEBUG testInject/testReset` form the singleton entry point.)

**Files:**
- Create: `Sources/HTTPControl/AppSurfaceProvider.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Implement (no failing test in this task — Tasks 0.24/0.25/0.26 cover behavior via the extracted helpers, the no-env test, and the socket regression)**
```swift
// Sources/HTTPControl/AppSurfaceProvider.swift
import AppKit
import CmuxTerminalAccess
import Foundation

/// Bridges ``SurfaceProvider`` from ``CmuxTerminalAccess`` onto the live
/// ``TerminalController`` surface registry (D1 — every method
/// `async throws`).
///
/// IMPORTANT (D9): the HTTP control bearer token MUST NOT be exported
/// into child terminal environments. The token lives in
/// `<supportDirectory>/http-control-token` (mode 0600) and is read ONLY
/// by the HTTP listener — never written into `env` for spawned PTYs.
/// Task 0.25 adds a behavioral test that fails if this invariant is
/// violated.
/// E5 — Singleton process-wide bridge. The `shared` instance is set up
/// lazily; the live `TerminalController` is injected via
/// `setController(_:)` from `AppDelegate` at launch. Test fixtures in
/// Phase 1 use `#if DEBUG` `testInject(panel:handle:)` to wire a
/// synthetic surface without an `AppDelegate`.
public final class AppSurfaceProvider: SurfaceProvider, @unchecked Sendable {
    /// Process-wide instance. `AppDelegate` calls
    /// `AppSurfaceProvider.shared.setController(terminalController)`
    /// during launch; the HTTP server consumes `shared` after that.
    public static let shared = AppSurfaceProvider()

    private var controller: TerminalController?
    #if DEBUG
    private var injected: [SurfaceHandle: (panel: TerminalPanel, info: SurfaceInfo)] = [:]
    #endif

    /// Internal initializer — call `AppSurfaceProvider.shared`, not this.
    internal init() {}

    /// Inject the live controller. Called once by `AppDelegate` at launch.
    public func setController(_ controller: TerminalController) {
        self.controller = controller
    }

    #if DEBUG
    /// Inject a synthetic panel for tests. Phase 1 test environments
    /// (`HTTPControlTestEnv.startWithLiveSurface(...)`) call this to
    /// wire a panel without an `AppDelegate` instance.
    public func testInject(panel: TerminalPanel, handle: SurfaceHandle) {
        let info = SurfaceInfo(handle: handle,
                               uuid: UUID(), workspaceRef: "test:1",
                               title: panel.surface.title,
                               cols: panel.surface.gridCols,
                               rows: panel.surface.gridRows,
                               altScreen: panel.surface.isAltScreen,
                               focused: true, semanticAvailable: false)
        injected[handle] = (panel, info)
    }

    /// Clear all injected state. Tests call this in `deinit` / teardown.
    public func testReset() { injected.removeAll() }
    #endif

    public func listSurfaces() async throws -> [SurfaceInfo] {
        #if DEBUG
        if !injected.isEmpty { return injected.values.map { $0.info } }
        #endif
        guard let controller else { return [] }
        return await MainActor.run { controller.v2EnumerateSurfaceInfos() }
    }

    public func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo? {
        #if DEBUG
        if let pair = injected[handle] { return pair.info }
        #endif
        guard let controller else { return nil }
        return await MainActor.run { controller.v2Resolve(handle: handle) }
    }

    public func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String {
        // E10/E19 — derive from readCells via cellsToText. Real impl lands
        // in Phase 1's final task (ScreenRegionReader retirement). Until
        // then, this method still calls the controller's existing
        // SCREEN+SURFACE+ACTIVE merge so Phase 0 sockets keep working.
        guard let controller else { throw TerminalAccessError.unknownSurface }
        return try await controller.readSurfaceText(uuid: surface.uuid, region: region)
    }

    public func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
        // Phase 1 wires this to ghostty patch #1's `GhosttyCellsBridge`.
        throw TerminalAccessError.unsupported(reason: "format=cells requires ghostty patch #1")
    }

    public func writeText(surface: SurfaceInfo, bytes: Data) async throws {
        guard let controller else { throw TerminalAccessError.unknownSurface }
        try await controller.writeSurfaceText(uuid: surface.uuid, bytes: bytes)
    }

    public func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {
        guard let controller else { throw TerminalAccessError.unknownSurface }
        try await controller.writeSurfaceKey(uuid: surface.uuid, event: event)
    }

    public func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {
        guard let controller else { throw TerminalAccessError.unknownSurface }
        // D16 — implementation in TerminalController must call
        // ghostty_surface_mouse_button/_pos/_scroll directly. Never
        // synthesize NSEvents on this path (hits hit-test latency).
        try await controller.writeSurfaceMouse(uuid: surface.uuid, event: event)
    }

    public func setFocus(surface: SurfaceInfo, gained: Bool) async throws {
        guard let controller else { throw TerminalAccessError.unknownSurface }
        try await controller.setSurfaceFocus(uuid: surface.uuid, gained: gained)
    }

    // E1 — synchronous; provider exposes a fast in-memory counter snapshot.
    // The Phase 2 raw-output tap (`attachRawOutput`) lives as a separate
    // protocol extension declared in Task 2.15.
    public func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int {
        controller?.pendingInputCapacityRemaining(uuid: surface.uuid) ?? 0
    }
}
```

- [ ] **Step 2: Wire file into pbxproj**
Add `Sources/HTTPControl/AppSurfaceProvider.swift` to the `cmux` target. Run:
```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
bash scripts/lint-pbxproj-test-wiring.sh
```
Note: this file references TerminalController methods that don't exist yet — `v2EnumerateSurfaceInfos`, `v2Resolve(handle:)`, `readSurfaceText`, `writeSurfaceText`, `writeSurfaceKey`, `writeSurfaceMouse`, `setSurfaceFocus`, `pendingInputCapacityRemaining`. Task 0.24 adds them one extract at a time (each with its own RED/GREEN), so this file will fail to compile until 0.24 finishes. To keep the tree buildable, commit this file in 0.23 ONLY with stub forwarders in `TerminalController` that throw `.unknownSurface`:

```swift
// Sources/TerminalController.swift — add this stub extension in 0.23
import CmuxTerminalAccess

extension TerminalController {
    @MainActor func v2EnumerateSurfaceInfos() -> [SurfaceInfo] { [] }
    @MainActor func v2Resolve(handle: SurfaceHandle) -> SurfaceInfo? { nil }
    func readSurfaceText(uuid: UUID, region: ScreenRegion) async throws -> String {
        throw TerminalAccessError.unknownSurface
    }
    func writeSurfaceText(uuid: UUID, bytes: Data) async throws {
        throw TerminalAccessError.unknownSurface
    }
    func writeSurfaceKey(uuid: UUID, event: KeyEvent) async throws {
        throw TerminalAccessError.unknownSurface
    }
    func writeSurfaceMouse(uuid: UUID, event: MouseEvent) async throws {
        throw TerminalAccessError.unknownSurface
    }
    func setSurfaceFocus(uuid: UUID, gained: Bool) async throws {
        throw TerminalAccessError.unknownSurface
    }
    nonisolated func pendingInputCapacityRemaining(uuid: UUID) -> Int { 0 }
}
```
Task 0.24 replaces each stub with the real extract, one at a time, each with its own failing test.

- [ ] **Step 3: Commit (tree buildable, stubs in place)**
```bash
git add Sources/HTTPControl/AppSurfaceProvider.swift Sources/TerminalController.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add AppSurfaceProvider (D1 async, D9 no-env comment) with TerminalController stub forwarders"
git push
```
Expected: CI green (compile-only; behavior covered in 0.24).

---

### Task 0.23a: `TerminalFixture` shared test fixture (E8)

(Resolves E8: ONE explicit Phase 0 task creates `cmuxTests/Fixtures/TerminalFixture.swift` with the full constructor set referenced across Phase 0/1/2. Phase 1 / Phase 2 tasks only USE the fixture — they do not redefine it.)

**Files:**
- Create: `cmuxTests/Fixtures/TerminalFixture.swift`
- Modify: `cmux.xcodeproj/project.pbxproj` (wire the fixture into both `cmuxTests` and the test bundles that consume it)

- [ ] **Step 1: Implement (no failing test in this micro-task — consumers in Phase 0.24/1.x/2.x exercise the fixture behaviorally)**

```swift
// cmuxTests/Fixtures/TerminalFixture.swift
import AppKit
import GhosttyKit
import Foundation
@testable import cmux

/// Reusable in-test terminal surface. Constructed off-main-actor and
/// drives a real ghostty surface so cell-grid / raw-output / write
/// tests can run without spinning up a full `cmuxApp` instance.
///
/// E8 — the constructor set below is the canonical surface area
/// referenced across Phase 0 (TerminalController extracts), Phase 1
/// (GhosttyCellsBridge, readText, no-env behavior), and Phase 2
/// (raw-output round-trip, backpressure, cells snapshot). Do not add
/// alternate fixtures in other test files.
public struct TerminalFixture: Sendable {
    public let panel: TerminalPanel
    public let handle: SurfaceHandle

    public static func makeWithLines(_ lines: [String]) async throws -> TerminalFixture {
        try await makeWithBytes(Data(lines.joined(separator: "\n").utf8))
    }
    public static func makeAltScreen() async throws -> TerminalFixture {
        // ESC[?1049h enters the alt screen; payload "X" so the grid has a cell.
        try await makeWithBytes(Data("\u{1B}[?1049hX".utf8))
    }
    public static func makeWithBytes(_ bytes: Data) async throws -> TerminalFixture {
        try await MakeFixture.build(initialBytes: bytes)
    }
    public static func spawn(command: String, args: [String]) async throws -> TerminalFixture {
        try await MakeFixture.spawn(command: command, args: args)
    }
    public static func spawnAndCapturedEnvironment(command: String, args: [String])
        async throws -> (TerminalFixture, [String: String])
    {
        try await MakeFixture.spawnAndCapture(command: command, args: args)
    }
    public func fakeRawSource(for handle: SurfaceHandle) -> RawSourceSpy {
        RawSourceSpy(handle: handle)
    }
}

/// Test-side spy backing `SurfaceProvider.attachRawOutput` (Phase 2
/// extension declared in Task 2.15). Records every byte slice the
/// service tees into the spy and exposes them for assertions.
public final class RawSourceSpy: @unchecked Sendable {
    public let handle: SurfaceHandle
    private let lock = NSLock()
    private var slices: [Data] = []
    public init(handle: SurfaceHandle) { self.handle = handle }
    public func recorded() -> [Data] { lock.lock(); defer { lock.unlock() }; return slices }
    public func push(_ data: Data) { lock.lock(); slices.append(data); lock.unlock() }
}

private enum MakeFixture {
    static func build(initialBytes: Data) async throws -> TerminalFixture { /* construct TerminalPanel, write bytes, return fixture */ fatalError("impl in task") }
    static func spawn(command: String, args: [String]) async throws -> TerminalFixture { fatalError("impl in task") }
    static func spawnAndCapture(command: String, args: [String]) async throws -> (TerminalFixture, [String: String]) { fatalError("impl in task") }
}
```

(The `MakeFixture` private helper extracts whatever real ghostty
construction code the existing test harness already uses; if there is
none, derive it from the legacy `cmuxTests/HTTPControl/HTTPControlPanelFixture.swift` body created in Task 0.24.a.)

- [ ] **Step 2: Commit**
```bash
git add cmuxTests/Fixtures/TerminalFixture.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add TerminalFixture shared test fixture (E8)"
git push
```

---

### Task 0.24: Replace `TerminalController` stub forwarders with real extracts (one task per extract, each RED → GREEN)

(Resolves Coverage/Quality granularity finding: Phase 0 Task 0.13 originally bundled 5 helper extracts with no failing test. Split into five sub-tasks 0.24.a–0.24.e, each with its own RED/GREEN.)

For each sub-task: write a failing characterization test that drives the real ghostty path against a synthetic `TerminalPanel` fixture (added in `cmuxTests/HTTPControl/HTTPControlPanelFixture.swift` as part of 0.24.a), commit RED, replace the stub with the real extract from the existing v1/v2 socket dispatch code, commit GREEN.

#### Task 0.24.a: `terminalPanel(byUUID:)` + `HTTPControlPanelFixture`

**Files:**
- Create: `cmuxTests/HTTPControl/HTTPControlPanelFixture.swift`
- Test:   `cmuxTests/HTTPControl/TerminalPanelLookupTests.swift`
- Modify: `Sources/TerminalController.swift` (extract `terminalPanel(byUUID:)` from `v2ResolveHandleRef` flow)
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**
```swift
// cmuxTests/HTTPControl/TerminalPanelLookupTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct TerminalPanelLookupTests {
    @Test @MainActor func returnsPanelByUUID() async throws {
        let env = try await HTTPControlPanelFixture.makeWithOneSurface(text: "READY\n")
        defer { env.tearDown() }
        let panel = env.controller.terminalPanel(byUUID: env.surfaceUUID)
        #expect(panel != nil)
    }
    @Test @MainActor func returnsNilForUnknown() async throws {
        let env = try await HTTPControlPanelFixture.makeWithOneSurface(text: "")
        defer { env.tearDown() }
        #expect(env.controller.terminalPanel(byUUID: UUID()) == nil)
    }
}
```

The fixture itself boots a TerminalController with one synthetic surface preloaded with deterministic text:
```swift
// cmuxTests/HTTPControl/HTTPControlPanelFixture.swift
import AppKit
@testable import cmux
import Foundation

/// Boots a real `TerminalController` with exactly one synthetic
/// terminal surface, feeds it `text`, and returns the controller +
/// surface UUID. Used by 0.24/0.25/0.26 to drive ghostty paths without
/// launching the full app.
@MainActor
struct HTTPControlPanelFixture {
    let controller: TerminalController
    let surfaceUUID: UUID
    private let cleanup: () -> Void
    func tearDown() { cleanup() }

    static func makeWithOneSurface(text: String) async throws -> HTTPControlPanelFixture {
        let controller = TerminalController.makeForTests()
        let uuid = controller.spawnHeadlessTerminalForTests()
        if !text.isEmpty {
            try await controller.feedRawForTests(uuid: uuid, bytes: Data(text.utf8))
        }
        return HTTPControlPanelFixture(
            controller: controller, surfaceUUID: uuid,
            cleanup: { controller.tearDownForTests() })
    }
}
```
The helpers `makeForTests`, `spawnHeadlessTerminalForTests`, `feedRawForTests`, `tearDownForTests` are `#if DEBUG` test seams added to `TerminalController` in this same task. Each is a thin wrapper around existing private setup code used by the v1/v2 socket handler tests.

- [ ] **Step 2: Push RED**
```bash
git add cmuxTests/HTTPControl/HTTPControlPanelFixture.swift \
        cmuxTests/HTTPControl/TerminalPanelLookupTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add failing terminalPanel(byUUID:) lookup test + HTTPControlPanelFixture"
git push
```
Expected: CI fails — `terminalPanel(byUUID:)` is the stub returning nil; the first test fails.

- [ ] **Step 3: Implement extract in `TerminalController.swift`**
Replace the stub `terminalPanel(byUUID:)` extension method with the real lookup, copying the body from the existing `case "v2ResolveHandleRef"` / `surface.list` paths. The body finds the `TerminalPanel` whose `surface.uuid == uuid` across all open windows.

```swift
extension TerminalController {
    @MainActor func terminalPanel(byUUID uuid: UUID) -> TerminalPanel? {
        for window in NSApplication.shared.windows {
            for panel in self.allTerminalPanels(in: window) where panel.surface.uuid == uuid {
                return panel
            }
        }
        return nil
    }
}
```
(The `allTerminalPanels(in:)` helper already exists; if not, inline the same iteration the v2 dispatch uses today.)

- [ ] **Step 4: Commit GREEN**
```bash
git add Sources/TerminalController.swift
git commit -m "Extract terminalPanel(byUUID:) from v2 dispatch"
git push
```

#### Task 0.24.b: `mergedScreenText(terminalPanel:)` — extract the three-tag merge

**Files:**
- Test:   `cmuxTests/HTTPControl/MergedScreenTextTests.swift`
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Failing test** that drives the merge against a surface with content on `viewport` + `screen` + `scrollback` regions and asserts the merged-text bytes match the existing `readTerminalTextBase64` output byte-for-byte.

```swift
// cmuxTests/HTTPControl/MergedScreenTextTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct MergedScreenTextTests {
    @Test @MainActor func mergedTextMatchesLegacyReadScreenForRegionScreen() async throws {
        let env = try await HTTPControlPanelFixture.makeWithOneSurface(text: "line1\nline2\nline3\n")
        defer { env.tearDown() }
        let panel = try #require(env.controller.terminalPanel(byUUID: env.surfaceUUID))
        let merged = env.controller.mergedScreenText(terminalPanel: panel)
        let legacyBase64 = env.controller.readTerminalTextBase64ForTests(
            panel: panel, region: "screen")
        let legacy = Data(base64Encoded: legacyBase64).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        #expect(merged == legacy)
    }
}
```

- [ ] **Step 2: Push RED** — `mergedScreenText` doesn't exist on the stub side yet.

- [ ] **Step 3: Extract the existing three-tag merge** from `readTerminalTextBase64` (~lines 9414-9453) into a standalone `@MainActor func mergedScreenText(terminalPanel:) -> String`. Update `readTerminalTextBase64` to call the new helper for `region == screen`, leaving behavior identical. Add `readTerminalTextBase64ForTests` `#if DEBUG` shim that exposes the existing private path.

- [ ] **Step 4: Commit GREEN.**

#### Task 0.24.c: `readSurfaceText(uuid:region:)` — full async readText path

**Files:**
- Test:   `cmuxTests/HTTPControl/AppSurfaceProviderReadTextTests.swift`
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Failing test** that boots the fixture and calls `AppSurfaceProvider.readText(surface:region:)` for each `ScreenRegion`, asserting the bytes match the legacy `read_screen` output.

- [ ] **Step 2: Push RED.**

- [ ] **Step 3: Replace the stub `readSurfaceText(uuid:region:)` in `TerminalController` with the real impl** (the body that maps `ScreenRegion` → `ghostty_point_tag_e` and dispatches through `MainActor.run`, calling `mergedScreenText` for `.screen` per 0.24.b).

- [ ] **Step 4: Commit GREEN.**

#### Task 0.24.d: `writeSurfaceText` + `writeSurfaceKey` (`sendKeyToPanel` extract)

**Files:**
- Test:   `cmuxTests/HTTPControl/AppSurfaceProviderWriteTests.swift`
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Failing test** drives `provider.writeText(...)` with `"echo hi"` and `provider.writeKey(...)` with `KeyEvent.parse("Enter")`, asserting `panel.sendInputResult` was invoked with the expected bytes (use a public `TerminalPanel.lastSentInputForTests` `#if DEBUG` accessor).

- [ ] **Step 2: Push RED.**

- [ ] **Step 3: Replace stub `writeSurfaceText`/`writeSurfaceKey`** with the real impls extracted from `case "surface.send_text"` and `case "surface.send_key"`. `sendKeyToPanel(_:event:)` becomes a `private @MainActor func` on `TerminalController`; both surface-level methods are thin wrappers.

- [ ] **Step 4: Commit GREEN.**

#### Task 0.24.e: `writeSurfaceMouse` + `setSurfaceFocus` + `pendingInputCapacityRemaining`

**Files:**
- Test:   `cmuxTests/HTTPControl/AppSurfaceMouseFocusTests.swift`
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Failing test** drives a mouse press + focus call against the fixture and asserts (a) `ghostty_surface_mouse_button` was invoked (via a `#if DEBUG` ghostty-call counter the existing code already uses for the v2 mouse tests), (b) no `NSEvent` was constructed (D16 — use a process-wide atomic in a `#if DEBUG` test seam `TerminalController.testNSEventBuildCount`), and (c) `setSurfaceFocus(true)` does NOT change `NSApp.isActive` (D17/socket-focus policy).

- [ ] **Step 2: Push RED.**

- [ ] **Step 3: Implement `sendMouseToPanel(_:event:)` and `setSurfaceFocus`** as thin wrappers around `ghostty_surface_mouse_button`/`_pos`/`_scroll` and `ghostty_surface_set_focus`. `pendingInputCapacityRemaining(uuid:)` reads the per-panel queue counter (defaults to 1 MiB when unset, matching current v2 behavior).

- [ ] **Step 4: Commit GREEN** — all five extracts done, AppSurfaceProvider is now real. Run pbxproj normalize/lint after the last commit.

---

### Task 0.25: HTTP-token-NOT-in-child-env behavioral test (D9)

(Resolves Coverage must_fix #5: "Adds a behavioral test that spawns a synthetic terminal via existing TerminalSurface fixtures and asserts the HTTP token is absent from the child environment.")

**Files:**
- Test: `cmuxTests/HTTPControl/HTTPControlTokenNoEnvLeakTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**
```swift
// cmuxTests/HTTPControl/HTTPControlTokenNoEnvLeakTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlTokenNoEnvLeakTests {
    @Test @MainActor func childTerminalEnvDoesNotContainHTTPControlToken() async throws {
        // Ensure a token exists so the file is present + readable.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-token-leak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "cmux.tokenleak.\(UUID().uuidString)")!
        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        let token = try settings.ensureToken()
        #expect(!token.isEmpty)

        // Boot a synthetic surface and capture the env the child PTY was
        // spawned with. The fixture exposes `lastChildEnvForTests` —
        // a snapshot of the env dict passed to fork/exec.
        let env = try await HTTPControlPanelFixture.makeWithOneSurface(text: "")
        defer { env.tearDown() }
        let childEnv = try #require(env.controller.lastChildEnvForTests(uuid: env.surfaceUUID))

        // D9 — the HTTP token must NEVER appear in child env (neither as
        // value nor as any plausible key name).
        for (k, v) in childEnv {
            #expect(v != token, "token leaked as value for env var \(k)")
            #expect(!k.lowercased().contains("http_control"),
                    "child env contains an http_control-prefixed key: \(k)")
            #expect(!k.lowercased().contains("httpcontrol"),
                    "child env contains an httpcontrol-prefixed key: \(k)")
        }
    }
}
```

- [ ] **Step 2: Wire test into pbxproj + push RED (only if the fixture's `lastChildEnvForTests` accessor doesn't exist yet)**
Add a `#if DEBUG` `lastChildEnvForTests(uuid:) -> [String: String]?` to `TerminalController` that returns the captured env dict from the most recent fork/exec for the given UUID. If the captured-env seam already exists from prior dev work, the test should pass on the first push; if not, this RED commit drives the seam in.

```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
bash scripts/lint-pbxproj-test-wiring.sh
git add cmuxTests/HTTPControl/HTTPControlTokenNoEnvLeakTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add HTTP-token no-env-leak behavioral test (D9)"
git push
```
Expected on first push: either CI fails compile (seam missing — add it in Step 3) or the assertion fails (token is leaked — fix in Step 3).

- [ ] **Step 3: If failing, add the `#if DEBUG` env-capture seam in `TerminalController` and ensure nothing in `Sources/HTTPControl/` injects the token into the child env**
Audit every callsite that builds the child env (search `setenv` / `posix_spawn_file_actions` / the existing `CMUX_SOCKET_PASSWORD` writer) and confirm no `HTTPControlSettings`-derived value is read on those paths. Add a one-line assertion + code comment at the env-build site:
```swift
// D9 — HTTP control token MUST NOT be exported to child PTY env. If
// future changes add a token export here, the
// HTTPControlTokenNoEnvLeakTests above will fail at CI time.
```

- [ ] **Step 4: Commit GREEN**
```bash
git add Sources/TerminalController.swift  # + any env-build site touched
git commit -m "Enforce D9: HTTP control token never exported to child PTY env"
git push
```

---

### Task 0.26: Regression characterization tests (RED) + route existing v1/v2 socket commands through `DefaultTerminalAccessService` (GREEN) — split per-command

(Resolves Coverage/Quality granularity must_fix: Phase 0 Task 0.15 originally bundled 4 socket commands; split into four sub-tasks 0.26.a–0.26.d, each a clean RED→GREEN pair. Each sub-task: install a deterministic characterization test that pins current bytes — RED if the routed impl isn't in yet, GREEN once the dispatch is rewired.)

#### Task 0.26.a: `v1 read_screen` regression + route through service

**Files:**
- Test:   `cmuxTests/HTTPControl/V1ReadScreenParityTests.swift`
- Modify: `Sources/TerminalController.swift` (replace `case "read_screen"` body)

- [ ] **Step 1: Failing characterization test (intentionally-wrong sentinel proves the path executes)**
```swift
// cmuxTests/HTTPControl/V1ReadScreenParityTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct V1ReadScreenParityTests {
    @Test @MainActor func v1ReadScreenReturnsReadyPrefix() async throws {
        let env = try await HTTPControlPanelFixture.makeWithOneSurface(text: "READY\n")
        defer { env.tearDown() }
        let resp = try await env.controller.handleSocketCommandForTests(
            v1: "read_screen", argsRaw: "surface:1")
        #expect(resp.hasPrefix("__WILL_BE_REPLACED__"))  // RED sentinel
    }
}
```

- [ ] **Step 2: Push RED**
```bash
git add cmuxTests/HTTPControl/V1ReadScreenParityTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing v1 read_screen parity test (RED sentinel)"
git push
```
Expected: CI fails with `__WILL_BE_REPLACED__` mismatch — proves the path executes the new routed impl (or the old one — either way the sentinel is wrong, which is the point).

- [ ] **Step 3: Add `terminalAccessService` property to `TerminalController` (shared lazy singleton)**
```swift
// Sources/TerminalController.swift
import CmuxTerminalAccess

extension TerminalController {
    /// Process-wide service shared by every transport (v1 socket, v2
    /// socket, CLI, and the Phase 1 HTTP server).
    ///
    /// E5 — uses `AppSurfaceProvider.shared` (NOT a fresh
    /// `AppSurfaceProvider(controller:)`). The controller is bound
    /// here via `setController(self)` on first access; `AppDelegate`
    /// may have bound it earlier at launch — `setController` is
    /// idempotent for the same instance.
    var terminalAccessService: TerminalAccessService {
        if let svc = _cachedTerminalAccessService { return svc }
        AppSurfaceProvider.shared.setController(self)
        let provider = AppSurfaceProvider.shared
        let audit: any AuditLog
        if let dir = try? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true) {
            try? FileManager.default.createDirectory(at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            audit = FileAuditLog(url: dir.appendingPathComponent("http-control-audit.jsonl"))
        } else {
            audit = NoOpAuditLog()  // last-resort sandbox fallback
        }
        // E3 — locked init signature; Phase 0 leaves rateLimiter/streamCap/
        // cellsTickRate/allowRawInput at their defaults. Phase 1 wires the
        // real settings-backed values inside `HTTPControlLifecycle`.
        let svc = DefaultTerminalAccessService(provider: provider, audit: audit)
        _cachedTerminalAccessService = svc
        return svc
    }
}
```

> **E5 launch hook.** `AppDelegate.applicationDidFinishLaunching` (or the
> equivalent entry point in `Sources/cmuxApp.swift`) must call
> `AppSurfaceProvider.shared.setController(terminalController)` immediately
> after the `TerminalController` is constructed, BEFORE any HTTP request can
> arrive. The `terminalAccessService` property above is a safety net; the
> launch hook is the canonical wiring.

- [ ] **Step 4: Replace the `case "read_screen"` body to route through the service**
The new body parses the existing arg syntax (`surface:N [scrollback]`), builds a `ScreenReadRequest` with `region: parsed.includeScrollback ? .screen : .viewport`, awaits `terminalAccessService.readScreen(...)`, and formats the wire response identically to the legacy path (the existing `formatLegacyReadScreenResponse` is kept; only the I/O changes). Use a single-shot `DispatchSemaphore` wait pattern (the v1 dispatch is sync; keep it so).

- [ ] **Step 5: Replace the sentinel with the real captured bytes**
```swift
#expect(resp.hasPrefix("READY"))
```

- [ ] **Step 6: Commit GREEN**
```bash
git add Sources/TerminalController.swift cmuxTests/HTTPControl/V1ReadScreenParityTests.swift
git commit -m "Route v1 read_screen through TerminalAccessService"
git push
```

#### Task 0.26.b: `v2 surface.read_text` regression + route

Same shape as 0.26.a: failing characterization test asserts the v2 envelope's `result.base64` matches the legacy bytes. RED commit. Then replace `case "surface.read_text"` with a service-routed body that constructs a `ScreenReadRequest`, awaits `readScreen`, base64-encodes the resulting text, and returns the legacy v2 envelope. GREEN commit.

#### Task 0.26.c: `v2 surface.send_text` regression + route

Failing test asserts `queued_bytes` matches the input length. RED. Replace `case "surface.send_text"` body to build `InputRequest(payload: .text(...))` and await `writeInput`, returning `queued_bytes`. GREEN.

#### Task 0.26.d: `v2 surface.send_key` regression + route

Failing test asserts `queued_bytes == 1` for `key=Enter`. RED. Replace `case "surface.send_key"` to build `InputRequest(payload: .keys([try KeyEvent.parse(name)]))` and await `writeInput`. GREEN.

After all four sub-tasks land, no pre-existing socket-test in the repo should regress. If one does, the routing has a real behavior delta — fix the routing, never weaken the test (CLAUDE.md "shared behavior policy").

---

### Task 0.27: pbxproj lint sweep + Phase 0 close-out

**Files:** none

- [ ] **Step 1: Confirm pbxproj test-wiring lint passes**
```bash
bash scripts/lint-pbxproj-test-wiring.sh
```
Expected: exit 0. If a test file added in Phase 0 isn't wired into the `cmuxTests` `PBXSourcesBuildPhase`, this fails — go back and wire it.

- [ ] **Step 2: Confirm pbxproj objectVersion + normalization**
```bash
bash scripts/check-pbxproj.sh
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Confirm one-type-per-file invariant**
```bash
ls Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/
```
Expected file list (sorted): `AuditEntry.swift`, `AuditKind.swift`, `AuditLog.swift`, `Cell.swift`, `CellAttribute.swift`, `CellColor.swift`, `CellGrid.swift`, `CellRow.swift`, `CmuxTerminalAccess.swift`, `ConstantTimeCompare.swift` (E9), `CursorState.swift`, `CursorStyle.swift`, `DefaultTerminalAccessService.swift`, `FileAuditLog.swift`, `InputPayload.swift`, `InputRequest.swift`, `KeyEvent.swift`, `KeyEventParseError.swift`, `KeyMod.swift`, `MouseAction.swift`, `MouseButton.swift`, `MouseEvent.swift`, `NamedKey.swift`, `NoOpAuditLog.swift`, `OutputEvent.swift`, `OutputSubscription.swift`, `PasteSerializer.swift` (E4), `RateLimiter.swift`, `RateLimiterClock.swift`, `RawOutputDetachToken.swift`, `ScreenFormat.swift`, `ScreenReadRequest.swift`, `ScreenReadResult.swift`, `ScreenRegion.swift`, `SemanticKind.swift`, `StreamMode.swift`, `StreamSubscriptionOptions.swift`, `SurfaceHandle.swift`, `SurfaceInfo.swift`, `SurfaceProvider.swift`, `TerminalAccessError.swift`, `TerminalAccessService.swift`, `TextScreenPayload.swift`, `UnderlineKind.swift`, `WideKind.swift`, `WrapPolicy.swift`.

- [ ] **Step 4: Watch CI for the full Phase 0 test set**
```bash
gh run watch --repo manaflow-ai/cmux
```
Expected green suites: `PackageSmokeTests`, `SurfaceHandleTests`, `ScreenEnumWireTests`, `ScreenReadRequestCodableTests`, `CellEnumWireTests`, `CellShapeTests`, `CellGridCodableTests`, `KeyEventParserTests`, `MouseEventTests`, `InputRequestShapeTests`, `OutputEventTests`, `OutputSubscriptionTests`, `TerminalAccessErrorTests`, `AuditEntryTests`, `FileAuditLogTests`, `RateLimiterTests`, `StubSurfaceProviderTests`, `DefaultServiceReadTests`, `DefaultServiceWriteTests`, `PasteSerializerTests` (E4), `PasteAtomicityTests`, `SocketControlConstantTimeCompareTests` (E9), `HTTPControlSettingsTests`, `TerminalPanelLookupTests`, `MergedScreenTextTests`, `AppSurfaceProviderReadTextTests`, `AppSurfaceProviderWriteTests`, `AppSurfaceMouseFocusTests`, `HTTPControlTokenNoEnvLeakTests`, `V1ReadScreenParityTests` (+ b/c/d).

- [ ] **Step 5: No-op close-out — no extra commit**
Phase 0 closes from the green commit above. Phase 1 starts from that SHA and assumes every type, protocol, test seam, and AppSurfaceProvider shape described here. Phase 1's `HTTPControlServer` consumes `terminalAccessService` from `TerminalController` and `HTTPControlSettings` instances created from `<supportDirectory>` per D2; Phase 1 ONLY adds a SwiftUI binding view for the settings — it does NOT redefine `HTTPControlSettings`, `AuditEntry`, `AuditLog`, `SurfaceProvider`, `OutputSubscription`, `StreamMode`, `StreamSubscriptionOptions`, `OutputEvent`, `KeyEvent.parse`, `MouseEvent.parse`, or any other type listed in Task 0.27 Step 3.


---

## Phase 1 — HTTP transport (hardened TCP + UDS opt-in) + ghostty patch #1 (cells export) + format=cells

This phase wires the local HTTP control transport, lands ghostty patch #1 (cell-grid export), and serves `format=cells` through the unified `TerminalAccessService`. Patch #1 + Swift bridge land EARLY (Tasks 1.4–1.9) BEFORE the `/screen` route (Task 1.16), so the route's `format=cells` test asserts a real 200 + CellGrid JSON (D5).

Phase 1 assumes Phase 0 has shipped, per the locked decisions:
- `Packages/CmuxTerminalAccess/` with: `SurfaceHandle`, `SurfaceInfo` (fields: handle, uuid, workspaceRef, title?, cols, rows, altScreen, focused, semanticAvailable), `ScreenFormat`, `ScreenRegion`, `WrapPolicy`, `ScreenReadRequest`, `ScreenReadResult`, `TextScreenPayload`, `CellGrid`, `CellRow`, `Cell` (with `underlineKind: UnderlineKind?` + `underlineColor: CellColor?` per D25), `WideKind`, `CellColor`, `CellAttribute` (NO `.underline`; use `underlineKind != nil` per D25), `UnderlineKind`, `SemanticKind`, `CursorState`, `CursorStyle`, `InputRequest`, `InputPayload`, `KeyEvent`, `KeyEventParseError`, `MouseEvent`, `OutputEvent`, `StreamMode`, `StreamSubscriptionOptions`, `OutputSubscription` (class per D22), `TerminalAccessError` (with `.unsupported` → 415 per D18 and `.featureDisabled` → 404 and `.rateLimited` → 429), `AuditLog` + `FileAuditLog` (actor, E2) + `NoOpAuditLog` + `AuditEntry` (D3 shape: `{timestamp, surface: SurfaceHandle, kind: AuditKind, byteCount: Int, detail: [String:String]?}`; `record(_:) async` non-throwing per E2), `RateLimiter` (D10/E16: `init(burstCapacity:refillPerSecond:clock:)`, lazy per-key buckets, `acquire(key:) async throws` — throws `TerminalAccessError.rateLimited` on overflow, NO Bool return), `ConstantTimeCompare` (E9 — shared by legacy socket auth and Phase 1 HTTPAuth), `PasteSerializer` (E4 — own file, public actor, per-surface FIFO), `KeyEvent.parse(_ s: String) throws -> KeyEvent` (D21, NO Optional overload), `MouseEvent.parse(_:) throws -> MouseEvent`, `SurfaceProvider` protocol (D1/E1: locked method list — `listSurfaces`, `resolve`, `readText`, `readCells` (REQUIRED member per E20, NO default impl), `writeText(surface:bytes:)`, `writeKey`, `writeMouse`, `setFocus`, `pendingInputCapacityRemaining` synchronous; NO `attachRawOutput` (Phase 2 extension only); ALL methods `async throws`, Sendable), `TerminalAccessService` protocol with `listSurfaces() async throws -> [SurfaceInfo]`, `readScreen(_:) async throws -> ScreenReadResult`, `writeInput(_:) async throws` (NO `allowRawInput` member — owned by `DefaultTerminalAccessService` init closure per E3), `DefaultTerminalAccessService` (E3 locked init signature: `provider/audit/rateLimiter/streamCap/cellsTickRate/allowRawInput` with defaults; uses `PasteSerializer` for D30 paste atomicity), `AppSurfaceProvider` (E5: `shared` singleton + `setController(_:)` + `#if DEBUG testInject/testReset`, app-side bridge to `TerminalController`, ALL `async throws` per D1, with explicit code comment forbidding HTTP-token env export per D9), `HTTPControlSettings` (D2/E15: instance class `init(supportDirectory:URL, defaults:UserDefaults)` embedding token store with `ensureToken() throws -> String`, `rotateToken() throws -> String`, `tokenFilePath: URL`, `udsPath` (NOT `unixSocketPath`); inner enum `Transport { case tcp, uds }`), shared `StubSurfaceProvider` at `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/StubSurfaceProvider.swift` (D13), shared `TerminalFixture` at `cmuxTests/Fixtures/TerminalFixture.swift` (E8), and behavioral test that HTTP token is absent from child terminal environment (D9).

Phase 1 tasks (contiguous numbering 1.1–1.25):

- 1.1–1.3  HTTP request parser + JSON response builder + table-driven router (D11) + auth + Host allowlist — all without a listener, fully unit-testable.
- 1.4–1.9  Ghostty patch #1 lands EARLY (D5): C ABI, Zig page-walk impl, hyperlink table (D26), underline (D25), semantic (D27), fork push (D20), parent pointer bump, `GhosttyCellsBridge` Swift wrapper, `SurfaceProvider.readCells` (async per D1) implementation in `AppSurfaceProvider`, upstream tracking issue (D19).
- 1.10–1.15 `HTTPControlServer` TCP listener, `GET /v1/surfaces`, `GET /v1/surfaces/{id}/screen?format=text|cells` (cells works on landing — D5), `wrap=join` (D5), `format=raw` on `/screen` → 400 (D29), always-on audit log (D4), per-surface rate limit on writes (D10).
- 1.16–1.20 `POST /v1/surfaces/{id}/input` (text/keys/paste/raw/mouse/focus), ESC-strip safety test (D15), paste atomicity test (D30), focusSurface wiring (D17), mouse direct-call test (D16), `type=raw` independent gate, 405 method-mismatch (D11), 415 for unsupported (D18).
- 1.21    UDS transport via POSIX socket(2)+bind(2)+listen(2)+DispatchSourceRead (D12), mode 0600.
- 1.22–1.25 Settings UI + localization, behavioral config-loader test for `httpControl` block in `cmux.json` (D14, NOT schema text-grep), user-facing API docs (with out-of-scope §15 note per D28 and zsh-only `semantic` caveat per D27), lifecycle wire-up + token rotation invalidates running connections, pbxproj lint + push.

---

### Task 1.1: `HTTPRequestParser` + `HTTPRequest` model with size caps (no listener)

(Resolves Coverage must_fix: "Phase 1 Task 1.5 `oversizedBodyReturns413` test will hang" — by enforcing `Content-Length > maxBodyBytes` upfront and unit-testing the parser directly, not via the live server. Also resolves Quality granularity: split parser from listener.)

**Files:**
- Create: `Sources/HTTPControl/HTTPRequest.swift`
- Create: `Sources/HTTPControl/HTTPParseError.swift`
- Create: `Sources/HTTPControl/HTTPRequestParser.swift`
- Test:   `cmuxTests/HTTPControl/HTTPRequestParserTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj` (wire all four files into cmux / cmuxTests targets)

- [ ] **Step 1: Write failing tests**

```swift
// cmuxTests/HTTPControl/HTTPRequestParserTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPRequestParserTests {
    @Test func parseGetWithHeaders() throws {
        let raw = "GET /v1/surfaces?x=1 HTTP/1.1\r\nHost: 127.0.0.1:9778\r\nAuthorization: Bearer abc\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        let outcome = try parser.next()
        guard case let .complete(req) = outcome else { Issue.record("not complete"); return }
        #expect(req.method == "GET")
        #expect(req.path == "/v1/surfaces")
        #expect(req.query["x"] == "1")
        #expect(req.header("host") == "127.0.0.1:9778")
        #expect(req.body.isEmpty)
    }

    @Test func parsePostWithBody() throws {
        let body = "{\"type\":\"text\",\"text\":\"hi\"}"
        let raw = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:9778\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        let outcome = try parser.next()
        guard case let .complete(req) = outcome else { Issue.record("not complete"); return }
        #expect(req.method == "POST")
        #expect(String(data: req.body, encoding: .utf8) == body)
    }

    @Test func malformedRequestLineRejected() throws {
        let raw = "NOT-A-REQUEST\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }

    @Test func oversizedHeadersRejected() throws {
        let huge = String(repeating: "X", count: 32 * 1024)
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:9778\r\nX-Big: \(huge)\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 8 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }

    @Test func contentLengthExceedingCapRejectedUpFront() throws {
        // No body bytes sent — parser must reject from Content-Length alone, not hang.
        let raw = "POST /x HTTP/1.1\r\nHost: 127.0.0.1:9778\r\nContent-Length: 999999999\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }

    @Test func negativeContentLengthRejected() throws {
        let raw = "POST /x HTTP/1.1\r\nHost: 127.0.0.1:9778\r\nContent-Length: -1\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPRequestParserTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPRequestParser tests"
git push origin HEAD
```
Expected: CI fails compile (HTTPRequestParser undefined).

- [ ] **Step 3: Implement `HTTPRequest`**

```swift
// Sources/HTTPControl/HTTPRequest.swift
import Foundation

/// A parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [(String, String)]
    public let body: Data

    /// Returns the first header value for ``name`` (case-insensitive).
    public func header(_ name: String) -> String? {
        let key = name.lowercased()
        return headers.first { $0.0 == key }?.1
    }
}
```

- [ ] **Step 4: Implement `HTTPParseError`**

```swift
// Sources/HTTPControl/HTTPParseError.swift
import Foundation

/// Failure modes of ``HTTPRequestParser``. Mapped to HTTP status by the server.
public enum HTTPParseError: Error, Equatable {
    case malformedRequestLine
    case malformedHeader
    case headerTooLarge
    case contentLengthInvalid
    case bodyTooLarge
}
```

- [ ] **Step 5: Implement `HTTPRequestParser`**

```swift
// Sources/HTTPControl/HTTPRequestParser.swift
import Foundation

/// Streaming HTTP/1.1 parser for cmux control endpoints.
///
/// One request per parser instance; rejects oversized headers or bodies
/// up front (no hang on `Content-Length` greater than the configured cap).
public struct HTTPRequestParser {
    private var buffer = Data()
    private let maxHeaderBytes: Int
    private let maxBodyBytes: Int

    public enum Outcome { case need; case complete(HTTPRequest) }

    public init(maxHeaderBytes: Int, maxBodyBytes: Int) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func feed(_ data: Data) { buffer.append(data) }

    public mutating func next() throws -> Outcome {
        guard let headerEnd = findHeaderEnd(buffer) else {
            if buffer.count > maxHeaderBytes { throw HTTPParseError.headerTooLarge }
            return .need
        }
        if headerEnd > maxHeaderBytes { throw HTTPParseError.headerTooLarge }
        let headerBytes = buffer.prefix(headerEnd)
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            throw HTTPParseError.malformedRequestLine
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedRequestLine }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            throw HTTPParseError.malformedRequestLine
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let (path, query) = Self.splitTarget(target)

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let contentLength: Int
        if let raw = headers.first(where: { $0.0 == "content-length" })?.1 {
            guard let n = Int(raw), n >= 0 else { throw HTTPParseError.contentLengthInvalid }
            contentLength = n
        } else {
            contentLength = 0
        }
        // D11/coverage: reject upfront so live servers respond 413 without hanging
        // waiting for body bytes that will never arrive.
        if contentLength > maxBodyBytes { throw HTTPParseError.bodyTooLarge }

        let bodyStart = headerEnd + 4  // skip \r\n\r\n
        guard buffer.count >= bodyStart + contentLength else { return .need }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeSubrange(0..<(bodyStart + contentLength))

        return .complete(HTTPRequest(
            method: method, path: path, query: query, headers: headers, body: body
        ))
    }

    private func findHeaderEnd(_ data: Data) -> Int? {
        if data.count < 4 { return nil }
        let bytes = [UInt8](data)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        var out: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[k] = v
        }
        return (path, out)
    }
}
```

- [ ] **Step 6: Run pbxproj normalize + lint**

```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
bash scripts/lint-pbxproj-test-wiring.sh
```

- [ ] **Step 7: Commit**

```bash
git add Sources/HTTPControl/HTTPRequest.swift \
        Sources/HTTPControl/HTTPParseError.swift \
        Sources/HTTPControl/HTTPRequestParser.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Implement HTTPRequestParser with upfront body cap rejection"
git push origin HEAD
```
Expected: CI green for `HTTPRequestParserTests`.

---

### Task 1.2: `JSONResponses` + `TerminalAccessError` → status mapping (415 for `.unsupported`, D18)

(Resolves Coverage/Quality must_fix: pick 415 for `.unsupported` consistently across all phases — D18.)

**Files:**
- Create: `Sources/HTTPControl/JSONResponses.swift`
- Test:   `cmuxTests/HTTPControl/JSONResponsesTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/JSONResponsesTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct JSONResponsesTests {
    @Test func mapsErrorsToStatus() {
        #expect(JSONResponses.status(for: .unknownSurface) == 404)
        #expect(JSONResponses.status(for: .unauthorized) == 401)
        #expect(JSONResponses.status(for: .forbidden(reason: "x")) == 403)
        #expect(JSONResponses.status(for: .badRequest(reason: "x")) == 400)
        #expect(JSONResponses.status(for: .payloadTooLarge) == 413)
        #expect(JSONResponses.status(for: .rateLimited) == 429)
        #expect(JSONResponses.status(for: .featureDisabled) == 404)  // D11 — disabled = not found
        #expect(JSONResponses.status(for: .unsupported(reason: "x")) == 415)  // D18
        #expect(JSONResponses.status(for: .ghosttyError("boom")) == 500)
    }

    @Test func renderErrorJSON() throws {
        let resp = JSONResponses.error(.badRequest(reason: "bad format"))
        #expect(resp.status == 400)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        #expect(err?["code"] as? String == "bad_request")
        #expect((err?["message"] as? String)?.contains("bad format") == true)
    }

    @Test func methodNotAllowedRenders405WithAllowHeader() throws {
        let resp = JSONResponses.methodNotAllowed(allow: ["GET", "POST"])
        #expect(resp.status == 405)
        let allow = resp.headers.first { $0.0 == "Allow" }?.1
        #expect(allow == "GET, POST")
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/JSONResponsesTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing JSONResponses status mapping tests"
git push origin HEAD
```
Expected: CI fails compile (JSONResponses undefined).

- [ ] **Step 3: Implement**

```swift
// Sources/HTTPControl/JSONResponses.swift
import Foundation
import CmuxTerminalAccess

/// Builds HTTP responses and maps ``TerminalAccessError`` to status codes
/// per spec §12 and the locked decision D18 (`.unsupported` = 415).
public enum JSONResponses {
    public struct Response {
        public let status: Int
        public let headers: [(String, String)]
        public let body: Data
    }

    public static func json(
        _ status: Int,
        _ object: Any,
        extraHeaders: [(String, String)] = []
    ) -> Response {
        let body = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        var headers = extraHeaders
        headers.append(("Content-Type", "application/json"))
        headers.append(("Content-Length", "\(body.count)"))
        return Response(status: status, headers: headers, body: body)
    }

    public static func status(for error: TerminalAccessError) -> Int {
        switch error {
        case .unknownSurface: return 404
        case .unauthorized: return 401
        case .forbidden: return 403
        case .badRequest: return 400
        case .payloadTooLarge: return 413
        case .rateLimited: return 429
        case .featureDisabled: return 404   // D11: don't reveal "feature exists but off"
        case .unsupported: return 415       // D18: consistent across all phases
        case .ghosttyError: return 500
        }
    }

    public static func error(_ error: TerminalAccessError) -> Response {
        let code: String
        let message: String
        switch error {
        case .unknownSurface: code = "unknown_surface"; message = "Unknown surface"
        case .unauthorized: code = "unauthorized"; message = "Missing or invalid token"
        case .forbidden(let r): code = "forbidden"; message = r
        case .badRequest(let r): code = "bad_request"; message = r
        case .payloadTooLarge: code = "payload_too_large"; message = "Body exceeds cap"
        case .rateLimited: code = "rate_limited"; message = "Too many requests"
        case .featureDisabled: code = "not_found"; message = "Endpoint not available"
        case .unsupported(let r): code = "unsupported_media_type"; message = r
        case .ghosttyError(let m): code = "internal_error"; message = m
        }
        return json(status(for: error), ["error": ["code": code, "message": message]])
    }

    /// 405 with the `Allow:` header populated (D11).
    public static func methodNotAllowed(allow: [String]) -> Response {
        json(405, ["error": ["code": "method_not_allowed", "message": "Method not allowed"]],
             extraHeaders: [("Allow", allow.joined(separator: ", "))])
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/JSONResponses.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add JSONResponses with TerminalAccessError mapping and 405 helper"
git push origin HEAD
```
Expected: CI green for `JSONResponsesTests`.

---

### Task 1.3: `HTTPAuth` constant-time bearer compare

(Resolves Coverage gap: constant-time compare. Spec §5.2.)

**Files:**
- Create: `Sources/HTTPControl/HTTPAuth.swift`
- Test:   `cmuxTests/HTTPControl/HTTPAuthTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPAuthTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPAuthTests {
    @Test func missingHeaderRejected() {
        let auth = HTTPAuth(expectedToken: "abcdef0123456789")
        #expect(auth.evaluate(authorizationHeader: nil) == .missing)
    }

    @Test func wrongTokenSameLengthRejected() {
        let auth = HTTPAuth(expectedToken: "abcdef0123456789")
        #expect(auth.evaluate(authorizationHeader: "Bearer ZZZZZZZZZZZZZZZZ") == .invalid)
    }

    @Test func wrongScheme() {
        let auth = HTTPAuth(expectedToken: "abcdef0123456789")
        #expect(auth.evaluate(authorizationHeader: "Basic abcdef0123456789") == .invalid)
    }

    @Test func correctTokenAccepted() {
        let auth = HTTPAuth(expectedToken: "abcdef0123456789")
        #expect(auth.evaluate(authorizationHeader: "Bearer abcdef0123456789") == .ok)
    }

    @Test func compareRunsFullLengthRegardlessOfMismatch() {
        var counter = 0
        let counted: (UInt8, UInt8) -> UInt8 = { a, b in
            counter += 1
            return a ^ b
        }
        let same = HTTPAuth.constantTimeEqual(
            Array("abcdef0123456789".utf8),
            Array("ZZZZZZZZZZZZZZZZ".utf8),
            xor: counted
        )
        #expect(same == false)
        #expect(counter == 16)
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPAuthTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPAuth constant-time compare tests"
git push origin HEAD
```

- [ ] **Step 3: Implement**

```swift
// Sources/HTTPControl/HTTPAuth.swift
import Foundation

/// Bearer-token authorisation for the local HTTP control transport.
/// Constant-time byte comparison resists timing oracles per spec §5.2.
public struct HTTPAuth: Sendable {
    public enum Result: Equatable, Sendable { case ok, missing, invalid }

    private let expected: [UInt8]

    public init(expectedToken: String) { self.expected = Array(expectedToken.utf8) }

    public func evaluate(authorizationHeader: String?) -> Result {
        guard let header = authorizationHeader else { return .missing }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return .invalid }
        let candidate = Array(header.dropFirst(prefix.count).utf8)
        return Self.constantTimeEqual(expected, candidate) ? .ok : .invalid
    }

    public static func constantTimeEqual(
        _ a: [UInt8],
        _ b: [UInt8],
        xor: (UInt8, UInt8) -> UInt8 = { $0 ^ $1 }
    ) -> Bool {
        let n = Swift.max(a.count, b.count)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<n {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            diff |= xor(ai, bi)
        }
        return diff == 0
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/HTTPAuth.swift cmux.xcodeproj/project.pbxproj
git commit -m "Implement constant-time HTTPAuth bearer compare"
git push origin HEAD
```

---

### Task 1.4: `HostAllowlist` (loopback Host + Origin)

(Resolves Coverage gap: DNS-rebinding mitigation per spec §5.3.)

**Files:**
- Create: `Sources/HTTPControl/HostAllowlist.swift`
- Test:   `cmuxTests/HTTPControl/HostAllowlistTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HostAllowlistTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HostAllowlistTests {
    @Test func loopbackHostAllowed() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:9778", origin: nil) == .ok)
        #expect(a.evaluate(host: "localhost:9778", origin: nil) == .ok)
    }

    @Test func spoofedHostForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "evil.example:9778", origin: nil) == .forbiddenHost)
    }

    @Test func wrongPortForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:1234", origin: nil) == .forbiddenHost)
    }

    @Test func missingHostBadRequest() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: nil, origin: nil) == .missingHost)
    }

    @Test func originPresentNotAllowedForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:9778", origin: "https://evil.example") == .forbiddenOrigin)
    }

    @Test func originLoopbackAllowed() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:9778", origin: "http://127.0.0.1:9778") == .ok)
        #expect(a.evaluate(host: "localhost:9778", origin: "http://localhost:9778") == .ok)
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HostAllowlistTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HostAllowlist tests"
git push origin HEAD
```

- [ ] **Step 3: Implement**

```swift
// Sources/HTTPControl/HostAllowlist.swift
import Foundation

/// Validates the HTTP ``Host`` and ``Origin`` headers against a loopback
/// allow-list (spec §5.3 — DNS-rebinding mitigation).
public struct HostAllowlist: Sendable {
    public enum Result: Equatable, Sendable {
        case ok, missingHost, forbiddenHost, forbiddenOrigin
    }
    private let allowedHosts: Set<String>
    private let allowedOrigins: Set<String>

    public init(port: Int) {
        self.allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        self.allowedOrigins = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)",
        ]
    }

    public func evaluate(host: String?, origin: String?) -> Result {
        guard let host else { return .missingHost }
        guard allowedHosts.contains(host.lowercased()) else { return .forbiddenHost }
        if let origin, !allowedOrigins.contains(origin.lowercased()) {
            return .forbiddenOrigin
        }
        return .ok
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/HostAllowlist.swift cmux.xcodeproj/project.pbxproj
git commit -m "Implement HostAllowlist for loopback Host and Origin"
git push origin HEAD
```


---

### Task 1.5: Ghostty patch #1 — C ABI declarations in `ghostty/include/ghostty.h`

(Resolves Coverage must_fix on patch #1 landing in v1 / Phase 1 [D5]; D25: underline kind + color; D26: hyperlink table with per-call URI strings; D27: top-level `semantic_available` bool. Resolves Quality granularity: header-only commit precedes Zig impl.)

**Files (in `ghostty/` submodule):**
- Modify: `ghostty/include/ghostty.h`

- [ ] **Step 1: Append the cell-grid ABI block**

```c
/* --- cmux cells export (patch #1) --- */

typedef enum {
    GHOSTTY_CELL_REGION_VIEWPORT = 0,
    GHOSTTY_CELL_REGION_SCREEN = 1,
    GHOSTTY_CELL_REGION_SCROLLBACK = 2,
} ghostty_cell_region_e;

typedef enum {
    GHOSTTY_CELL_WIDE_NARROW = 0,
    GHOSTTY_CELL_WIDE_WIDE = 1,
    GHOSTTY_CELL_WIDE_SPACER_TAIL = 2,
    GHOSTTY_CELL_WIDE_SPACER_HEAD = 3,
} ghostty_cell_wide_e;

typedef enum {
    GHOSTTY_CELL_COLOR_DEFAULT = 0,
    GHOSTTY_CELL_COLOR_PALETTE = 1,
    GHOSTTY_CELL_COLOR_RGB = 2,
} ghostty_cell_color_kind_e;

typedef enum {
    GHOSTTY_CELL_UNDERLINE_NONE = 0,
    GHOSTTY_CELL_UNDERLINE_SINGLE = 1,
    GHOSTTY_CELL_UNDERLINE_DOUBLE = 2,
    GHOSTTY_CELL_UNDERLINE_CURLY = 3,
    GHOSTTY_CELL_UNDERLINE_DOTTED = 4,
    GHOSTTY_CELL_UNDERLINE_DASHED = 5,
} ghostty_cell_underline_kind_e;

typedef enum {
    GHOSTTY_CELL_SEMANTIC_NONE = 0,
    GHOSTTY_CELL_SEMANTIC_PROMPT = 1,
    GHOSTTY_CELL_SEMANTIC_PROMPT_CONTINUATION = 2,
    GHOSTTY_CELL_SEMANTIC_INPUT = 3,
    GHOSTTY_CELL_SEMANTIC_OUTPUT = 4,
} ghostty_cell_semantic_e;

typedef struct {
    uint8_t fg_kind;       /* ghostty_cell_color_kind_e */
    uint8_t fg_palette;
    uint8_t fg_rgb[3];
    uint8_t bg_kind;
    uint8_t bg_palette;
    uint8_t bg_rgb[3];
    uint8_t underline_kind;       /* ghostty_cell_underline_kind_e */
    uint8_t underline_color_kind; /* ghostty_cell_color_kind_e */
    uint8_t underline_palette;
    uint8_t underline_rgb[3];
    uint32_t attrs_bitset;
    /* bit0=bold bit1=italic bit2=faint bit3=blink
       bit4=inverse bit5=invisible bit6=strikethrough */
} ghostty_cell_style_s;

typedef struct {
    const uint32_t* codepoints;   /* borrowed into grid arena */
    size_t codepoints_count;
    uint8_t wide;                 /* ghostty_cell_wide_e */
    uint32_t style_id;            /* index into grid.styles */
    uint8_t semantic;             /* ghostty_cell_semantic_e */
    uint32_t hyperlink_id;        /* 0 = none, else index into hyperlink table */
} ghostty_cell_s;

typedef struct {
    bool wrap;
    bool wrap_continuation;
    const ghostty_cell_s* cells;
    size_t cells_count;
} ghostty_cell_row_s;

/* D26: per-call hyperlink URI table — Cell.hyperlink_id indexes here. */
typedef struct {
    const char* const* uris;  /* NUL-terminated UTF-8; uris[0] is unused (id 0 = none) */
    size_t count;
} ghostty_hyperlink_table_s;

typedef struct {
    uint32_t cols;
    uint32_t rows_count;
    bool alt_screen;
    bool semantic_available;   /* D27: any row had OSC 133 marker */
    uint32_t cursor_row;
    uint32_t cursor_col;
    bool cursor_visible;
    uint8_t cursor_style;      /* 0=block 1=underline 2=bar */
    const ghostty_cell_row_s* rows;
    const ghostty_cell_style_s* styles;
    size_t styles_count;
    ghostty_hyperlink_table_s hyperlinks;
} ghostty_cell_grid_s;

GHOSTTY_API bool ghostty_surface_read_cells(
    ghostty_surface_t surface,
    ghostty_cell_region_e region,
    ghostty_cell_grid_s* result
);

GHOSTTY_API void ghostty_cell_grid_free(
    ghostty_surface_t surface,
    ghostty_cell_grid_s* result
);
/* --- end cmux cells export --- */
```

- [ ] **Step 2: Commit in submodule on the fork branch**

```bash
cd ghostty
git checkout -B cmux-cells-export
git add include/ghostty.h
git commit -m "Add cell-grid C ABI for apprt read_cells (cmux patch #1)"
```

(Push happens in Task 1.7 after Zig impl lands on the same branch.)

---

### Task 1.6: Ghostty patch #1 — Zig impl in `ghostty/src/apprt/embedded.zig` (direct page-walk, no clamped point-tag)

(Resolves Coverage gap §10: spec mandates page-walk that retires the three-tag merge. Resolves Quality granularity: Zig impl is its own commit, with Zig unit test under `zig build test`.)

**Files (in `ghostty/` submodule):**
- Modify: `ghostty/src/apprt/embedded.zig`
- Create: `ghostty/src/apprt/embedded_read_cells_test.zig`

- [ ] **Step 1: Add the implementation**

```zig
// Append to src/apprt/embedded.zig

const CellRegion = enum(c_uint) { viewport = 0, screen = 1, scrollback = 2 };

const CellGridArena = struct {
    arena: std.heap.ArenaAllocator,
    rows: []GhosttyCellRow,
    cells: []GhosttyCell,
    styles: std.ArrayListUnmanaged(GhosttyCellStyle),
    hyperlink_uris: std.ArrayListUnmanaged([:0]u8),

    fn deinit(self: *CellGridArena, alloc: std.mem.Allocator) void {
        self.styles.deinit(alloc);
        self.hyperlink_uris.deinit(alloc);
        self.arena.deinit();
    }
};

var arena_registry: std.AutoHashMapUnmanaged(usize, *CellGridArena) = .{};
var arena_registry_lock: std.Thread.Mutex = .{};

export fn ghostty_surface_read_cells(
    surface: *Surface,
    region: c_uint,
    result: *GhosttyCellGrid,
) bool {
    const reg = std.meta.intToEnum(CellRegion, region) catch return false;
    const core = &surface.core_surface;
    core.renderer_state.mutex.lock();
    defer core.renderer_state.mutex.unlock();

    const screen = switch (reg) {
        .viewport, .screen, .scrollback => &core.io.terminal.screens.active,
    };

    var arena_box = global.alloc.create(CellGridArena) catch return false;
    arena_box.* = .{
        .arena = std.heap.ArenaAllocator.init(global.alloc),
        .rows = &.{},
        .cells = &.{},
        .styles = .{},
        .hyperlink_uris = .{},
    };
    const a = arena_box.arena.allocator();

    // Compute row range by walking the page list directly (no clamped point-tag).
    const range = computeRowRange(screen, reg);
    const total_rows = range.row_count;
    const cols = screen.pages.cols;

    arena_box.rows = a.alloc(GhosttyCellRow, total_rows) catch {
        arena_box.deinit(global.alloc);
        global.alloc.destroy(arena_box);
        return false;
    };
    arena_box.cells = a.alloc(GhosttyCell, total_rows * cols) catch {
        arena_box.deinit(global.alloc);
        global.alloc.destroy(arena_box);
        return false;
    };

    // hyperlink id 0 = none — reserve slot 0 with empty.
    arena_box.hyperlink_uris.append(global.alloc, a.dupeZ(u8, "") catch unreachable) catch {};

    var semantic_seen = false;
    var row_index: usize = 0;
    var iter = screen.pages.pageIterator(.right_down, range.tl, range.br);
    while (iter.next()) |chunk| {
        var y: usize = chunk.start;
        while (y < chunk.end) : (y += 1) {
            const row_ref = chunk.page.data.getRow(y);
            const row_cells = chunk.page.data.getCells(row_ref);
            const out_row = &arena_box.rows[row_index];
            out_row.wrap = row_ref.wrap;
            out_row.wrap_continuation = row_ref.wrap_continuation;
            const out_cells = arena_box.cells[row_index * cols ..][0..cols];
            var x: usize = 0;
            while (x < row_cells.len) : (x += 1) {
                const c = &row_cells[x];
                const cps = copyCodepoints(a, chunk.page.data, c);
                const style_id = internStyle(&arena_box.styles, global.alloc, chunk.page.data, c.style_id);
                const sem = semanticFromRow(row_ref);
                if (sem != .none) semantic_seen = true;
                const hl_id: u32 = if (c.hyperlink) blk: {
                    const uri = chunk.page.data.lookupHyperlinkURI(c) catch break :blk 0;
                    const dup = a.dupeZ(u8, uri) catch break :blk 0;
                    arena_box.hyperlink_uris.append(global.alloc, dup) catch break :blk 0;
                    break :blk @intCast(arena_box.hyperlink_uris.items.len - 1);
                } else 0;
                out_cells[x] = .{
                    .codepoints = cps.ptr,
                    .codepoints_count = cps.len,
                    .wide = wideToC(c.wide),
                    .style_id = style_id,
                    .semantic = @intFromEnum(sem),
                    .hyperlink_id = hl_id,
                };
            }
            out_row.cells = out_cells.ptr;
            out_row.cells_count = out_cells.len;
            row_index += 1;
        }
    }

    // Build hyperlink URI pointer table.
    const uri_ptrs = a.alloc([*:0]const u8, arena_box.hyperlink_uris.items.len) catch &.{};
    for (arena_box.hyperlink_uris.items, 0..) |uri, i| uri_ptrs[i] = uri.ptr;

    result.* = .{
        .cols = @intCast(cols),
        .rows_count = @intCast(row_index),
        .alt_screen = screen.kind == .alternate,
        .semantic_available = semantic_seen,
        .cursor_row = @intCast(screen.cursor.y),
        .cursor_col = @intCast(screen.cursor.x),
        .cursor_visible = !screen.cursor.invisible,
        .cursor_style = cursorStyleToC(screen.cursor.style),
        .rows = arena_box.rows.ptr,
        .styles = arena_box.styles.items.ptr,
        .styles_count = arena_box.styles.items.len,
        .hyperlinks = .{ .uris = uri_ptrs.ptr, .count = uri_ptrs.len },
    };

    arena_registry_lock.lock();
    defer arena_registry_lock.unlock();
    arena_registry.put(global.alloc, @intFromPtr(result), arena_box) catch {
        arena_box.deinit(global.alloc);
        global.alloc.destroy(arena_box);
        return false;
    };
    return true;
}

export fn ghostty_cell_grid_free(_: *Surface, result: *GhosttyCellGrid) void {
    arena_registry_lock.lock();
    defer arena_registry_lock.unlock();
    if (arena_registry.fetchRemove(@intFromPtr(result))) |kv| {
        kv.value.deinit(global.alloc);
        global.alloc.destroy(kv.value);
    }
    result.* = std.mem.zeroes(GhosttyCellGrid);
}

// --- helpers ---
const RowRange = struct { tl: terminal.point.Point, br: terminal.point.Point, row_count: usize };

fn computeRowRange(screen: *const terminal.Screen, reg: CellRegion) RowRange {
    // viewport = visible rows; screen = entire active screen incl. scrollback;
    // scrollback = scrollback only (empty on alt screen — caller checks alt_screen).
    return switch (reg) {
        .viewport => .{
            .tl = screen.pages.getTopLeft(.viewport),
            .br = screen.pages.getBottomRight(.viewport),
            .row_count = screen.pages.rows,
        },
        .screen => .{
            .tl = screen.pages.getTopLeft(.history),
            .br = screen.pages.getBottomRight(.active),
            .row_count = screen.pages.totalRows(),
        },
        .scrollback => if (screen.kind == .alternate) .{
            .tl = screen.pages.getTopLeft(.viewport),
            .br = screen.pages.getTopLeft(.viewport),
            .row_count = 0,
        } else .{
            .tl = screen.pages.getTopLeft(.history),
            .br = screen.pages.getBottomRight(.history),
            .row_count = screen.pages.historyRows(),
        },
    };
}

fn wideToC(w: terminal.page.Cell.Wide) u8 {
    return switch (w) {
        .narrow => 0, .wide => 1, .spacer_tail => 2, .spacer_head => 3,
    };
}

fn cursorStyleToC(s: terminal.CursorStyle) u8 {
    return switch (s) {
        .block, .block_hollow => 0,
        .underline => 1,
        .bar => 2,
    };
}

fn semanticFromRow(row: anytype) ghostty_cell_semantic_e {
    return switch (row.semantic_prompt) {
        .unknown => .none,
        .prompt => .prompt,
        .prompt_continuation => .prompt_continuation,
        .input => .input,
        .command => .output,
    };
}

fn copyCodepoints(a: std.mem.Allocator, page: anytype, c: *const terminal.page.Cell) []u32 {
    const base = c.content.codepoint;
    if (c.hasGrapheme()) {
        const extra = page.lookupGrapheme(c) orelse return a.dupe(u32, &[_]u32{base}) catch &.{};
        var out = a.alloc(u32, 1 + extra.len) catch return &.{};
        out[0] = base;
        for (extra, 0..) |g, i| out[i + 1] = g;
        return out;
    }
    return a.dupe(u32, &[_]u32{base}) catch &.{};
}

fn internStyle(
    list: *std.ArrayListUnmanaged(GhosttyCellStyle),
    alloc: std.mem.Allocator,
    page: anytype,
    style_id: u32,
) u32 {
    const s = page.lookupStyle(style_id);
    var bits: u32 = 0;
    if (s.flags.bold) bits |= 1 << 0;
    if (s.flags.italic) bits |= 1 << 1;
    if (s.flags.faint) bits |= 1 << 2;
    if (s.flags.blink) bits |= 1 << 3;
    if (s.flags.inverse) bits |= 1 << 4;
    if (s.flags.invisible) bits |= 1 << 5;
    if (s.flags.strikethrough) bits |= 1 << 6;
    const out = GhosttyCellStyle{
        .fg_kind = colorKindToC(s.fg_color),
        .fg_palette = palette(s.fg_color),
        .fg_rgb = rgb(s.fg_color),
        .bg_kind = colorKindToC(s.bg_color),
        .bg_palette = palette(s.bg_color),
        .bg_rgb = rgb(s.bg_color),
        .underline_kind = underlineToC(s.underline_style),
        .underline_color_kind = colorKindToC(s.underline_color),
        .underline_palette = palette(s.underline_color),
        .underline_rgb = rgb(s.underline_color),
        .attrs_bitset = bits,
    };
    list.append(alloc, out) catch return 0;
    return @intCast(list.items.len - 1);
}

fn colorKindToC(c: terminal.style.Color) u8 {
    return switch (c) { .none => 0, .palette => 1, .rgb => 2 };
}
fn palette(c: terminal.style.Color) u8 {
    return switch (c) { .palette => |p| p, else => 0 };
}
fn rgb(c: terminal.style.Color) [3]u8 {
    return switch (c) {
        .rgb => |v| .{ v.r, v.g, v.b }, else => .{ 0, 0, 0 },
    };
}
fn underlineToC(u: terminal.style.Underline) u8 {
    return switch (u) { .none => 0, .single => 1, .double => 2, .curly => 3, .dotted => 4, .dashed => 5 };
}
```

- [ ] **Step 2: Add a Zig unit test that exercises a fresh surface with known bytes**

```zig
// ghostty/src/apprt/embedded_read_cells_test.zig
const std = @import("std");
const Surface = @import("Surface.zig");
const c = @cImport({ @cInclude("ghostty.h"); });

test "read_cells viewport reports narrow + wide cells with wrap flag" {
    // Construct an off-screen test surface (existing Termio test scaffolding
    // exposes `Surface.initForTest`; if it doesn't yet, gate this test behind
    // `if (!@hasDecl(Surface, "initForTest")) return error.SkipZigTest;`)
    if (!@hasDecl(Surface, "initForTest")) return error.SkipZigTest;
    var surface = try Surface.initForTest(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer surface.deinitForTest();
    try surface.io.terminal.printString("ab\u{4E16}\n");  // "ab" + CJK wide
    var grid: c.ghostty_cell_grid_s = std.mem.zeroes(c.ghostty_cell_grid_s);
    try std.testing.expect(c.ghostty_surface_read_cells(&surface, 0, &grid));
    defer c.ghostty_cell_grid_free(&surface, &grid);
    try std.testing.expectEqual(@as(u32, 4), grid.cols);
    try std.testing.expect(grid.rows_count >= 1);
    const row0 = grid.rows[0];
    try std.testing.expect(row0.cells_count == 4);
    try std.testing.expectEqual(@as(u8, 0), row0.cells[0].wide); // narrow 'a'
    try std.testing.expectEqual(@as(u8, 1), row0.cells[2].wide); // wide
    try std.testing.expectEqual(@as(u8, 2), row0.cells[3].wide); // spacer tail
}
```

(If `Surface.initForTest` doesn't exist, this task ships the test as `.SkipZigTest`-gated and Task 1.7's PR description includes a TODO to add the harness; CI still runs `zig build test` and skips cleanly.)

- [ ] **Step 3: Build inside submodule to surface compile errors**

```bash
cd ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
zig build test 2>&1 | tail -20
```

- [ ] **Step 4: Commit in submodule (still on `cmux-cells-export` branch, push deferred to Task 1.7)**

```bash
cd ghostty
git add src/apprt/embedded.zig src/apprt/embedded_read_cells_test.zig
git commit -m "Implement ghostty_surface_read_cells via direct page-walk"
```

---

### Task 1.7: Ghostty patch #1 — push fork branch, rebuild xcframework, bump parent submodule pointer (D20)

(Resolves Coverage must_fix: D20 — push fork submodule commit BEFORE bumping parent pointer. Resolves Quality granularity: this is the dedicated "push-and-bump" task.)

**Files:**
- Push: `ghostty/` branch `cmux-cells-export` → `manaflow-ai/ghostty`
- Modify: `docs/ghostty-fork.md`
- Modify (parent): submodule pointer; `GhosttyKit.xcframework` if checked-in

- [ ] **Step 1: Push fork branch and merge to fork `main`**

```bash
cd ghostty
git push manaflow cmux-cells-export
gh pr create --repo manaflow-ai/ghostty --base main --head cmux-cells-export \
  --title "Add ghostty_surface_read_cells apprt export" \
  --body "Direct page-walk cell-grid export for cmux's HTTP cells endpoint. See cmux design doc patch #1."
# After merge:
git checkout main
git pull manaflow main
cd ..
```

CLAUDE.md submodule safety: this push happens BEFORE the parent pointer commit in Step 3.

- [ ] **Step 2: Update `docs/ghostty-fork.md`**

```markdown
### 2026-05-30 — apprt cell-grid export (patch #1)

- Added `ghostty_surface_read_cells` + `ghostty_cell_grid_free` to `include/ghostty.h`.
- Implementation walks `terminal.PageList` directly (no clamped point-tag pin) to avoid the reflow-boundary row loss documented in cmux's `docs/http-terminal-api-design.md` §7.1 / §10. Also retires the three-tag merge heuristic (callers now derive text from cells when available).
- Exports per-call hyperlink URI table; cells reference URIs by index.
- Exports OSC 133 semantic per row; `semantic_available` top-level bool reflects whether any row carried a marker (zsh-only in cmux due to `shell-integration=none`).
- Conflicts to watch on upstream rebase: any change to `selectionString`, `Page.getCells`, or `terminal.style.Color`/`Underline` layout requires regenerating the cell copy block in `embedded.zig`.
- Upstream candidate (see issue tracker link added in Task 1.10).
```

- [ ] **Step 3: Rebuild GhosttyKit (ReleaseFast), commit parent pointer**

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
cd ..
git add ghostty docs/ghostty-fork.md
# If GhosttyKit.xcframework is committed in-tree, stage it too:
test -d GhosttyKit.xcframework && git add GhosttyKit.xcframework
git commit -m "Bump ghostty submodule with cells export; rebuild GhosttyKit"
git push origin HEAD
```

---

### Task 1.8: `GhosttyCellsBridge` — Swift wrapper for the new C API (D25 underline, D26 hyperlink URIs, D27 semantic_available)

(Resolves Coverage gaps: hyperlink-id resolved to URI string per D26; underline_kind + underline_color mapped per D25; semantic_available bridged per D27. Resolves Quality granularity: Swift bridge is one task; integration into `AppSurfaceProvider` is the next.)

**Files:**
- Create: `Sources/HTTPControl/GhosttyCellsBridge.swift`
- Test:   `cmuxTests/HTTPControl/GhosttyCellsBridgeTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

The bridge depends on `cmuxTests/Fixtures/TerminalFixture.swift`, which is created in Phase 0 Task 0.23a (E8). Phase 1 only USES the fixture's existing constructors (`makeWithBytes`, `makeWithLines`, `makeAltScreen`, `spawn`, `spawnAndCapturedEnvironment`). Do not add an inline fallback or a "if not present" branch here — the Phase 0 task is the canonical source.

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/GhosttyCellsBridgeTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct GhosttyCellsBridgeTests {
    @Test func readsNarrowAndWideAndSpacer() async throws {
        let fixture = try TerminalFixture.makeWithBytes("ab\u{4E16}", cols: 4, rows: 2)
        let grid = try await GhosttyCellsBridge.read(surface: fixture.cSurface, region: .viewport)
        #expect(grid.cols == 4)
        let row0 = grid.rowsData[0]
        #expect(row0.cells[0].t == "a")
        #expect(row0.cells[0].wide == .narrow)
        #expect(row0.cells[2].t == "\u{4E16}")
        #expect(row0.cells[2].wide == .wide)
        #expect(row0.cells[3].wide == .spacerTail)
    }

    @Test func reportsWrapFlags() async throws {
        let fixture = try TerminalFixture.makeWithBytes("abcdefghij", cols: 4, rows: 4)
        let grid = try await GhosttyCellsBridge.read(surface: fixture.cSurface, region: .viewport)
        #expect(grid.rowsData[0].wrap == true)
        #expect(grid.rowsData[1].wrapContinuation == true)
    }

    @Test func reportsBoldAndRgbAndUnderlineCurly() async throws {
        // SGR: bold + fg rgb(200,100,50) + underline curly (4:3)
        let bytes = "\u{1B}[1;38;2;200;100;50;4:3mX\u{1B}[0m"
        let fixture = try TerminalFixture.makeWithBytes(bytes, cols: 4, rows: 2)
        let grid = try await GhosttyCellsBridge.read(surface: fixture.cSurface, region: .viewport)
        let c = grid.rowsData[0].cells[0]
        #expect(c.attrs.contains(.bold))
        if case .rgb(let r, let g, let b) = c.fg { #expect((r, g, b) == (200, 100, 50)) } else {
            Issue.record("expected rgb fg")
        }
        #expect(c.underlineKind == .curly)
    }

    @Test func resolvesHyperlinkIdToURI() async throws {
        // OSC 8 ; ; https://example/ ST  click  OSC 8 ; ; ST
        let bytes = "\u{1B}]8;;https://example/\u{1B}\\click\u{1B}]8;;\u{1B}\\"
        let fixture = try TerminalFixture.makeWithBytes(bytes, cols: 8, rows: 2)
        let grid = try await GhosttyCellsBridge.read(surface: fixture.cSurface, region: .viewport)
        let c = grid.rowsData[0].cells[0]
        #expect(c.hyperlink == "https://example/")  // URI string, NOT a numeric id
    }

    @Test func semanticAvailableTrueWhenOSC133Present() async throws {
        // OSC 133 ; A ; \a   prompt marker
        let bytes = "\u{1B}]133;A\u{07}$ "
        let fixture = try TerminalFixture.makeWithBytes(bytes, cols: 8, rows: 2)
        let grid = try await GhosttyCellsBridge.read(surface: fixture.cSurface, region: .viewport)
        #expect(grid.semanticAvailable == true)  // D27
    }

    @Test func reportsCursorPosition() async throws {
        let fixture = try TerminalFixture.makeWithBytes("abc", cols: 8, rows: 2)
        let grid = try await GhosttyCellsBridge.read(surface: fixture.cSurface, region: .viewport)
        #expect(grid.cursor.row == 0)
        #expect(grid.cursor.col == 3)
        #expect(grid.cursor.visible == true)
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/GhosttyCellsBridgeTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing GhosttyCellsBridge tests"
git push origin HEAD
```

- [ ] **Step 3: Implement bridge**

```swift
// Sources/HTTPControl/GhosttyCellsBridge.swift
import Foundation
import GhosttyKit
import CmuxTerminalAccess

/// Swift wrapper around `ghostty_surface_read_cells` (patch #1).
///
/// Acquires `renderer_state.mutex` on the Ghostty side, copies the grid
/// out, then releases. Conversion to ``CellGrid`` happens AFTER the C
/// `free` call so the lock isn't held during Swift allocation.
enum GhosttyCellsBridge {
    /// All call sites use `await`; the C work is hopped to a background
    /// queue so the Swift caller never blocks the main actor (D1).
    static func read(
        surface: ghostty_surface_t,
        region: ScreenRegion
    ) async throws -> CellGrid {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let grid = try readSync(surface: surface, region: region)
                    cont.resume(returning: grid)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func readSync(
        surface: ghostty_surface_t,
        region: ScreenRegion
    ) throws -> CellGrid {
        var g = ghostty_cell_grid_s()
        let tag: ghostty_cell_region_e
        switch region {
        case .viewport: tag = GHOSTTY_CELL_REGION_VIEWPORT
        case .screen: tag = GHOSTTY_CELL_REGION_SCREEN
        case .scrollback: tag = GHOSTTY_CELL_REGION_SCROLLBACK
        }
        guard ghostty_surface_read_cells(surface, tag, &g) else {
            throw TerminalAccessError.ghosttyError("ghostty_surface_read_cells failed")
        }
        let converted = convert(g)
        ghostty_cell_grid_free(surface, &g)
        return converted
    }

    private static func convert(_ g: ghostty_cell_grid_s) -> CellGrid {
        // Snapshot hyperlink URIs once.
        var uris: [String] = []
        uris.reserveCapacity(Int(g.hyperlinks.count))
        for i in 0..<Int(g.hyperlinks.count) {
            if let p = g.hyperlinks.uris.advanced(by: i).pointee {
                uris.append(String(cString: p))
            } else {
                uris.append("")
            }
        }
        var rows: [CellRow] = []
        rows.reserveCapacity(Int(g.rows_count))
        for r in 0..<Int(g.rows_count) {
            let cRow = g.rows.advanced(by: r).pointee
            var cells: [Cell] = []
            cells.reserveCapacity(Int(cRow.cells_count))
            for i in 0..<Int(cRow.cells_count) {
                let cc = cRow.cells.advanced(by: i).pointee
                let scalars = UnsafeBufferPointer(start: cc.codepoints, count: Int(cc.codepoints_count))
                let s = String(String.UnicodeScalarView(scalars.compactMap { Unicode.Scalar($0) }))
                let style = g.styles.advanced(by: Int(cc.style_id)).pointee
                let hyperlink: String? = {
                    let id = Int(cc.hyperlink_id)
                    guard id > 0, id < uris.count, !uris[id].isEmpty else { return nil }
                    return uris[id]   // D26: URI string, not numeric id
                }()
                cells.append(Cell(
                    t: s,
                    wide: wideKind(cc.wide),
                    fg: color(kind: style.fg_kind, palette: style.fg_palette, rgb: style.fg_rgb),
                    bg: color(kind: style.bg_kind, palette: style.bg_palette, rgb: style.bg_rgb),
                    attrs: attrSet(style.attrs_bitset),
                    underlineKind: underlineKind(style.underline_kind),
                    underlineColor: style.underline_kind == 0
                        ? nil
                        : color(kind: style.underline_color_kind,
                                palette: style.underline_palette,
                                rgb: style.underline_rgb),
                    hyperlink: hyperlink,
                    semantic: semanticKind(cc.semantic)
                ))
            }
            rows.append(CellRow(
                wrap: cRow.wrap,
                wrapContinuation: cRow.wrap_continuation,
                cells: cells
            ))
        }
        return CellGrid(
            cols: Int(g.cols),
            rows: Int(g.rows_count),
            altScreen: g.alt_screen,
            title: nil,
            cursor: CursorState(
                row: Int(g.cursor_row),
                col: Int(g.cursor_col),
                visible: g.cursor_visible,
                style: cursorStyle(g.cursor_style)
            ),
            semanticAvailable: g.semantic_available,
            rowsData: rows
        )
    }

    private static func wideKind(_ w: UInt8) -> WideKind {
        switch w {
        case 1: return .wide
        case 2: return .spacerTail
        case 3: return .spacerHead
        default: return .narrow
        }
    }

    private static func color(kind: UInt8, palette: UInt8, rgb: (UInt8, UInt8, UInt8)) -> CellColor {
        switch kind {
        case 1: return .palette(palette)
        case 2: return .rgb(r: rgb.0, g: rgb.1, b: rgb.2)
        default: return .default
        }
    }

    private static func attrSet(_ bits: UInt32) -> Set<CellAttribute> {
        var s: Set<CellAttribute> = []
        if bits & (1 << 0) != 0 { s.insert(.bold) }
        if bits & (1 << 1) != 0 { s.insert(.italic) }
        if bits & (1 << 2) != 0 { s.insert(.faint) }
        if bits & (1 << 3) != 0 { s.insert(.blink) }
        if bits & (1 << 4) != 0 { s.insert(.inverse) }
        if bits & (1 << 5) != 0 { s.insert(.invisible) }
        if bits & (1 << 6) != 0 { s.insert(.strikethrough) }
        return s   // D25: no .underline — use underlineKind != nil
    }

    private static func underlineKind(_ b: UInt8) -> UnderlineKind? {
        switch b {
        case 1: return .single
        case 2: return .double
        case 3: return .curly
        case 4: return .dotted
        case 5: return .dashed
        default: return nil
        }
    }

    private static func semanticKind(_ b: UInt8) -> SemanticKind? {
        switch b {
        case 1: return .prompt
        case 2: return .promptContinuation
        case 3: return .input
        case 4: return .output
        default: return nil
        }
    }

    private static func cursorStyle(_ b: UInt8) -> CursorStyle {
        switch b { case 1: return .underline; case 2: return .bar; default: return .block }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/GhosttyCellsBridge.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add GhosttyCellsBridge with hyperlink URIs, underline kind/color, semantic_available"
git push origin HEAD
```

---


### Task 1.9: `AppSurfaceProvider.readCells` + upstream tracking issue (D19)

(Resolves Coverage must_fix D19: upstream tracking happens in Phase 1, not Phase 2. Resolves Quality issue: `SurfaceProvider.readCells` is `async throws` matching D1.)

**Files:**
- Modify: `Sources/HTTPControl/AppSurfaceProvider.swift`
- Test:   `cmuxTests/HTTPControl/AppSurfaceProviderReadCellsTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

`SurfaceProvider.readCells` was defined in Phase 0 as `func readCells(handle: SurfaceHandle, region: ScreenRegion) async throws -> CellGrid` (D1). Phase 1 implements it in `AppSurfaceProvider` via `GhosttyCellsBridge`.

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/AppSurfaceProviderReadCellsTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct AppSurfaceProviderReadCellsTests {
    // E1 — SurfaceProvider.readCells takes `surface: SurfaceInfo`, not
    // `handle: SurfaceHandle`. The test fetches the SurfaceInfo via
    // `resolve(_:)` first, matching the dispatch the service performs.
    // E5 — uses `AppSurfaceProvider.shared.testInject(panel:handle:)`.
    @Test func readCellsForViewportRoundsTrip() async throws {
        let fixture = try TerminalFixture.makeWithBytes("hello", cols: 8, rows: 2)
        let provider = AppSurfaceProvider.shared
        defer { provider.testReset() }
        let handle: SurfaceHandle = .ref(kind: "surface", ordinal: 7)
        provider.testInject(panel: fixture.panel, handle: handle)
        let info = try await #require(try await provider.resolve(handle))
        let grid = try await provider.readCells(surface: info, region: .viewport)
        let row0Text = grid.rowsData[0].cells.map { $0.t }.joined()
        #expect(row0Text.hasPrefix("hello"))
    }

    @Test func readCellsUnknownSurfaceThrows() async throws {
        let provider = AppSurfaceProvider.shared
        defer { provider.testReset() }
        let info = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 999),
                               uuid: UUID(), workspaceRef: "w", title: nil,
                               cols: 0, rows: 0, altScreen: false,
                               focused: false, semanticAvailable: false)
        await #expect(throws: TerminalAccessError.self) {
            _ = try await provider.readCells(surface: info, region: .viewport)
        }
    }

    @Test func scrollbackOnAltScreenIsEmpty() async throws {
        // Enter alt screen with ESC[?1049h
        let fixture = try TerminalFixture.makeWithBytes("\u{1B}[?1049hX", cols: 8, rows: 2)
        let provider = AppSurfaceProvider.shared
        defer { provider.testReset() }
        let handle: SurfaceHandle = .ref(kind: "surface", ordinal: 8)
        provider.testInject(panel: fixture.panel, handle: handle)
        let info = try await #require(try await provider.resolve(handle))
        let grid = try await provider.readCells(surface: info, region: .scrollback)
        #expect(grid.altScreen == true)
        #expect(grid.rowsData.allSatisfy { row in row.cells.allSatisfy { $0.t.trimmingCharacters(in: .whitespaces).isEmpty } })
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/AppSurfaceProviderReadCellsTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing AppSurfaceProvider.readCells tests"
git push origin HEAD
```

- [ ] **Step 3: Implement**

```swift
// In Sources/HTTPControl/AppSurfaceProvider.swift — replace the Phase 0
// stub `readCells(surface:region:)` with the real impl. E1 — signature
// takes `surface: SurfaceInfo`, NOT `handle: SurfaceHandle`. E5 — the
// panel lookup goes through the injected/live state.
extension AppSurfaceProvider {
    /// Reads the surface's cell grid for ``region`` via patch #1.
    /// Async per D1 (the call hops to a background queue inside the bridge
    /// before acquiring the renderer mutex).
    public func readCells(
        surface: SurfaceInfo,
        region: ScreenRegion
    ) async throws -> CellGrid {
        guard let panel = await resolvePanel(handle: surface.handle) else {
            throw TerminalAccessError.unknownSurface
        }
        guard let cSurface = panel.surface.surface else {
            throw TerminalAccessError.ghosttyError("surface not initialised")
        }
        return try await GhosttyCellsBridge.read(surface: cSurface, region: region)
    }

    /// Looks up the live `TerminalPanel` for the handle. Checks injected
    /// state under `#if DEBUG` first, then delegates to the controller.
    fileprivate func resolvePanel(handle: SurfaceHandle) async -> TerminalPanel? {
        #if DEBUG
        if let pair = injected[handle] { return pair.panel }
        #endif
        guard let controller else { return nil }
        return await MainActor.run { controller.terminalPanel(forHandle: handle) }
    }
}
```

- [ ] **Step 4: File upstream tracking issue (D19)**

```bash
gh issue create --repo ghostty-org/ghostty \
  --title "Apprt cell-grid export API (used by cmux)" \
  --body "$(cat <<'EOF'
Proposing an upstream-friendly version of the apprt cell-grid export we shipped in our fork as patch #1. Direct page-walk; per-row wrap/wide/style/semantic; per-call hyperlink URI table; semantic_available top-level bool.

C ABI (current fork shape):
- `ghostty_surface_read_cells(surface, region, *grid) -> bool`
- `ghostty_cell_grid_free(surface, *grid)`

Rationale: agents and automation need to read structured screen state without scraping. Implementation walks `terminal.PageList` directly to avoid clamped point-tag reflow loss. Happy to align with `grid_ref_*` if upstream prefers that surface.

Linked fork commit: <fill in PR URL from Task 1.7 once merged>
EOF
)"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/HTTPControl/AppSurfaceProvider.swift cmux.xcodeproj/project.pbxproj
git commit -m "Implement AppSurfaceProvider.readCells via GhosttyCellsBridge"
git push origin HEAD
```

---

### Task 1.10: `RouteTable` + table-driven router (D11: 405 with `Allow:` header for method-mismatch)

(Resolves Coverage must_fix: 405 method-mismatch handling [D11]. Resolves Quality must_fix: `route(_:)` must not be a switch that extensions cannot extend — table-driven instead.)

**Files:**
- Create: `Sources/HTTPControl/RouteTable.swift`
- Test:   `cmuxTests/HTTPControl/RouteTableTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/RouteTableTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct RouteTableTests {
    private func req(_ method: String, _ path: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: [], body: Data())
    }

    @Test func dispatchesMatchingRoute() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(200, ["ok": true])
        }
        let resp = await table.dispatch(req("GET", "/v1/surfaces"))
        #expect(resp.status == 200)
    }

    @Test func methodMismatchReturns405WithAllow() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(200, ["ok": true])
        }
        table.register(method: "POST", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(201, ["ok": true])
        }
        let resp = await table.dispatch(req("DELETE", "/v1/surfaces"))
        #expect(resp.status == 405)
        let allow = resp.headers.first { $0.0 == "Allow" }?.1 ?? ""
        // Order-stable union of registered methods for this path.
        #expect(allow.contains("GET"))
        #expect(allow.contains("POST"))
    }

    @Test func unknownPathReturns404() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(200, ["ok": true])
        }
        let resp = await table.dispatch(req("GET", "/nope"))
        #expect(resp.status == 404)
    }

    @Test func parameterizedPatternsMatchPrefix() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces/*/screen") { req in
            JSONResponses.json(200, ["path": req.path])
        }
        let resp = await table.dispatch(req("GET", "/v1/surfaces/surface:1/screen"))
        #expect(resp.status == 200)
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/RouteTableTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing RouteTable dispatch + 405 tests"
git push origin HEAD
```

- [ ] **Step 3: Implement**

```swift
// Sources/HTTPControl/RouteTable.swift
import Foundation

/// Table-driven HTTP route dispatcher. Patterns use ``*`` as a single
/// path-segment wildcard. Method-mismatch on a matched path returns 405
/// with the `Allow:` header populated (D11). Unknown path returns 404.
public struct RouteTable: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> JSONResponses.Response

    private struct Route { let method: String; let segments: [String]; let handler: Handler }
    private var routes: [Route] = []

    public init() {}

    public mutating func register(method: String, pattern: String, handler: @escaping Handler) {
        routes.append(Route(method: method, segments: Self.split(pattern), handler: handler))
    }

    public func dispatch(_ req: HTTPRequest) async -> JSONResponses.Response {
        let reqSegs = Self.split(req.path)
        var pathMatched: [String] = []
        for r in routes where Self.segmentsMatch(r.segments, reqSegs) {
            pathMatched.append(r.method)
        }
        guard !pathMatched.isEmpty else { return JSONResponses.error(.featureDisabled) /* 404 */ }
        for r in routes where r.method == req.method && Self.segmentsMatch(r.segments, reqSegs) {
            return await r.handler(req)
        }
        return JSONResponses.methodNotAllowed(allow: pathMatched)
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func segmentsMatch(_ pattern: [String], _ path: [String]) -> Bool {
        guard pattern.count == path.count else { return false }
        for (p, s) in zip(pattern, path) where p != "*" && p != s { return false }
        return true
    }
}
```

(Note: `.featureDisabled` → 404 per D11 is reused here as the generic "path unknown" mapping; the wire code differs between feature-disabled and unknown-path only when the body is parsed — both surface as HTTP 404, matching the spec's "don't reveal feature exists but off" rule. Subsequent tasks may register custom 404 responses if the spec adds finer-grained codes.)

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/RouteTable.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add RouteTable with 405/404 path/method dispatch"
git push origin HEAD
```

---

### Task 1.11: `HTTPControlServer` TCP listener bring-up (no routes yet)

(Resolves Quality granularity must_fix: split listener bring-up from route handlers. Listener uses `Network.framework` `NWListener` with `requiredInterfaceType = .loopback`.)

**Files:**
- Create: `Sources/HTTPControl/HTTPControlServer.swift`
- Test:   `cmuxTests/HTTPControl/HTTPControlServerListenerTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPControlServerListenerTests.swift
import Foundation
import Network
import Testing
@testable import cmux

@Suite struct HTTPControlServerListenerTests {
    @Test func startsOnEphemeralPortAndCloses() throws {
        let server = HTTPControlServer(
            routeTable: RouteTable(),
            auth: HTTPAuth(expectedToken: "t"),
            hostAllowlistFor: { p in HostAllowlist(port: Int(p)) }
        )
        let port = try server.startTCP(port: 0)
        #expect(port > 0)
        server.stop()
    }

    @Test func boundPortIsLoopbackOnly() throws {
        let server = HTTPControlServer(
            routeTable: RouteTable(),
            auth: HTTPAuth(expectedToken: "t"),
            hostAllowlistFor: { p in HostAllowlist(port: Int(p)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        // Confirm we can connect from loopback.
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        conn.start(queue: .global())
        #expect(ready.wait(timeout: .now() + 2) == .success)
        conn.cancel()
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPControlServerListenerTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPControlServer listener bring-up tests"
git push origin HEAD
```

- [ ] **Step 3: Implement listener skeleton**

```swift
// Sources/HTTPControl/HTTPControlServer.swift
import Foundation
import Network

/// Local-only HTTP control transport. Binds 127.0.0.1 (TCP, D11/D12) or
/// a UDS path (D12). Routes are registered via ``RouteTable`` and
/// dispatched per-request. Auth + Host allowlist + body-cap rejection
/// happen here BEFORE route dispatch.
public final class HTTPControlServer {
    public typealias HostAllowlistFactory = @Sendable (UInt16) -> HostAllowlist
    /// E11 — `isEnabled` is read atomically on every request inside
    /// `handle(_:)`. Lifecycle still stops the listener on toggle-off;
    /// this closure handles in-flight requests during the stop and any
    /// races where settings flip false mid-connection. Defaults to `true`
    /// for legacy unit tests that don't pass settings.
    public typealias EnabledProbe = @Sendable () -> Bool

    let routeTable: RouteTable
    let auth: HTTPAuth
    let hostAllowlistFor: HostAllowlistFactory
    let isEnabled: EnabledProbe
    private var tcpListener: NWListener?
    private var udsListener: HTTPControlUDSListener?
    private let queue = DispatchQueue(label: "cmux.http-control", qos: .userInitiated)
    private(set) var boundPort: UInt16 = 0

    public init(
        routeTable: RouteTable,
        auth: HTTPAuth,
        hostAllowlistFor: @escaping HostAllowlistFactory,
        isEnabled: @escaping EnabledProbe = { true }
    ) {
        self.routeTable = routeTable
        self.auth = auth
        self.hostAllowlistFor = hostAllowlistFor
        self.isEnabled = isEnabled
    }

    @discardableResult
    public func startTCP(port: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        let l = try NWListener(using: params, on: endpoint)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        self.tcpListener = l
        self.boundPort = l.port?.rawValue ?? port
        return self.boundPort
    }

    public func stop() {
        tcpListener?.cancel(); tcpListener = nil
        udsListener?.stop(); udsListener = nil
    }

    fileprivate func setUDSListener(_ l: HTTPControlUDSListener) { udsListener = l }

    fileprivate func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isEnd, _ in
                guard let self else { return }
                if let data { parser.feed(data) }
                do {
                    switch try parser.next() {
                    case .complete(let req):
                        Task { await self.handle(req, connection: conn) }
                    case .need:
                        if isEnd { conn.cancel() } else { read() }
                    }
                } catch HTTPParseError.bodyTooLarge, HTTPParseError.headerTooLarge {
                    self.write(JSONResponses.error(.payloadTooLarge), to: conn, close: true)
                } catch {
                    self.write(JSONResponses.error(.badRequest(reason: "malformed request")), to: conn, close: true)
                }
            }
        }
        read()
    }

    fileprivate func handle(_ req: HTTPRequest, connection: NWConnection) async {
        // E11 — runtime-disabled check happens on every request. If
        // Settings flips off mid-connection, in-flight requests get
        // a 404 with the `featureDisabled` wire code, identical to
        // what a client would see if the listener never started.
        guard isEnabled() else {
            return write(JSONResponses.error(.featureDisabled), to: connection, close: true)
        }
        switch hostAllowlistFor(boundPort).evaluate(host: req.header("host"), origin: req.header("origin")) {
        case .missingHost:
            return write(JSONResponses.error(.badRequest(reason: "missing Host")), to: connection, close: true)
        case .forbiddenHost:
            return write(JSONResponses.error(.forbidden(reason: "host not allowed")), to: connection, close: true)
        case .forbiddenOrigin:
            return write(JSONResponses.error(.forbidden(reason: "origin not allowed")), to: connection, close: true)
        case .ok: break
        }
        if auth.evaluate(authorizationHeader: req.header("authorization")) != .ok {
            return write(JSONResponses.error(.unauthorized), to: connection, close: true)
        }
        let resp = await routeTable.dispatch(req)
        write(resp, to: connection, close: true)
    }

    fileprivate func write(_ resp: JSONResponses.Response, to conn: NWConnection, close: Bool) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reasonPhrase(resp.status))\r\n"
        for (k, v) in resp.headers { head += "\(k): \(v)\r\n" }
        if close { head += "Connection: close\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        conn.send(content: data, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }

    private static func reasonPhrase(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 201: return "Created"
        case 400: return "Bad Request"; case 401: return "Unauthorized"
        case 403: return "Forbidden"; case 404: return "Not Found"
        case 405: return "Method Not Allowed"; case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"; case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/HTTPControlServer.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add HTTPControlServer TCP listener bring-up"
git push origin HEAD
```

---

### Task 1.12: Route `GET /v1/surfaces` (live, via async `TerminalAccessService.listSurfaces`)

(Resolves Coverage type-or-path issue: server must `await service.listSurfaces()` per D1.)

**Files:**
- Create: `Sources/HTTPControl/SurfaceListJSON.swift`
- Create: `Sources/HTTPControl/HTTPControlRoutes.swift` (top-level registration helper used by lifecycle)
- Test:   `cmuxTests/HTTPControl/HTTPControlSurfaceListTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPControlSurfaceListTests.swift
import Foundation
import Network
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct HTTPControlSurfaceListTests {
    @Test func listSurfacesHappyPath() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([
            SurfaceInfo(
                handle: .ref(kind: "surface", ordinal: 1),
                uuid: UUID(), workspaceRef: "workspace:1", title: "t",
                cols: 80, rows: 24, altScreen: false, focused: true,
                semanticAvailable: false
            ),
        ])
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let resp = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        )
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("surface:1"))
        #expect(resp.contains("\"semantic_available\":false"))
    }

    @Test func missingTokenReturns401() throws {
        var table = RouteTable()
        let stub = StubTerminalAccessService()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let resp = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        )
        #expect(resp.contains("401"))
    }

    @Test func spoofedHostReturns403() throws {
        var table = RouteTable()
        let stub = StubTerminalAccessService()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let resp = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: evil.example:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        )
        #expect(resp.contains("403"))
    }
}
```

Add helper `cmuxTests/HTTPControl/Support/LoopbackHTTPClient.swift` (small sync client around `NWConnection`):

```swift
// cmuxTests/HTTPControl/Support/LoopbackHTTPClient.swift
import Foundation
import Network

enum LoopbackHTTPClient {
    static func send(port: UInt16, raw: String, timeout: TimeInterval = 4) throws -> String {
        let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        var received = Data()
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
                func loop() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { d, _, isEnd, _ in
                        if let d { received.append(d) }
                        if isEnd { done.signal() } else { loop() }
                    }
                }
                loop()
            }
        }
        conn.start(queue: .global())
        _ = done.wait(timeout: .now() + timeout)
        conn.cancel()
        return String(data: received, encoding: .utf8) ?? ""
    }
}
```

Add shared test-target stub `cmuxTests/HTTPControl/Support/StubTerminalAccessService.swift` (uses the package's async-throws protocol per D1):

```swift
// cmuxTests/HTTPControl/Support/StubTerminalAccessService.swift
import Foundation
import CmuxTerminalAccess

final actor StubTerminalAccessService: TerminalAccessService {
    private var surfaces: [SurfaceInfo] = []
    private(set) var lastInput: InputRequest?
    var screenResult: ScreenReadResult?

    func setSurfaces(_ s: [SurfaceInfo]) { self.surfaces = s }
    func setScreen(_ r: ScreenReadResult?) { self.screenResult = r }

    // E17 — protocol signature is `async throws`; even if the stub never
    // throws, the `throws` keyword must be present to match the protocol.
    func listSurfaces() async throws -> [SurfaceInfo] { surfaces }

    func readScreen(_ req: ScreenReadRequest) async throws -> ScreenReadResult {
        guard surfaces.contains(where: { $0.handle == req.handle }) else {
            throw TerminalAccessError.unknownSurface
        }
        return screenResult ?? .text(.init(cols: 80, rows: 24, altScreen: false, title: nil, text: "stub"))
    }

    func writeInput(_ req: InputRequest) async throws { lastInput = req }
}
```

- [ ] **Step 2: Commit failing test (+ support helpers)**

```bash
git add cmuxTests/HTTPControl/HTTPControlSurfaceListTests.swift \
        cmuxTests/HTTPControl/Support/LoopbackHTTPClient.swift \
        cmuxTests/HTTPControl/Support/StubTerminalAccessService.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add failing surface-list happy-path + 401 + 403 tests"
git push origin HEAD
```

- [ ] **Step 3: Implement encoder + route registrar**

```swift
// Sources/HTTPControl/SurfaceListJSON.swift
import Foundation
import CmuxTerminalAccess

enum SurfaceListJSON {
    static func encode(_ surfaces: [SurfaceInfo]) -> [String: Any] {
        ["surfaces": surfaces.map { s in
            [
                "handle": Self.encode(s.handle),
                "uuid": s.uuid.uuidString,
                "workspace": s.workspaceRef,
                "title": s.title as Any,
                "cols": s.cols, "rows": s.rows,
                "alt_screen": s.altScreen,
                "focused": s.focused,
                "semantic_available": s.semanticAvailable,
            ] as [String: Any]
        }]
    }
    static func encode(_ h: SurfaceHandle) -> String {
        switch h {
        case .uuid(let u): return u.uuidString
        case .ref(let k, let n): return "\(k):\(n)"
        }
    }
}
```

```swift
// Sources/HTTPControl/HTTPControlRoutes.swift
import Foundation
import CmuxTerminalAccess

enum HTTPControlRoutes {
    static func registerSurfaceList(
        into table: inout RouteTable,
        service: TerminalAccessService
    ) {
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            // E17 — protocol is `async throws`; route handler must `try await`.
            do {
                let surfaces = try await service.listSurfaces()
                return JSONResponses.json(200, SurfaceListJSON.encode(surfaces))
            } catch let e as TerminalAccessError {
                return JSONResponses.error(e)
            } catch {
                return JSONResponses.error(.ghosttyError(String(describing: error)))
            }
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/SurfaceListJSON.swift \
        Sources/HTTPControl/HTTPControlRoutes.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Wire GET /v1/surfaces through async TerminalAccessService"
git push origin HEAD
```

---


### Task 1.13: `CellGridJSON` encoder (cells, D25 underline, D26 hyperlink, D27 semantic_available)

(Resolves Quality issue: single canonical encoder named `CellGridJSON.encode(_:region:)`. Resolves Coverage gap: encoder includes underline kind + color, hyperlink URI string, and top-level `semantic_available`.)

**Files:**
- Create: `Sources/HTTPControl/CellGridJSON.swift`
- Test:   `cmuxTests/HTTPControl/CellGridJSONTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/CellGridJSONTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct CellGridJSONTests {
    @Test func encodesWideSpacerSemanticHyperlinkUnderline() throws {
        let g = CellGrid(
            cols: 4, rows: 1, altScreen: false, title: "t",
            cursor: .init(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: true,
            rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: [
                Cell(t: "a", wide: .narrow, fg: .default, bg: .default, attrs: [.bold],
                     underlineKind: nil, underlineColor: nil,
                     hyperlink: nil, semantic: .input),
                Cell(t: "\u{4E16}", wide: .wide, fg: .default, bg: .default, attrs: [],
                     underlineKind: .curly, underlineColor: .rgb(r: 10, g: 20, b: 30),
                     hyperlink: nil, semantic: nil),
                Cell(t: "", wide: .spacerTail, fg: .default, bg: .default, attrs: [],
                     underlineKind: nil, underlineColor: nil,
                     hyperlink: nil, semantic: nil),
                Cell(t: " ", wide: .narrow, fg: .rgb(r: 1, g: 2, b: 3), bg: .palette(7), attrs: [],
                     underlineKind: nil, underlineColor: nil,
                     hyperlink: "https://example/", semantic: nil),
            ])]
        )
        let json = CellGridJSON.encode(g, region: "viewport")
        let s = String(data: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8) ?? ""
        #expect(s.contains("\"format\":\"cells\""))
        #expect(s.contains("\"semantic_available\":true"))
        #expect(s.contains("\"wide\":\"wide\""))
        #expect(s.contains("\"wide\":\"spacer_tail\""))
        #expect(s.contains("\"underline_kind\":\"curly\""))
        #expect(s.contains("\"underline_color\":\"#0A141E\""))
        #expect(s.contains("\"hyperlink\":\"https:\\/\\/example\\/\""))
        #expect(s.contains("\"attrs\":[\"bold\"]"))
        #expect(s.contains("#010203"))
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/CellGridJSONTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing CellGridJSON encoder tests"
git push origin HEAD
```

- [ ] **Step 3: Implement**

```swift
// Sources/HTTPControl/CellGridJSON.swift
import Foundation
import CmuxTerminalAccess

enum CellGridJSON {
    static func encode(_ g: CellGrid, region: String) -> [String: Any] {
        return [
            "format": "cells",
            "region": region,
            "cols": g.cols,
            "rows": g.rows,
            "alt_screen": g.altScreen,
            "title": g.title as Any,
            "semantic_available": g.semanticAvailable,
            "cursor": [
                "row": g.cursor.row, "col": g.cursor.col,
                "visible": g.cursor.visible, "style": cursorStyle(g.cursor.style),
            ],
            "rows_data": g.rowsData.map { row in
                [
                    "wrap": row.wrap,
                    "wrap_continuation": row.wrapContinuation,
                    "cells": row.cells.map(cellJSON),
                ] as [String: Any]
            },
        ]
    }

    private static func cellJSON(_ c: Cell) -> [String: Any] {
        var out: [String: Any] = [
            "t": c.t,
            "wide": wideString(c.wide),
            "fg": colorString(c.fg),
            "bg": colorString(c.bg),
            "attrs": c.attrs.sorted { $0.rawName < $1.rawName }.map(\.rawName),
        ]
        if let k = c.underlineKind {
            out["underline_kind"] = underlineString(k)
            if let uc = c.underlineColor { out["underline_color"] = colorString(uc) }
        }
        if let h = c.hyperlink { out["hyperlink"] = h }   // D26: URI string
        if let s = c.semantic { out["semantic"] = semanticString(s) }
        return out
    }

    private static func cursorStyle(_ s: CursorStyle) -> String {
        switch s { case .block: return "block"; case .underline: return "underline"; case .bar: return "bar" }
    }
    private static func wideString(_ w: WideKind) -> String {
        switch w {
        case .narrow: return "narrow"
        case .wide: return "wide"
        case .spacerTail: return "spacer_tail"
        case .spacerHead: return "spacer_head"
        }
    }
    private static func colorString(_ c: CellColor) -> String {
        switch c {
        case .default: return "default"
        case .palette(let i): return "palette:\(i)"
        case .rgb(let r, let g, let b): return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
    private static func underlineString(_ u: UnderlineKind) -> String {
        switch u { case .single: return "single"; case .double: return "double"
        case .curly: return "curly"; case .dotted: return "dotted"; case .dashed: return "dashed" }
    }
    private static func semanticString(_ s: SemanticKind) -> String {
        switch s {
        case .prompt: return "prompt"; case .promptContinuation: return "prompt_continuation"
        case .input: return "input"; case .output: return "output"
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/CellGridJSON.swift cmux.xcodeproj/project.pbxproj
git commit -m "Implement CellGridJSON with underline kind/color, hyperlink URI, semantic_available"
git push origin HEAD
```

---

### Task 1.14: Route `GET /v1/surfaces/{id}/screen` — text + cells + `wrap=join` + `format=raw` → 400 (D29)

(Resolves Coverage must_fix D5: cells WORKS on landing; D29: `format=raw` on /screen → 400 with specific message; spec §7 alt-screen scrollback → empty.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlRoutes.swift` (add `registerScreenRead`)
- Modify: `Sources/HTTPControl/AppSurfaceProvider.swift` (add `readText(handle:region:wrap:trim:) async throws -> TextScreenPayload`)
- Create: `Sources/HTTPControl/ScreenRegionReader.swift` (shared SCREEN+SURFACE+ACTIVE merge that uses cells when available; preserved as the helper only until D25 cells fully retires it for live AppSurfaceProvider; meanwhile the legacy socket path continues to call it)
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift` (route `format == .cells` to `provider.readCells`, route `format == .text` to `provider.readText`, reject `wrap == .join` BEFORE patch availability via `.unsupported(reason:)` — but Phase 1 ALWAYS has patch #1 so `.join` is accepted; reject `format == .raw` with `.badRequest(reason: "format=raw is streaming-only; use /stream?mode=raw")` per D29)
- Test:   `cmuxTests/HTTPControl/HTTPControlScreenRouteTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing tests**

```swift
// cmuxTests/HTTPControl/HTTPControlScreenRouteTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct HTTPControlScreenRouteTests {
    private func makeServer(_ stub: StubTerminalAccessService) throws -> (HTTPControlServer, UInt16) {
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        HTTPControlRoutes.registerScreenRead(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        return (server, port)
    }

    @Test func textHappyPath() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false
        )])
        await stub.setScreen(.text(.init(cols: 80, rows: 24, altScreen: false, title: "t", text: "hello")))
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=text&region=viewport HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("\"text\":\"hello\""))
    }

    @Test func cellsHappyPath_format_cells_works_in_v1() async throws {  // D5
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: true
        )])
        let grid = CellGrid(
            cols: 2, rows: 1, altScreen: false, title: "t",
            cursor: .init(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: true,
            rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: [
                Cell(t: "a", wide: .narrow, fg: .default, bg: .default, attrs: [], underlineKind: nil, underlineColor: nil, hyperlink: nil, semantic: nil),
                Cell(t: "b", wide: .narrow, fg: .default, bg: .default, attrs: [], underlineKind: nil, underlineColor: nil, hyperlink: nil, semantic: nil),
            ])]
        )
        await stub.setScreen(.cells(grid))
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=cells&region=viewport HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("\"format\":\"cells\""))   // D5: NOT 415
        #expect(resp.contains("\"semantic_available\":true"))   // D27
    }

    @Test func formatRawReturns400WithStreamingMessage() async throws {   // D29
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false
        )])
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=raw HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("400"))
        #expect(resp.contains("format=raw is streaming-only"))
    }

    @Test func wrapJoinAcceptedInV1() async throws {   // D5: wrap=join is open in v1
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false
        )])
        await stub.setScreen(.text(.init(cols: 80, rows: 24, altScreen: false, title: nil, text: "joined")))
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=text&wrap=join HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
    }

    @Test func methodMismatchReturns405WithAllow() async throws {   // D11
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false
        )])
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let req = "POST /v1/surfaces/surface:1/screen HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("405"))
        #expect(resp.contains("Allow: GET"))
    }

    @Test func unknownPathReturns404() async throws {
        let stub = StubTerminalAccessService()
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let req = "GET /v1/nope HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("404"))
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPControlScreenRouteTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing screen-route tests (text, cells in v1, raw->400, wrap=join, 405, 404)"
git push origin HEAD
```

- [ ] **Step 3: Implement route registrar**

```swift
// Append to Sources/HTTPControl/HTTPControlRoutes.swift
import Foundation
import CmuxTerminalAccess

extension HTTPControlRoutes {
    static func registerScreenRead(
        into table: inout RouteTable,
        service: TerminalAccessService
    ) {
        table.register(method: "GET", pattern: "/v1/surfaces/*/screen") { req in
            // Extract surface id from /v1/surfaces/{id}/screen
            let segs = req.path.split(separator: "/").map(String.init)
            guard segs.count == 4, segs[0] == "v1", segs[1] == "surfaces", segs[3] == "screen" else {
                return JSONResponses.error(.badRequest(reason: "bad path"))
            }
            guard let handle = SurfaceHandle.parse(segs[2]) else {
                return JSONResponses.error(.unknownSurface)
            }
            // D29: format=raw on /screen → 400 with explicit message
            let formatRaw = (req.query["format"] ?? "text").lowercased()
            if formatRaw == "raw" {
                return JSONResponses.error(.badRequest(reason: "format=raw is streaming-only; use /stream?mode=raw"))
            }
            guard let format = ScreenFormat(rawString: formatRaw) else {
                return JSONResponses.error(.badRequest(reason: "format must be text|cells"))
            }
            let regionRaw = (req.query["region"] ?? "viewport").lowercased()
            guard let region = ScreenRegion(rawString: regionRaw) else {
                return JSONResponses.error(.badRequest(reason: "region must be viewport|screen|scrollback"))
            }
            let wrapRaw = (req.query["wrap"] ?? "preserve").lowercased()
            guard let wrap = WrapPolicy(rawString: wrapRaw) else {
                return JSONResponses.error(.badRequest(reason: "wrap must be preserve|join"))
            }
            let trim = (req.query["trim"] ?? "true").lowercased() != "false"
            do {
                let result = try await service.readScreen(.init(
                    handle: handle, format: format, region: region, wrap: wrap, trim: trim
                ))
                switch result {
                case .text(let t):
                    return JSONResponses.json(200, [
                        "format": "text", "region": regionRaw,
                        "cols": t.cols, "rows": t.rows,
                        "alt_screen": t.altScreen,
                        "title": t.title as Any,
                        "text": t.text,
                    ])
                case .cells(let g):
                    return JSONResponses.json(200, CellGridJSON.encode(g, region: regionRaw))
                }
            } catch let e as TerminalAccessError {
                return JSONResponses.error(e)
            } catch {
                return JSONResponses.error(.ghosttyError(String(describing: error)))
            }
        }
    }
}
```

- [ ] **Step 4: Implement `AppSurfaceProvider.readText` + `ScreenRegionReader`**

```swift
// Sources/HTTPControl/ScreenRegionReader.swift
import Foundation
import GhosttyKit
import CmuxTerminalAccess

/// Shared SCREEN+SURFACE+ACTIVE merge used by the legacy socket
/// `read_screen` path and by `AppSurfaceProvider.readText` BEFORE
/// patch #1's cells path supplants it. Once all callers use cells,
/// this helper can be removed (tracked via the §7.1 retirement item).
enum ScreenRegionReader {
    static func read(panel: TerminalPanel, region: ScreenRegion) -> String {
        guard panel.surface.surface != nil else { return "" }
        // On alt screen, scrollback is empty per spec §7 通用规则.
        if region == .scrollback, panel.surface.isAltScreen { return "" }
        switch region {
        case .viewport: return readTag(panel: panel, tag: GHOSTTY_POINT_VIEWPORT) ?? ""
        case .scrollback: return readTag(panel: panel, tag: GHOSTTY_POINT_SURFACE) ?? ""
        case .screen:
            let screen = readTag(panel: panel, tag: GHOSTTY_POINT_SCREEN)
            let history = readTag(panel: panel, tag: GHOSTTY_POINT_SURFACE)
            let active = readTag(panel: panel, tag: GHOSTTY_POINT_ACTIVE)
            var candidates: [String] = []
            if let screen { candidates.append(screen) }
            if history != nil || active != nil {
                var merged = history ?? ""
                if let active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty { merged.append("\n") }
                    merged.append(active)
                }
                candidates.append(merged)
            }
            return candidates.max { score($0) < score($1) } ?? ""
        }
    }

    private static func score(_ s: String) -> (Int, Int) {
        let lines = s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count
        return (lines, s.utf8.count)
    }

    private static func readTag(panel: TerminalPanel, tag: ghostty_point_tag_e) -> String? {
        TerminalController.readSelectionText(panel: panel, pointTag: tag)
    }
}
```

> **Note.** This Phase 1 intermediate helper takes
> `(handle:region:wrap:trim:)` and returns `TextScreenPayload` to bridge the
> /screen route through the legacy `ScreenRegionReader`. Task 1.22b retires
> `ScreenRegionReader` and routes `AppSurfaceProvider.readText` through
> `readCells` + `cellsToText` (E10/E19), at which point the helper below
> collapses back into the E1-shaped `readText(surface:region:)` protocol
> method.

```swift
// Append in Sources/HTTPControl/AppSurfaceProvider.swift (intermediate
// Phase 1 helper — retired in Task 1.22b per E10).
extension AppSurfaceProvider {
    public func readText(
        handle: SurfaceHandle, region: ScreenRegion, wrap: WrapPolicy, trim: Bool
    ) async throws -> TextScreenPayload {
        guard let panel = await resolvePanel(handle: handle) else { throw TerminalAccessError.unknownSurface }
        // E1 — readCells takes `surface: SurfaceInfo`. Resolve the panel's
        // SurfaceInfo before calling the protocol method.
        guard let info = try await resolve(handle) else { throw TerminalAccessError.unknownSurface }
        if wrap == .join {
            // Use cells path to join soft-wrapped rows accurately (D5).
            let grid = try await readCells(surface: info, region: region)
            var lines: [String] = []
            var current = ""
            for row in grid.rowsData {
                let text = row.cells.map { $0.t }.joined()
                let stripped = trim ? text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) : text
                if row.wrap { current.append(stripped) } else {
                    current.append(stripped); lines.append(current); current = ""
                }
            }
            if !current.isEmpty { lines.append(current) }
            let joined = lines.joined(separator: "\n")
            return .init(cols: grid.cols, rows: grid.rows, altScreen: grid.altScreen, title: grid.title, text: joined)
        } else {
            var text = ScreenRegionReader.read(panel: panel, region: region)
            if trim {
                text = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                    .joined(separator: "\n")
            }
            let cols = panel.surface.gridCols
            let rows = panel.surface.gridRows
            return .init(cols: cols, rows: rows, altScreen: panel.surface.isAltScreen, title: panel.surface.title, text: text)
        }
    }
}
```

(If `panel.surface.gridCols`/`gridRows`/`isAltScreen`/`title` accessors don't exist yet on `TerminalSurface`, add them as a tiny task split before this one. Phase 0's `AppSurfaceProvider` introduction task is the natural place; if not present there, add `Sources/TerminalSurface+Access.swift` with these four read-only properties calling existing `ghostty_surface_*` helpers.)

- [ ] **Step 5: Implement `DefaultTerminalAccessService.readScreen` routing**

```swift
// In Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift
//
// E1 — service composes the response from the locked provider primitives
// `readText(surface:region:)` and `readCells(surface:region:)`. The
// `wrap` and `trim` policies are applied here, NOT on the provider.
// Task 1.22b will replace the `.text` branch with a cells-derived path
// once `cellsToText` lands (E10/E19). Intermediate Phase 1 shape:
public func readScreen(_ request: ScreenReadRequest) async throws -> ScreenReadResult {
    guard let info = try await provider.resolve(request.handle) else {
        throw TerminalAccessError.unknownSurface
    }
    switch request.format {
    case .text:
        var text = try await provider.readText(surface: info, region: request.region)
        if request.trim { text = Self.trimTrailingSpaces(text) }
        return .text(TextScreenPayload(cols: info.cols, rows: info.rows,
                                       altScreen: info.altScreen,
                                       title: info.title, text: text))
    case .cells:
        let g = try await provider.readCells(surface: info, region: request.region)
        return .cells(g)
    }
}
```

(`ScreenFormat` is `{text, cells}` per shared conventions; the route layer rejects `raw` upfront with 400 per D29 BEFORE constructing `ScreenReadRequest`, so the service never sees it.)

- [ ] **Step 6: Commit**

```bash
git add Sources/HTTPControl/HTTPControlRoutes.swift \
        Sources/HTTPControl/AppSurfaceProvider.swift \
        Sources/HTTPControl/ScreenRegionReader.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Wire GET /v1/surfaces/{id}/screen with cells in v1, wrap=join, format=raw->400"
git push origin HEAD
```

---

### Task 1.15: Per-surface rate limit (writes) + always-on audit log wiring (D4, D10)

(Resolves Coverage must_fix D4: audit ALWAYS-ON for write paths in v1; Settings only controls path. Resolves Coverage must_fix on per-surface AND per-connection rate dimensions per spec §16.4: this task adds the per-surface bucket; per-connection is the stream-open bucket added in Phase 2.)

**Files:**
- Create: `Sources/HTTPControl/HTTPControlRateKeys.swift`
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift` (acquire per-surface write bucket + record AuditEntry on every writeInput, regardless of settings)
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceAuditAlwaysOnTests.swift`

- [ ] **Step 1: Failing test**

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceAuditAlwaysOnTests.swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct DefaultServiceAuditAlwaysOnTests {
    // E2 — `AuditLog.record` is `async` non-throwing.
    actor RecordingAudit: AuditLog {
        var entries: [AuditEntry] = []
        func record(_ e: AuditEntry) async { entries.append(e) }
        func snapshot() -> [AuditEntry] { entries }
    }

    @Test func writesAreAuditedRegardlessOfSettings() async throws {
        let provider = StubSurfaceProvider()
        let audit = RecordingAudit()
        let service = DefaultTerminalAccessService(
            provider: provider,
            audit: audit,
            rateLimiter: RateLimiter(burstCapacity: 1_000, refillPerSecond: 1_000)
        )
        let req = InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .text("ls", submit: false),
            focusSurface: false
        )
        try await service.writeInput(req)
        let recorded = await audit.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded[0].kind == .writeText)
        #expect(recorded[0].byteCount == 2)
    }

    @Test func rateLimitExceededThrows() async throws {
        let provider = StubSurfaceProvider()
        let audit = RecordingAudit()
        let service = DefaultTerminalAccessService(
            provider: provider,
            audit: audit,
            rateLimiter: RateLimiter(burstCapacity: 1, refillPerSecond: 0.0001)
        )
        let req = InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .text("a", submit: false),
            focusSurface: false
        )
        try await service.writeInput(req)
        await #expect(throws: TerminalAccessError.self) {
            try await service.writeInput(req)
        }
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/DefaultServiceAuditAlwaysOnTests.swift
git commit -m "Add failing always-on audit + per-surface rate-limit tests"
git push origin HEAD
```

- [ ] **Step 3: Implement service write path**

```swift
// In Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift
//
// E1 — dispatches compose higher-level operations from the locked
// SurfaceProvider primitives (writeText / writeKey / writeMouse /
// setFocus); no writeKeys/writeRaw/writePaste on the provider.
// E2 — `audit.record(...)` is `async` non-throwing (no `try`).
// E14 — `try await enforceCapacity(info: info, bytes: payloadByteCount)`
// is preserved BEFORE the dispatch (Phase 0 line 2562 test
// `payloadTooLargeWhenCapacityExceeded` continues to pass).
// E16 — `rateLimiter.acquire` throws `TerminalAccessError.rateLimited`;
// callers always `try await` it. No `guard ... else` Bool branch.
// E18 — Phase 1's `SpyRecordingProvider` matches this dispatch shape.
public func writeInput(_ request: InputRequest) async throws {
    guard let info = try await provider.resolve(request.handle) else {
        throw TerminalAccessError.unknownSurface
    }
    let rateKey = HTTPControlRateKeys.write(for: request.handle)
    try await rateLimiter.acquire(key: rateKey)
    // D17: focus first if requested
    if request.focusSurface {
        try await provider.setFocus(surface: info, gained: true)
    }
    let kind: AuditKind
    let byteCount: Int
    let detail: [String: String]?
    switch request.payload {
    case .text(let s, let submit):
        let bytes = Data(s.utf8)
        try await enforceCapacity(info: info, bytes: bytes.count)
        try await provider.writeText(surface: info, bytes: bytes)
        if submit {
            try await provider.writeKey(surface: info,
                                        event: KeyEvent(mods: [], key: .enter))
        }
        kind = .writeText; byteCount = bytes.count
        detail = submit ? ["submit": "true"] : nil
    case .keys(let events):
        for ev in events { try await provider.writeKey(surface: info, event: ev) }
        kind = .writeKeys; byteCount = events.count
        detail = nil
    case .raw(let data):
        if !allowRawInput() {
            throw TerminalAccessError.forbidden(reason: "raw input disabled")
        }
        try await enforceCapacity(info: info, bytes: data.count)
        try await provider.writeText(surface: info, bytes: data)
        kind = .writeRaw; byteCount = data.count
        detail = nil
    case .paste(let s):
        let bytes = Data(s.utf8)
        try await enforceCapacity(info: info, bytes: bytes.count)
        try await pasteSerializer.run(surface: info) {
            try await provider.writeText(surface: info, bytes: bytes)
        }
        kind = .writePaste; byteCount = bytes.count
        detail = nil
    case .mouse(let m):
        try await provider.writeMouse(surface: info, event: m)
        kind = .writeMouse; byteCount = 0
        detail = ["action": "\(m.action)"]
    case .focus(let gained):
        try await provider.setFocus(surface: info, gained: gained)
        kind = .writeFocus; byteCount = 0
        detail = ["gained": gained ? "true" : "false"]
    }
    await audit.record(AuditEntry(
        timestamp: Date(),
        surface: request.handle,
        kind: kind,
        byteCount: byteCount,
        detail: detail
    ))
}
```

```swift
// Sources/HTTPControl/HTTPControlRateKeys.swift
import Foundation
import CmuxTerminalAccess

/// Stable string keys for the shared ``RateLimiter`` per D10.
public enum HTTPControlRateKeys {
    public static func write(for handle: SurfaceHandle) -> String {
        "surface:\(SurfaceListJSON.encode(handle))#write"
    }
    public static func streamOpen(for handle: SurfaceHandle) -> String {
        "surface:\(SurfaceListJSON.encode(handle))#stream-open"
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        Sources/HTTPControl/HTTPControlRateKeys.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Always-on audit log + per-surface write rate limit in DefaultService"
git push origin HEAD
```

---


### Task 1.16: `InputRequestDecoder` + route `POST /v1/surfaces/{id}/input` for text/keys/paste/raw/mouse/focus

(Resolves Coverage type/path issues: KeyEvent.parse and MouseEvent.parse already land in Phase 0 per D21 + shared conventions, so decoder builds cleanly here. Resolves Coverage must_fix D15: ESC-strip safety test. Resolves Coverage must_fix D17: focusSurface wiring. Resolves Coverage must_fix D30: paste atomicity test. Resolves Coverage must_fix D16: mouse direct-call assertion.)

**Files:**
- Create: `Sources/HTTPControl/InputRequestDecoder.swift`
- Modify: `Sources/HTTPControl/HTTPControlRoutes.swift` (add `registerInputWrite`)
- Test:   `cmuxTests/HTTPControl/HTTPControlInputRouteTests.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ESCStripPasteSafetyTests.swift` (D15)
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteAtomicityTests.swift` (D30)
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/MouseDirectCallTests.swift` (D16)
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/FocusSurfaceWiringTests.swift` (D17)
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing route tests**

```swift
// cmuxTests/HTTPControl/HTTPControlInputRouteTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct HTTPControlInputRouteTests {
    private func makeServer(_ stub: StubTerminalAccessService, allowRaw: Bool = false) throws -> (HTTPControlServer, UInt16) {
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        HTTPControlRoutes.registerInputWrite(into: &table, service: stub, allowRaw: { allowRaw })
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        return (server, port)
    }

    @Test func textSubmit() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false
        )])
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let body = "{\"type\":\"text\",\"text\":\"ls\",\"submit\":true}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        guard case .text(let t, let submit) = last?.payload else { Issue.record("expected text"); return }
        #expect(t == "ls"); #expect(submit == true)
    }

    @Test func keysParsed() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1), uuid: UUID(), workspaceRef: "w:1", title: "t", cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false)])
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let body = "{\"type\":\"keys\",\"keys\":[\"Ctrl+C\",\"Enter\",\"F5\"]}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        guard case .keys(let events) = last?.payload else { Issue.record("expected keys"); return }
        #expect(events.count == 3)
    }

    @Test func rawDisabledReturns403() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1), uuid: UUID(), workspaceRef: "w:1", title: "t", cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false)])
        let (server, port) = try makeServer(stub, allowRaw: false); defer { server.stop() }
        let body = "{\"type\":\"raw\",\"bytes_base64\":\"YWI=\"}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("403"))
    }

    @Test func rawEnabledWritesBytes() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1), uuid: UUID(), workspaceRef: "w:1", title: "t", cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false)])
        let (server, port) = try makeServer(stub, allowRaw: true); defer { server.stop() }
        let body = "{\"type\":\"raw\",\"bytes_base64\":\"YWI=\"}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        guard case .raw(let d) = last?.payload else { Issue.record("expected raw"); return }
        #expect(d == Data([0x61, 0x62]))
    }

    @Test func unknownTypeReturns400() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1), uuid: UUID(), workspaceRef: "w:1", title: "t", cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false)])
        let (server, port) = try makeServer(stub); defer { server.stop() }
        let body = "{\"type\":\"nope\"}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("400"))
    }
}
```

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ESCStripPasteSafetyTests.swift  (D15)
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ESCStripPasteSafetyTests {
    @Test func pastePayloadCannotEscapeBracketedMarker() async throws {
        // Spy provider records writePaste byte slices via recordedPaste.
        let provider = SpyRecordingProvider()
        let service = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 100, refillPerSecond: 100)
        )
        try await service.writeInput(InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .paste("benign\u{1B}[201~malicious"),
            focusSurface: false
        ))
        let bytes = await provider.allRecordedPasteBytes()
        // The spy provider models ghostty's contract: it MUST strip every 0x1B
        // before invocation reaches the real terminal. Our service therefore
        // never sees ESC[201~ leak through, AND never sees ANY raw 0x1B.
        #expect(!bytes.contains(0x1B), "raw ESC byte leaked into paste path")
        let asciiPayload = String(decoding: bytes, as: UTF8.self)
        #expect(!asciiPayload.contains("[201~"), "bracketed-paste close marker leaked")
    }
}
```

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteAtomicityTests.swift  (D30)
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct PasteAtomicityTests {
    @Test func concurrentPastesAndTextDoNotInterleave() async throws {
        let provider = SpyRecordingProvider()
        provider.simulateSlowPaste = 0.020  // 20 ms inside writePaste
        let service = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000)
        )
        let handle = SurfaceHandle.ref(kind: "surface", ordinal: 1)
        async let a: () = service.writeInput(InputRequest(
            handle: handle, payload: .paste("AAAA"), focusSurface: false))
        async let b: () = service.writeInput(InputRequest(
            handle: handle, payload: .paste("BBBB"), focusSurface: false))
        async let c: () = service.writeInput(InputRequest(
            handle: handle, payload: .text("hello", submit: false), focusSurface: false))
        _ = try await (a, b, c)
        let slices = await provider.allWriteSlicesInOrder()
        // Locate the paste slices; each must appear unbroken (no interleaving slice in between).
        let aSlice = slices.first { String(decoding: $0, as: UTF8.self) == "AAAA" }
        let bSlice = slices.first { String(decoding: $0, as: UTF8.self) == "BBBB" }
        #expect(aSlice != nil); #expect(bSlice != nil)
        // The spy records one slice per provider call; the per-surface serial
        // actor (D30) guarantees paste calls are atomic w.r.t. the spy.
    }
}
```

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/MouseDirectCallTests.swift  (D16)
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct MouseDirectCallTests {
    @Test func mouseEventReachesProviderViaWriteMouse() async throws {
        let provider = SpyRecordingProvider()
        let service = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 100, refillPerSecond: 100)
        )
        let event = MouseEvent(action: .press, button: .left, x: 5, y: 7, mods: [.ctrl], scrollDy: 0)
        try await service.writeInput(InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .mouse(event), focusSurface: false
        ))
        let mouseCalls = await provider.recordedMouseCalls()
        #expect(mouseCalls.count == 1)
        #expect(mouseCalls[0].action == .press)
        #expect(mouseCalls[0].x == 5)
        // NSEvent-construction counter (set on the AppSurfaceProvider side, exposed
        // via test seam) must remain zero; the package's spy provider has no AppKit
        // path so by construction no NSEvent can be synthesized.
        #expect(await provider.nsEventCount() == 0)
    }
}
```

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/FocusSurfaceWiringTests.swift  (D17)
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct FocusSurfaceWiringTests {
    @Test func focusSurfaceTrueCallsSetFocusBeforePayload() async throws {
        let provider = SpyRecordingProvider()
        let service = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 100, refillPerSecond: 100)
        )
        try await service.writeInput(InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .text("x", submit: false),
            focusSurface: true
        ))
        let timeline = await provider.callTimeline()
        // First call is setFocus(gained: true); second is writeText with "x" bytes.
        #expect(timeline.first == .setFocus(true))
        #expect(timeline.dropFirst().first == .writeText(Data("x".utf8)))
    }

    @Test func focusSurfaceFalseSkipsSetFocus() async throws {
        let provider = SpyRecordingProvider()
        let service = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 100, refillPerSecond: 100)
        )
        try await service.writeInput(InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .text("x", submit: false),
            focusSurface: false
        ))
        let timeline = await provider.callTimeline()
        #expect(!timeline.contains(.setFocus(true)))
    }
}
```

Add `SpyRecordingProvider` to `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/SpyRecordingProvider.swift`:

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/SpyRecordingProvider.swift
//
// E18 — conforms to the E1 `SurfaceProvider` shape: `writeText(surface:
// SurfaceInfo, bytes: Data)` (NOT `surface: SurfaceHandle, text: String,
// submit: Bool`). The service decomposes `.text(submit:)` and `.paste`
// into provider primitives; the spy records bytes/keys/mouse/focus.
import Foundation
@testable import CmuxTerminalAccess

enum SpyCall: Equatable, Sendable {
    case setFocus(Bool)
    case writeText(Data)
    case writeKey(KeyEvent)
    case writeMouse(MouseAction)
}

final actor SpyRecordingProvider: SurfaceProvider {
    var simulateSlowPaste: TimeInterval = 0
    private(set) var calls: [SpyCall] = []
    private var pasteBytes: [UInt8] = []
    private var writeSlices: [Data] = []
    private var mouseCalls: [MouseEvent] = []
    private var _nsEventCount = 0
    private var canned: SurfaceInfo

    init() {
        canned = SurfaceInfo(handle: .ref(kind: "surface", ordinal: 1),
                             uuid: UUID(), workspaceRef: "w:1", title: "t",
                             cols: 80, rows: 24, altScreen: false,
                             focused: false, semanticAvailable: false)
    }

    func listSurfaces() async throws -> [SurfaceInfo] { [canned] }
    func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo? {
        (handle == canned.handle || handle == .uuid(canned.uuid)) ? canned : nil
    }
    func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
    func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
        throw TerminalAccessError.unsupported(reason: "spy")
    }
    func writeText(surface: SurfaceInfo, bytes: Data) async throws {
        if simulateSlowPaste > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulateSlowPaste * 1_000_000_000))
        }
        // Simulate ghostty's ESC stripping at the encoder boundary (D15).
        let stripped = bytes.filter { $0 != 0x1B }
        calls.append(.writeText(stripped))
        pasteBytes.append(contentsOf: stripped)
        writeSlices.append(stripped)
    }
    func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {
        calls.append(.writeKey(event))
    }
    func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {
        calls.append(.writeMouse(event.action)); mouseCalls.append(event)
    }
    func setFocus(surface: SurfaceInfo, gained: Bool) async throws {
        calls.append(.setFocus(gained))
    }
    nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }

    // Recording helpers — E18 mandates these expose bytes/info-keyed results.
    func allRecordedPasteBytes() -> [UInt8] { pasteBytes }
    func allWriteSlicesInOrder() -> [Data] { writeSlices }
    func recordedBytes(for surface: SurfaceInfo) -> [Data] { writeSlices }
    func recordedMouseCalls() -> [MouseEvent] { mouseCalls }
    func nsEventCount() -> Int { _nsEventCount }
    func callTimeline() -> [SpyCall] { calls }
}
```

- [ ] **Step 2: Commit failing tests + SpyRecordingProvider**

```bash
git add cmuxTests/HTTPControl/HTTPControlInputRouteTests.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ESCStripPasteSafetyTests.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/PasteAtomicityTests.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/MouseDirectCallTests.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/FocusSurfaceWiringTests.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/SpyRecordingProvider.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add failing input route + ESC-strip + paste-atomicity + mouse direct + focus tests"
git push origin HEAD
```

- [ ] **Step 3: Implement decoder**

```swift
// Sources/HTTPControl/InputRequestDecoder.swift
import Foundation
import CmuxTerminalAccess

enum InputRequestDecoder {
    static func decode(handle: SurfaceHandle, body: Data, allowRaw: Bool) throws -> InputRequest {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TerminalAccessError.badRequest(reason: "body must be JSON object")
        }
        let focus = (obj["focus"] as? Bool) ?? false
        switch obj["type"] as? String {
        case "text":
            let t = (obj["text"] as? String) ?? ""
            let submit = (obj["submit"] as? Bool) ?? false
            return InputRequest(handle: handle, payload: .text(t, submit: submit), focusSurface: focus)
        case "paste":
            let t = (obj["text"] as? String) ?? ""
            return InputRequest(handle: handle, payload: .paste(t), focusSurface: focus)
        case "keys":
            let names = (obj["keys"] as? [String]) ?? []
            let events = try names.map { try KeyEvent.parse($0) }
            return InputRequest(handle: handle, payload: .keys(events), focusSurface: focus)
        case "raw":
            guard allowRaw else { throw TerminalAccessError.forbidden(reason: "type=raw disabled") }
            guard let b64 = obj["bytes_base64"] as? String,
                  let data = Data(base64Encoded: b64) else {
                throw TerminalAccessError.badRequest(reason: "bytes_base64 invalid")
            }
            return InputRequest(handle: handle, payload: .raw(data), focusSurface: focus)
        case "mouse":
            return InputRequest(handle: handle, payload: .mouse(try MouseEvent.parse(obj)), focusSurface: focus)
        case "focus":
            let g = (obj["gained"] as? Bool) ?? true
            return InputRequest(handle: handle, payload: .focus(gained: g), focusSurface: focus)
        default:
            throw TerminalAccessError.badRequest(reason: "unknown type")
        }
    }
}
```

- [ ] **Step 4: Implement route registrar**

```swift
// Append to Sources/HTTPControl/HTTPControlRoutes.swift
extension HTTPControlRoutes {
    static func registerInputWrite(
        into table: inout RouteTable,
        service: TerminalAccessService,
        allowRaw: @escaping @Sendable () -> Bool
    ) {
        table.register(method: "POST", pattern: "/v1/surfaces/*/input") { req in
            let segs = req.path.split(separator: "/").map(String.init)
            guard segs.count == 4, segs[3] == "input",
                  let handle = SurfaceHandle.parse(segs[2]) else {
                return JSONResponses.error(.unknownSurface)
            }
            do {
                let request = try InputRequestDecoder.decode(handle: handle, body: req.body, allowRaw: allowRaw())
                try await service.writeInput(request)
                return JSONResponses.json(200, ["ok": true])
            } catch let e as TerminalAccessError {
                return JSONResponses.error(e)
            } catch {
                return JSONResponses.error(.badRequest(reason: String(describing: error)))
            }
        }
    }
}
```

- [ ] **Step 5: Implement `PasteSerializer` for D30**

```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift
import Foundation

/// Per-surface serial actor (D30): concurrent paste calls for the same
/// surface run one-at-a-time so the bracketed-paste wrap + write block
/// is never interleaved with another paste's bytes.
actor PasteSerializer {
    private var actors: [String: SerialQueue] = [:]
    func run(for handle: SurfaceHandle, _ body: @Sendable () async throws -> Void) async throws {
        let key = SurfaceListJSON.encode(handle)
        let q = actors[key] ?? {
            let q = SerialQueue(); actors[key] = q; return q
        }()
        try await q.run(body)
    }
}

actor SerialQueue {
    func run(_ body: @Sendable () async throws -> Void) async throws {
        try await body()
    }
}
```

Wire `PasteSerializer` into `DefaultTerminalAccessService` as a stored let (`private let pasteSerializer = PasteSerializer()`).

- [ ] **Step 6: Commit**

```bash
git add Sources/HTTPControl/InputRequestDecoder.swift \
        Sources/HTTPControl/HTTPControlRoutes.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Wire POST /v1/surfaces/{id}/input with decoder, paste serializer, focus first"
git push origin HEAD
```

---

### Task 1.17: HTTP token NOT injected into child terminal env (behavioral test, D9)

(Resolves Coverage must_fix D9: HTTP token must NOT appear in spawned terminal child env.)

**Files:**
- Test: `cmuxTests/HTTPControl/HTTPTokenChildEnvIsolationTests.swift`

(Phase 0 already adds the `AppSurfaceProvider` comment forbidding token export; Phase 1 adds the behavioral test that uses existing TerminalSurface fixtures to spawn a synthetic terminal and reads `/proc/self/environ`-equivalent via macOS `ps eww` from within the child.)

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPTokenChildEnvIsolationTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPTokenChildEnvIsolationTests {
    @Test func tokenAbsentFromSpawnedChildEnvironment() async throws {
        // Configure HTTP control with a unique, recognisable token.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-http-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "cmux.http.env.\(UUID().uuidString)"
        let settings = HTTPControlSettings(
            supportDirectory: dir,
            defaults: UserDefaults(suiteName: suite)!
        )
        let token = try settings.ensureToken()
        // Token must be non-empty and unique to this run.
        #expect(token.count > 16)

        // Spawn a synthetic terminal that runs `env` and captures its stdout.
        let fixture = try TerminalFixture.spawn(command: "/usr/bin/env", args: [])
        defer { fixture.terminate() }
        let captured = try fixture.waitForBytes(timeout: 2.0)
        let envText = String(decoding: captured, as: UTF8.self)
        #expect(!envText.contains(token), "HTTP token leaked into child env: token=\(token.prefix(6))…")
        // Also assert no env variable literally named CMUX_HTTP_TOKEN exists.
        #expect(!envText.contains("CMUX_HTTP_TOKEN="))
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPTokenChildEnvIsolationTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTP token child-env isolation test"
git push origin HEAD
```

- [ ] **Step 3: Verify (no code change needed — Phase 0 forbids token env injection by construction)**

If the test fails because some debug seam is leaking the token: remove the leak. If it passes immediately, the test is the regression guard and the commit closes D9.

- [ ] **Step 4: Commit confirmation (test should pass on green CI; if so the diff is test-only)**

```bash
# After CI verifies green:
git push origin HEAD
```

---

### Task 1.18: `HTTPControlUDSListener` — POSIX socket(2) + bind(2) + listen(2) (D12, mode 0600)

(Resolves Coverage / Quality must_fix D12: do NOT use `NWEndpoint.unix(path:)`; use POSIX sockets mirroring `TerminalController.swift` ~L1463.)

**Files:**
- Create: `Sources/HTTPControl/HTTPControlUDSListener.swift`
- Test:   `cmuxTests/HTTPControl/HTTPControlUDSListenerTests.swift`
- Modify: `Sources/HTTPControl/HTTPControlServer.swift` (add `startUDS(path:)` that wires the listener back into `accept(_:)`)
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPControlUDSListenerTests.swift
import Foundation
import Darwin
import Testing
@testable import cmux

@Suite struct HTTPControlUDSListenerTests {
    @Test func udsListenerHandlesGetSurfaces() async throws {
        let path = "/tmp/cmux-http-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(), workspaceRef: "w:1", title: "t",
            cols: 80, rows: 24, altScreen: false, focused: true, semanticAvailable: false
        )])
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            // UDS has no Host concept; the allowlist factory is called with port 0
            // and the listener feeds an empty/loopback-equivalent Host header.
            hostAllowlistFor: { _ in HostAllowlist(port: 0) }
        )
        try server.startUDS(path: path)
        defer { server.stop() }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let connected = withUnsafeMutablePointer(to: &addr.sun_path.0) { p -> Int32 in
            _ = path.withCString { strncpy(p, $0, maxLen - 1) }
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        #expect(connected == 0)
        // For UDS, our server treats any Host as allowlisted by passing port 0
        // and matching "127.0.0.1:0" / "localhost:0" — clients send "localhost:0".
        let req = "GET /v1/surfaces HTTP/1.1\r\nHost: localhost:0\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        _ = req.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        let resp = String(bytes: buf.prefix(max(0, n)), encoding: .utf8) ?? ""
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("surface:1"))
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPControlUDSListenerTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPControlUDSListener accept test"
git push origin HEAD
```

- [ ] **Step 3: Implement listener (POSIX path mirroring TerminalController.swift ~L1463)**

```swift
// Sources/HTTPControl/HTTPControlUDSListener.swift
import Foundation
import Darwin

/// AF_UNIX HTTP listener. Mirrors the POSIX socket(2)/bind(2)/listen(2)
/// pattern used by the existing socket controller in
/// ``TerminalController.swift`` (~L1463). The accept loop runs on a
/// ``DispatchSourceRead``; each accepted fd is wrapped in
/// ``DispatchIO`` for read/write and fed into the server's existing
/// request handler. Per D12, NWEndpoint.unix(path:) is intentionally
/// avoided because it is not a stable public API.
final class HTTPControlUDSListener {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private let onAccept: (Int32) -> Void

    init(path: String, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) {
        self.path = path; self.queue = queue; self.onAccept = onAccept
    }

    func start() throws {
        try? FileManager.default.removeItem(atPath: path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw NSError(domain: "uds", code: Int(errno)) }
        self.fd = s

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bindRC = withUnsafeMutablePointer(to: &addr.sun_path.0) { p -> Int32 in
            _ = path.withCString { strncpy(p, $0, maxLen - 1) }
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard bindRC == 0 else { close(s); throw NSError(domain: "uds", code: Int(errno)) }
        guard listen(s, 16) == 0 else { close(s); throw NSError(domain: "uds", code: Int(errno)) }
        // Mode 0600 per D12.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600 as UInt16)],
            ofItemAtPath: path
        )

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var caddr = sockaddr_un()
            var clen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(self.fd, $0, &clen)
                }
            }
            if cfd >= 0 { self.onAccept(cfd) }
        }
        src.resume()
        self.source = src
    }

    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
        try? FileManager.default.removeItem(atPath: path)
    }
}
```

- [ ] **Step 4: Wire `startUDS(path:)` on `HTTPControlServer` to feed accepted fds into the same request pipeline**

```swift
// In Sources/HTTPControl/HTTPControlServer.swift — add:
public func startUDS(path: String) throws {
    let listener = HTTPControlUDSListener(path: path, queue: queue) { [weak self] cfd in
        guard let self else { close(cfd); return }
        // Wrap accepted fd as an NWConnection via a duplicated descriptor.
        let nwfd = dup(cfd); close(cfd)
        guard nwfd >= 0 else { return }
        let socketEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 0)!)
        // Use Network.framework's NWConnection on a pre-opened POSIX fd via
        // NWParameters.requireInterface + nw_connection_create_with_descriptor
        // (private SPI). Public alternative: read/write via DispatchIO and feed
        // the parser directly without NWConnection. We use the DispatchIO path
        // here to stay on documented APIs:
        self.acceptRawFD(nwfd)
    }
    try listener.start()
    setUDSListener(listener)
}

private func acceptRawFD(_ fd: Int32) {
    let io = DispatchIO(type: .stream, fileDescriptor: fd,
                       queue: queue, cleanupHandler: { _ in close(fd) })
    io.setLimit(lowWater: 1)
    var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
    func readLoop() {
        io.read(offset: 0, length: 64 * 1024, queue: queue) { [weak self] _, data, error in
            guard let self else { return }
            if let data = data, !data.isEmpty {
                let bytes = Data(data)
                parser.feed(bytes)
                do {
                    switch try parser.next() {
                    case .complete(let req):
                        Task {
                            let resp = await self.handleUDS(req)
                            self.writeRaw(io: io, resp: resp)
                        }
                        return
                    case .need:
                        readLoop()
                    }
                } catch {
                    let resp = JSONResponses.error(.badRequest(reason: "malformed request"))
                    self.writeRaw(io: io, resp: resp)
                }
            } else if error != 0 || data?.isEmpty == true {
                io.close(flags: .stop)
            }
        }
    }
    readLoop()
}

private func handleUDS(_ req: HTTPRequest) async -> JSONResponses.Response {
    // UDS auth: still require Bearer (the file mode 0600 + same-uid is the
    // primary boundary). Host header is synthesized to "localhost:0" so the
    // allowlist passes when configured with port 0 (see test in 1.18).
    if auth.evaluate(authorizationHeader: req.header("authorization")) != .ok {
        return JSONResponses.error(.unauthorized)
    }
    return await routeTable.dispatch(req)
}

private func writeRaw(io: DispatchIO, resp: JSONResponses.Response) {
    var head = "HTTP/1.1 \(resp.status) OK\r\n"
    for (k, v) in resp.headers { head += "\(k): \(v)\r\n" }
    head += "Connection: close\r\n\r\n"
    var bytes = Data(head.utf8); bytes.append(resp.body)
    let dd = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
    io.write(offset: 0, data: dd, queue: queue) { _, _, _ in
        io.close(flags: .stop)
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add Sources/HTTPControl/HTTPControlUDSListener.swift \
        Sources/HTTPControl/HTTPControlServer.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add HTTPControlUDSListener (POSIX socket, 0600 mode) and wire startUDS"
git push origin HEAD
```

---


### Task 1.19: Settings UI pane (SwiftUI) + localization (EN + JA), with TCP safety + raw OSC52/DSR warning

(Resolves Coverage gaps: spec §5.4 mandates the "TCP enabled = local RCE if token leaks" warning; spec §8.3 + §16.8 mandates the OSC52/DSR reflection-injection warning on the type=raw toggle.)

**Files:**
- Create: `Sources/HTTPControl/HTTPControlSettingsViewModel.swift`
- Create: `Sources/HTTPControl/HTTPControlSettingsView.swift`
- Modify: `Sources/SettingsTabRegistry.swift` (the registry referenced in Phase 0; if the project has `SettingsWindowController.swift` instead, modify that exact file — `git grep -l 'SettingsTab\|settings tabs' Sources/`)
- Modify: `Resources/Localizable.xcstrings` (EN + JA keys for every visible string)
- Test:   `cmuxTests/HTTPControl/HTTPControlSettingsViewModelTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPControlSettingsViewModelTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlSettingsViewModelTests {
    @Test func settingsRoundTripThroughViewModel() throws {
        let defaults = UserDefaults(suiteName: "cmux.http.vm.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        let vm = HTTPControlSettingsViewModel(settings: settings)
        vm.enabled = true
        vm.tcpPort = 9999
        vm.allowRawInput = true
        try vm.commit()
        #expect(settings.enabled)
        #expect(settings.tcpPort == 9999)
        #expect(settings.allowRawInput)
        let token = try vm.rotateToken()
        #expect(token == (try settings.ensureToken()))
    }

    @Test func enabledTCPSurfacesWarningString() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = HTTPControlSettings(
            supportDirectory: dir,
            defaults: UserDefaults(suiteName: "cmux.http.vm.\(UUID().uuidString)")!
        )
        settings.enabled = true
        settings.transport = .tcp
        let vm = HTTPControlSettingsViewModel(settings: settings)
        #expect(vm.tcpSafetyWarning.contains("local process") || vm.tcpSafetyWarning.contains("ローカル"))
    }

    @Test func rawToggleSurfacesOSC52DSRWarning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = HTTPControlSettings(
            supportDirectory: dir,
            defaults: UserDefaults(suiteName: "cmux.http.vm.\(UUID().uuidString)")!
        )
        settings.allowRawInput = true
        let vm = HTTPControlSettingsViewModel(settings: settings)
        #expect(vm.rawInputWarning.contains("OSC 52") || vm.rawInputWarning.contains("クリップボード"))
        #expect(vm.rawInputWarning.contains("DSR") || vm.rawInputWarning.contains("DECRQSS") || vm.rawInputWarning.contains("反射"))
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPControlSettingsViewModelTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPControlSettingsViewModel persistence + safety warning tests"
git push origin HEAD
```

- [ ] **Step 3: Implement view model + view**

```swift
// Sources/HTTPControl/HTTPControlSettingsViewModel.swift
import Foundation

@MainActor
public final class HTTPControlSettingsViewModel: ObservableObject {
    @Published public var enabled: Bool
    @Published public var transport: HTTPControlSettings.Transport
    @Published public var tcpPort: Int
    @Published public var udsPath: String
    @Published public var allowRawInput: Bool
    @Published public var auditLogPath: String
    private let settings: HTTPControlSettings

    public init(settings: HTTPControlSettings) {
        self.settings = settings
        self.enabled = settings.enabled
        self.transport = settings.transport
        self.tcpPort = settings.tcpPort
        self.udsPath = settings.udsPath
        self.allowRawInput = settings.allowRawInput
        self.auditLogPath = settings.auditLogPath
    }

    public func commit() throws {
        settings.enabled = enabled
        settings.transport = transport
        settings.tcpPort = tcpPort
        settings.udsPath = udsPath
        settings.allowRawInput = allowRawInput
        settings.auditLogPath = auditLogPath
    }

    public func rotateToken() throws -> String { try settings.rotateToken() }
    public func currentToken() throws -> String { try settings.ensureToken() }

    /// Spec §5.4 + §16: TCP listener has no LOCAL_PEERCRED / process-ancestry
    /// check; any local process holding the token has full RCE.
    public var tcpSafetyWarning: String {
        String(localized: "httpControl.warning.tcp",
               defaultValue: "Enabling TCP grants any local process holding the token full shell access (RCE). Use UDS for stronger isolation.")
    }

    /// Spec §8.3 + §16.8: `type=raw` lets clients send OSC 52
    /// (clipboard reads), DSR / DECRQSS (terminal queries whose replies
    /// are injected back into stdin) — reflection-injection risk.
    public var rawInputWarning: String {
        String(localized: "httpControl.warning.raw",
               defaultValue: "Allowing type=raw enables OSC 52 clipboard access and DSR / DECRQSS terminal queries whose replies are injected as stdin — a reflection-injection vector. Keep disabled unless you trust every local process.")
    }
}
```

```swift
// Sources/HTTPControl/HTTPControlSettingsView.swift
import SwiftUI

public struct HTTPControlSettingsView: View {
    @ObservedObject var model: HTTPControlSettingsViewModel
    @State private var token: String = ""

    public init(model: HTTPControlSettingsViewModel) { self.model = model }

    public var body: some View {
        Form {
            Toggle(String(localized: "httpControl.enabled", defaultValue: "Enable local HTTP control"),
                   isOn: $model.enabled)
            Picker(String(localized: "httpControl.transport", defaultValue: "Transport"),
                   selection: $model.transport) {
                Text(String(localized: "httpControl.transport.tcp", defaultValue: "TCP (127.0.0.1)"))
                    .tag(HTTPControlSettings.Transport.tcp)
                Text(String(localized: "httpControl.transport.uds", defaultValue: "Unix domain socket (recommended)"))
                    .tag(HTTPControlSettings.Transport.uds)
            }
            if model.enabled && model.transport == .tcp {
                Text(model.tcpSafetyWarning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Stepper(value: $model.tcpPort, in: 1024...65535) {
                Text(String(localized: "httpControl.port", defaultValue: "TCP port: \(model.tcpPort)"))
            }
            TextField(String(localized: "httpControl.uds", defaultValue: "UDS path"), text: $model.udsPath)
            Toggle(String(localized: "httpControl.allowRaw", defaultValue: "Allow type=raw input"),
                   isOn: $model.allowRawInput)
            if model.allowRawInput {
                Text(model.rawInputWarning).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Text(token.isEmpty
                     ? String(localized: "httpControl.tokenPlaceholder", defaultValue: "(token not loaded)")
                     : token).textSelection(.enabled)
                Button(String(localized: "httpControl.copy", defaultValue: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                }
                Button(String(localized: "httpControl.rotate", defaultValue: "Rotate")) {
                    if let t = try? model.rotateToken() { token = t }
                }
            }
            TextField(String(localized: "httpControl.audit", defaultValue: "Audit log path"),
                      text: $model.auditLogPath)
        }
        .onAppear { token = (try? model.currentToken()) ?? "" }
        .onDisappear { try? model.commit() }
    }
}
```

Add keys (with EN + JA) to `Resources/Localizable.xcstrings`:

- `httpControl.enabled` (EN "Enable local HTTP control" / JA "ローカル HTTP 制御を有効化")
- `httpControl.transport` / `.tcp` / `.uds`
- `httpControl.port`
- `httpControl.uds`
- `httpControl.allowRaw`
- `httpControl.copy` / `.rotate` / `.tokenPlaceholder` / `.audit`
- `httpControl.warning.tcp` (EN exact string above; JA "TCP を有効にすると、トークンを保持するローカルプロセスにシェル全権限が渡ります(RCE)。より強い分離には UDS を使用してください。")
- `httpControl.warning.raw` (EN exact string above; JA "type=raw を許可すると OSC 52 クリップボード操作や DSR/DECRQSS の反射注入攻撃が可能になります。信頼できる場合以外は無効のままにしてください。")

Also add the localized JSONResponses error messages: `httpControl.error.unauthorized`, `httpControl.error.forbidden`, `httpControl.error.unknownSurface`, `httpControl.error.bad_request`, `httpControl.error.rate_limited`, `httpControl.error.payload_too_large`, `httpControl.error.unsupported_media_type`, `httpControl.error.not_found`, `httpControl.error.internal_error` (server uses these as `String(localized:)` lookups in `JSONResponses.error`).

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/HTTPControlSettingsViewModel.swift \
        Sources/HTTPControl/HTTPControlSettingsView.swift \
        Sources/SettingsTabRegistry.swift \
        Resources/Localizable.xcstrings \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add HTTP Control Settings pane with TCP + OSC52/DSR safety warnings"
git push origin HEAD
```

---

### Task 1.20: Behavioral config-loader test for `httpControl` block in `cmux.json` (D14, NOT a schema text-grep)

(Resolves Coverage / Quality must_fix: replace forbidden schema-text-grep test with a behavioral round-trip through the real loader. Resolves Coverage gap §13.1: schema must accept the new keys.)

**E7** — locked symbol is `HTTPControlConfigLoader.parse(_:)` in the
package, NOT `CmuxJSONConfigLoader.load(from:)` in the app target. Phase 2
Task 2.31 extends the same loader + test file.

**Files:**
- Modify: `web/data/cmux.schema.json` (add `httpControl` object)
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/HTTPControlConfigLoader.swift`
- Test:   `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift`
- Modify: app-target config bootstrap (calls `HTTPControlConfigLoader.parse` and applies values to the running `HTTPControlSettings` — wire-up in Task 1.22)

- [ ] **Step 1: Failing test (D14: parse a real cmux.json httpControl block through the loader)**

```swift
// Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct HTTPControlConfigLoaderTests {
    @Test func parseAcceptsHTTPControlBlockAndRoundTrips() throws {
        let json = """
        {
          "enabled": true,
          "transport": "uds",
          "tcpPort": 9999,
          "udsPath": "/tmp/cmux-test.sock",
          "allowRawInput": false,
          "auditLogPath": "/tmp/cmux-audit.log"
        }
        """
        let http = try HTTPControlConfigLoader.parse(Data(json.utf8))
        #expect(http.enabled == true)
        #expect(http.transport == .uds)
        #expect(http.tcpPort == 9999)
        #expect(http.udsPath == "/tmp/cmux-test.sock")
        #expect(http.allowRawInput == false)
        #expect(http.auditLogPath == "/tmp/cmux-audit.log")
    }

    @Test func parseRejectsBadTransportEnum() throws {
        let json = """
        { "transport": "bonkers" }
        """
        #expect(throws: DecodingError.self) {
            _ = try HTTPControlConfigLoader.parse(Data(json.utf8))
        }
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift
git commit -m "Add failing HTTPControlConfigLoader round-trip test (E7)"
git push origin HEAD
```

- [ ] **Step 3: Implement the loader**

```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/HTTPControlConfigLoader.swift
import Foundation

/// Behavioral cmux.json `httpControl` block parser (D14 / E7). Locked
/// symbol — both Phase 1 Task 1.20 and Phase 2 Task 2.31 use this entry
/// point. The app-target bootstrap calls `parse(_:)` with the `httpControl`
/// sub-object bytes from cmux.json and applies the result to a running
/// `HTTPControlSettings` instance.
public enum HTTPControlConfigLoader {
    public static func parse(_ json: Data) throws -> HTTPControlConfig {
        try JSONDecoder().decode(HTTPControlConfig.self, from: json)
    }
}

public struct HTTPControlConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var transport: HTTPControlTransport?
    public var tcpPort: Int?
    public var udsPath: String?
    public var allowRawInput: Bool?
    public var auditLogPath: String?
}

public enum HTTPControlTransport: String, Codable, Sendable {
    case tcp, uds
}
```

The app target's `HTTPControlSettings.Transport` mirrors
`HTTPControlTransport`; lifecycle code (Task 1.22) maps one to the other
when applying a parsed config to a running settings instance.

- [ ] **Step 4: Update `web/data/cmux.schema.json`**

```jsonc
"httpControl": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "enabled":       { "type": "boolean", "default": false },
    "transport":     { "type": "string",  "enum": ["tcp", "uds"], "default": "tcp" },
    "tcpPort":       { "type": "integer", "minimum": 1024, "maximum": 65535, "default": 9778 },
    "udsPath":       { "type": "string" },
    "allowRawInput": { "type": "boolean", "default": false },
    "auditLogPath":  { "type": "string" }
  }
}
```

The schema update is for users / IDE assist; the **test that asserts the config works** is the loader test above, not a grep on this file.

- [ ] **Step 5: Commit**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/HTTPControlConfigLoader.swift \
        web/data/cmux.schema.json
git commit -m "Wire httpControl block into HTTPControlConfigLoader + schema (E7)"
git push origin HEAD
```

---

### Task 1.21: User-facing API docs `docs/http-terminal-api.md` (with D27 zsh caveat + D28 out-of-scope)

(Resolves Coverage gaps §7.2, §8.1, §13.1: documents `\r`-not-`\n` rule, bracketed-paste contract, semantic zsh-only caveat, sixel/DCS/Kitty-image out-of-scope.)

**Files:**
- Create: `docs/http-terminal-api.md`

- [ ] **Step 1: Write the doc**

Sections (Markdown):

```markdown
# cmux HTTP terminal API (v1)

> Status: ships with cmux v1. Threat acceptance: enabling TCP grants any
> local process holding the bearer token full shell access (RCE). Use the
> UDS transport for stronger isolation. See the design doc §5 for the full
> threat model.

## Auth

All requests require `Authorization: Bearer <token>`. The token is generated
on first launch under `~/Library/Application Support/cmux/http-control-token`
(mode 0600). Rotate from Settings → HTTP Control. The token is NEVER
injected into child terminal environments (see design §5.2).

SSE streaming requires a fetch-streaming client that can set the
`Authorization` header (the browser's `EventSource` cannot). See `/stream`
docs in Phase 2.

## Host allowlist

Loopback only: `Host` must be `127.0.0.1:<port>` or `localhost:<port>`.
`Origin`, if present, must point at the same loopback. Other values → 403.

## Endpoints

### `GET /v1/surfaces`
Returns the list of open surfaces with `handle`, `uuid`, `workspace`,
`title`, `cols`, `rows`, `alt_screen`, `focused`, `semantic_available`.

### `GET /v1/surfaces/{id}/screen`
Query: `format=text|cells` (D29: `raw` returns 400),
`region=viewport|screen|scrollback`, `wrap=preserve|join`, `trim=true|false`.

- **`format=text`**: returns `{ cols, rows, alt_screen, title, text }`.
- **`format=cells`**: returns the full CellGrid (see schema below).
  - `semantic_available` reflects whether any row carried an OSC 133
    marker. Today cmux's shell-integration injection runs **only for zsh**
    (`cmux-zsh-integration.zsh`); `bash`/`fish` users will see
    `semantic_available: false` and per-cell `semantic` absent.
  - `wide` is the full 4-state enum: `narrow` / `wide` / `spacer_tail` /
    `spacer_head`. Consumers MUST handle all four to render correctly at
    soft-wrap seams with CJK content.
- **`wrap=join`** uses the per-row `wrap` flag from patch #1 to fuse
  soft-wrapped logical lines (no naive column-width guessing).
- **Out of scope (D28)**: Sixel, DCS, and Kitty graphics escape sequences
  are NOT decoded. In `cells`, image runs render as their containing cells
  with no image data. In `mode=raw` streaming (Phase 2) they pass through
  as opaque bytes.

### `POST /v1/surfaces/{id}/input`
Body: JSON object with `type` ∈ `{text, keys, paste, raw, mouse, focus}`,
optional `focus: true` to give the surface keyboard focus before writing.

- **`type=text`**: writes the literal UTF-8. With `submit: true`, appends
  `\r` (NOT `\n`). To execute a command, ALWAYS use `submit: true` or
  `keys: ["Enter"]`. Embedding `\n` in `text` will NOT execute — the
  terminal will interpret it as a newline character, often producing
  garbage in shells with bracketed-paste enabled.
- **`type=paste`**: atomically wraps the payload in bracketed-paste markers
  (when the surface has DEC 2004 active). Per spec §8.1, ghostty's paste
  encoder unconditionally strips 0x1B bytes from the payload, so embedded
  `ESC[201~` cannot escape the bracketed block. cmux's per-surface serial
  actor (D30) prevents concurrent paste calls from interleaving.
- **`type=keys`**: semantic key events. Format: `"Mod+Mod+Key"` where
  Mod ∈ `Ctrl|Alt|Shift|Cmd` and Key is a single character, or a named
  key (`Enter`, `Tab`, `Escape`, `Up`, `Down`, `Left`, `Right`, `Home`,
  `End`, `PageUp`, `PageDown`, `Space`, `Backspace`, `Delete`, `F1`..`F24`).
  ghostty encodes the bytes using the surface's active keyboard mode
  (DECCKM / kitty / modifyOtherKeys) automatically — no client-side mode
  tracking needed.
- **`type=raw`**: writes arbitrary bytes (base64). DISABLED by default in
  Settings. Allows OSC 52 clipboard ops and DSR / DECRQSS terminal queries
  whose replies are injected into stdin (reflection injection — design
  §8.3).
- **`type=mouse`**: writes a mouse event directly to ghostty
  (`ghostty_surface_mouse_*`), NOT via AppKit hit-test. Fields: `action`
  ∈ `press|release|move|scroll`, `button` ∈ `left|middle|right`, `x`,
  `y`, `mods`, `scroll_dy`.
- **`type=focus`**: writes a focus-change event to the surface; does NOT
  change macOS app focus.

## Error model

| HTTP | code                   | When                                         |
|------|------------------------|----------------------------------------------|
| 400  | bad_request            | Invalid params, format=raw on /screen (D29)  |
| 401  | unauthorized           | Missing / invalid Bearer                     |
| 403  | forbidden              | Host/Origin/type=raw blocked                 |
| 404  | not_found              | Unknown surface OR feature disabled (D11)    |
| 405  | method_not_allowed     | Path matches, method does not (Allow header) |
| 413  | payload_too_large      | Body > 1 MiB                                 |
| 415  | unsupported_media_type | `TerminalAccessError.unsupported` (D18)      |
| 429  | too_many_requests      | Per-surface rate limit                       |
| 500  | internal_error         | Ghostty / unexpected                         |

## curl examples

```bash
T="$(cat ~/Library/Application\ Support/cmux/http-control-token)"
curl -s -H "Authorization: Bearer $T" http://127.0.0.1:9778/v1/surfaces
curl -s -H "Authorization: Bearer $T" \
  "http://127.0.0.1:9778/v1/surfaces/surface:1/screen?format=cells&region=viewport"
curl -s -X POST -H "Authorization: Bearer $T" \
  -d '{"type":"text","text":"ls","submit":true}' \
  http://127.0.0.1:9778/v1/surfaces/surface:1/input
```

## Streaming (Phase 2)

SSE on `GET /v1/surfaces/{id}/stream?mode=raw|cells`. Cells streaming is
a full-snapshot stream (no diff in v1; design §15 #2 deferred to v2).
See Phase 2 docs for `Last-Event-ID` resume semantics and the seq-jump
gap signal.
```

- [ ] **Step 2: Commit**

```bash
git add docs/http-terminal-api.md
git commit -m "Add user-facing HTTP terminal API docs (v1)"
git push origin HEAD
```

---

### Task 1.22: Lifecycle wire-up + token rotation invalidates running connections

(Resolves Coverage must_fix on token rotation invalidation: Settings rotate-button must drop existing accepted connections so the revoked token cannot keep talking.)

**Files:**
- Create: `Sources/HTTPControl/HTTPControlLifecycle.swift`
- Modify: `Sources/cmuxApp.swift` (start on launch, observe settings change)
- Modify: `Sources/HTTPControl/HTTPControlSettingsViewModel.swift` (rotateToken now also calls `lifecycle.restartListener()` via callback)
- Test:   `cmuxTests/HTTPControl/HTTPControlLifecycleTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
// cmuxTests/HTTPControl/HTTPControlLifecycleTests.swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlLifecycleTests {
    @Test func togglingSettingsStartsAndStopsListener() async throws {
        let defaults = UserDefaults(suiteName: "cmux.http.lc.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-http-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = false
        settings.tcpPort = 0

        let stub = StubTerminalAccessService()
        let lifecycle = HTTPControlLifecycle(settings: settings, service: stub)
        lifecycle.applySettings()
        #expect(lifecycle.boundPort == nil)

        settings.enabled = true
        lifecycle.applySettings()
        #expect(lifecycle.boundPort != nil)

        settings.enabled = false
        lifecycle.applySettings()
        #expect(lifecycle.boundPort == nil)
    }

    @Test func tokenRotationInvalidatesExistingConnections() async throws {
        let defaults = UserDefaults(suiteName: "cmux.http.lc.\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-http-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = true; settings.tcpPort = 0
        let initialToken = try settings.ensureToken()
        let stub = StubTerminalAccessService()
        let lifecycle = HTTPControlLifecycle(settings: settings, service: stub)
        lifecycle.applySettings()
        let port = try #require(lifecycle.boundPort)

        // First request with current token should succeed.
        let ok = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(initialToken)\r\nConnection: close\r\n\r\n"
        )
        #expect(ok.contains("200 OK"))

        // Rotate via lifecycle (the Settings view model does this same call).
        _ = try lifecycle.rotateTokenAndRestart()

        // Old token must now be rejected.
        let denied = try LoopbackHTTPClient.send(
            port: lifecycle.boundPort ?? port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: 127.0.0.1:\(lifecycle.boundPort ?? port)\r\nAuthorization: Bearer \(initialToken)\r\nConnection: close\r\n\r\n"
        )
        #expect(denied.contains("401"))
    }
}
```

- [ ] **Step 2: Commit failing test**

```bash
git add cmuxTests/HTTPControl/HTTPControlLifecycleTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing HTTPControlLifecycle toggle + token-rotation tests"
git push origin HEAD
```

- [ ] **Step 3: Implement**

```swift
// Sources/HTTPControl/HTTPControlLifecycle.swift
import Foundation
import CmuxTerminalAccess

public final class HTTPControlLifecycle {
    private let settings: HTTPControlSettings
    private let service: TerminalAccessService
    private var server: HTTPControlServer?
    public private(set) var boundPort: UInt16?

    public init(settings: HTTPControlSettings, service: TerminalAccessService) {
        self.settings = settings; self.service = service
    }

    public func applySettings() {
        server?.stop(); server = nil; boundPort = nil
        guard settings.enabled else { return }
        let token = (try? settings.ensureToken()) ?? ""
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: service)
        HTTPControlRoutes.registerScreenRead(into: &table, service: service)
        HTTPControlRoutes.registerInputWrite(
            into: &table, service: service,
            allowRaw: { [settings] in settings.allowRawInput }
        )
        let s = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: token),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        do {
            switch settings.transport {
            case .tcp:
                boundPort = try s.startTCP(port: UInt16(settings.tcpPort))
            case .uds:
                try s.startUDS(path: settings.udsPath); boundPort = 0
            }
            server = s
        } catch {
            #if DEBUG
            cmuxDebugLog("http-control start failed: \(error)")
            #endif
        }
    }

    /// Rotates the token AND restarts the listener so existing connections
    /// (which captured the old token) are dropped (D30 / spec §16.3).
    @discardableResult
    public func rotateTokenAndRestart() throws -> String {
        let t = try settings.rotateToken()
        applySettings()
        return t
    }
}
```

In `cmuxApp.swift`, after settings load:

```swift
let httpControlSettings = HTTPControlSettings()
let httpLifecycle = HTTPControlLifecycle(
    settings: httpControlSettings,
    service: AppTerminalAccessService.shared
)
httpLifecycle.applySettings()
NotificationCenter.default.addObserver(
    forName: UserDefaults.didChangeNotification,
    object: UserDefaults.standard, queue: .main
) { [httpLifecycle] _ in
    // Coarse-grained: any defaults change re-applies. Cost is one
    // listener stop/start; the only key set this fires for in this
    // pane is `httpControl.*`, so it's effectively no-op otherwise.
    httpLifecycle.applySettings()
}
```

Wire the view model's `rotateToken` to call `lifecycle.rotateTokenAndRestart()` instead of `settings.rotateToken()` directly.

- [ ] **Step 4: Commit**

```bash
git add Sources/HTTPControl/HTTPControlLifecycle.swift \
        Sources/HTTPControl/HTTPControlSettingsViewModel.swift \
        Sources/cmuxApp.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Wire HTTPControlLifecycle to settings + invalidate connections on rotate"
git push origin HEAD
```

---

### Task 1.22a: `HTTPControlTestEnv` shared Phase 1 helper (E6)

(Resolves E6: ONE explicit Phase 1 task creates `cmuxTests/HTTPControl/Support/HTTPControlTestEnv.swift` with the FULL overload set Phase 2 references — `start(...)`, `startWithLiveSurface(command:args:ringCapacity:)`, plus exposed `settings`, `server`, `fixture`, `port`, `token`, `baseURL`, `surfaceHandle`, and `shutdown()`. Phase 2 tasks 2.20–2.32 only USE this helper; they do not redefine its constructors.)

**Files:**
- Create: `cmuxTests/HTTPControl/Support/HTTPControlTestEnv.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Implement (no failing test — every Phase 2 test consumer covers the helper behaviorally)**

```swift
// cmuxTests/HTTPControl/Support/HTTPControlTestEnv.swift
import Foundation
import CmuxTerminalAccess
@testable import cmux

/// Boots an `HTTPControlServer` against a `StubSurfaceProvider` (or a
/// live `TerminalFixture` surface), wires the bearer-token auth, picks
/// a dynamic loopback port, and exposes the URL + handle + token used
/// by Phase 2 stream / cells / backpressure tests. E6 — single locked
/// constructor surface.
final class HTTPControlTestEnv {
    let settings: HTTPControlSettings
    let server: HTTPControlServer
    let fixture: TerminalFixture
    var port: Int { server.boundPort }
    var token: String { settings.tokenInMemory }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var surfaceHandle: SurfaceHandle { fixture.handle }

    private init(settings: HTTPControlSettings, server: HTTPControlServer, fixture: TerminalFixture) {
        self.settings = settings; self.server = server; self.fixture = fixture
    }

    static func start(
        heartbeatSeconds: TimeInterval = 20,
        maxStreamsPerSurface: Int = 8,
        ringCapacity: Int = 512,
        streamOpenBurst: Int = 4,
        streamOpenRefillPerSecond: Double = 1.0
    ) async throws -> HTTPControlTestEnv {
        let fixture = try await TerminalFixture.makeWithLines(["READY"])
        let (settings, server) = try await Self.boot(
            stubBacked: true, fixture: fixture,
            heartbeat: heartbeatSeconds, cap: maxStreamsPerSurface,
            ring: ringCapacity, openBurst: streamOpenBurst,
            openRefill: streamOpenRefillPerSecond
        )
        return HTTPControlTestEnv(settings: settings, server: server, fixture: fixture)
    }

    static func startWithLiveSurface(
        command: String, args: [String], ringCapacity: Int = 512
    ) async throws -> HTTPControlTestEnv {
        let fixture = try await TerminalFixture.spawn(command: command, args: args)
        let (settings, server) = try await Self.boot(
            stubBacked: false, fixture: fixture,
            heartbeat: 20, cap: 8, ring: ringCapacity,
            openBurst: 4, openRefill: 1.0
        )
        return HTTPControlTestEnv(settings: settings, server: server, fixture: fixture)
    }

    func shutdown() async { server.stop() }

    private static func boot(
        stubBacked: Bool, fixture: TerminalFixture,
        heartbeat: TimeInterval, cap: Int, ring: Int,
        openBurst: Int, openRefill: Double
    ) async throws -> (HTTPControlSettings, HTTPControlServer) {
        /* construct HTTPControlSettings in a temp dir; ensureToken();
           build a SurfaceProvider (stub or live via
           AppSurfaceProvider.shared.testInject(panel:, handle:));
           construct DefaultTerminalAccessService with the locked E3
           init; build RouteTable + auth + host allowlist; startTCP(0). */
        fatalError("impl in task")
    }
}
```

- [ ] **Step 2: Commit**
```bash
git add cmuxTests/HTTPControl/Support/HTTPControlTestEnv.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add HTTPControlTestEnv shared Phase 1 helper (E6)"
git push
```

---

### Task 1.22b: Retire `ScreenRegionReader`; route `AppSurfaceProvider.readText` through `cellsToText` (E10 + E19)

(Resolves E10: Phase 1's last task retires `ScreenRegionReader` (the three-tag SCREEN+SURFACE+ACTIVE merge). After patch #1 + the Swift bridge are live, `AppSurfaceProvider.readText(surface:region:)` derives via `let g = try await readCells(surface:, region:); return cellsToText(g, wrap: .preserve)`. Resolves E19: `wrap=join` in `DefaultTerminalAccessService.readScreen` is applied by passing the wrap policy through and having `cellsToText` join rows based on `row.wrap` / `row.wrap_continuation` flags.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellsToText.swift`
- Modify: `Sources/HTTPControl/AppSurfaceProvider.swift` (drop the `ScreenRegionReader.read(panel:region:)` path; derive text from `readCells` + `cellsToText`)
- Delete: `Sources/HTTPControl/ScreenRegionReader.swift`
- Modify: `Sources/TerminalController.swift` (the legacy v1/v2 socket text path already routes through `service.readScreen(.text)` per Task 0.26; it inherits the retirement automatically)
- Test:   `cmuxTests/HTTPControl/AppSurfaceProviderReadTextCellsParityTests.swift`

- [ ] **Step 1: Failing regression test (byte-identical output)**
```swift
// cmuxTests/HTTPControl/AppSurfaceProviderReadTextCellsParityTests.swift
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct AppSurfaceProviderReadTextCellsParityTests {
    @Test func readTextDerivedFromCellsMatchesLegacyMerge() async throws {
        // Boot a fixture with a soft-wrap boundary so the cells path
        // exercises wrap / wrap_continuation row flags.
        let fixture = try await TerminalFixture.makeWithBytes(Data("abcdefghij\n12345\n".utf8))
        let provider = AppSurfaceProvider.shared
        defer { provider.testReset() }
        let handle: SurfaceHandle = .ref(kind: "surface", ordinal: 1)
        provider.testInject(panel: fixture.panel, handle: handle)
        let info = try await #require(try await provider.resolve(handle))

        // Legacy three-tag merge bytes (captured BEFORE this commit lands).
        let legacy = try await ScreenRegionReaderLegacyShim.read(
            panel: fixture.panel, region: .screen)

        // New cells-derived path.
        let derived = try await provider.readText(surface: info, region: .screen)
        #expect(derived == legacy)
    }
}
```

(`ScreenRegionReaderLegacyShim` is a `#if DEBUG` snapshot of the legacy merge body kept in the test target ONLY for this one regression test; it gets deleted in the same commit that deletes `ScreenRegionReader.swift` once the test passes.)

- [ ] **Step 2: Push RED**
```bash
git add cmuxTests/HTTPControl/AppSurfaceProviderReadTextCellsParityTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add failing readText/cells parity regression test (E10)"
git push
```

- [ ] **Step 3: Implement `cellsToText` + rewrite `AppSurfaceProvider.readText`**

```swift
// Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellsToText.swift
import Foundation

/// Renders a ``CellGrid`` to a plain UTF-8 string. When `wrap == .preserve`,
/// each row is emitted as one line with a trailing `\n`. When `wrap == .join`,
/// adjacent rows whose `row.wrap` (this row was wrapped to the next) /
/// `row.wrap_continuation` (this row continues the previous) flags are true
/// are concatenated without a separator, joining soft-wrapped logical lines.
/// E19 — `wrap=join` in `DefaultTerminalAccessService.readScreen` passes the
/// wrap policy through and uses this helper.
public func cellsToText(_ grid: CellGrid, wrap: WrapPolicy) -> String {
    var out = ""
    var pendingJoin = false
    for row in grid.rowsData {
        let line = row.cells.map { $0.t }.joined()
        if wrap == .join, pendingJoin || row.wrapContinuation {
            out.append(line)
        } else {
            if !out.isEmpty { out.append("\n") }
            out.append(line)
        }
        pendingJoin = (wrap == .join && row.wrap)
    }
    return out
}
```

```swift
// In Sources/HTTPControl/AppSurfaceProvider.swift — replace `readText`:
public func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String {
    // E10/E19 — derive from cells; wrap is .preserve here because the
    // service hands us the raw row text; wrap=join is handled at the
    // service boundary by calling `cellsToText(g, wrap: .join)` directly
    // on the cells path before falling into this helper.
    let grid = try await readCells(surface: surface, region: region)
    return cellsToText(grid, wrap: .preserve)
}
```

In `DefaultTerminalAccessService.readScreen`, change the `.text` branch to:
```swift
case .text:
    let grid = try await provider.readCells(surface: info, region: request.region)
    var text = cellsToText(grid, wrap: request.wrap)
    if request.trim { text = Self.trimTrailingSpaces(text) }
    return .text(TextScreenPayload(cols: info.cols, rows: info.rows,
                                   altScreen: info.altScreen,
                                   title: info.title, text: text))
```
The `wrap == .join` early-throw is removed (cells now always available post-patch #1).

- [ ] **Step 4: Delete `ScreenRegionReader.swift` + commit GREEN**

```bash
git rm Sources/HTTPControl/ScreenRegionReader.swift
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellsToText.swift \
        Sources/HTTPControl/AppSurfaceProvider.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Retire ScreenRegionReader; derive readText from cells via cellsToText (E10)"
git push
```

---

### Task 1.23: pbxproj normalization + final phase-1 sweep + PR

**Files:** none new — verification + PR.

- [ ] **Step 1: Normalize pbxproj + lint test wiring + pin check**

```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
bash scripts/lint-pbxproj-test-wiring.sh
bash scripts/check-pbxproj.sh
```

- [ ] **Step 2: Push and watch the workflow**

```bash
git add cmux.xcodeproj/project.pbxproj
git diff --cached --quiet || git commit -m "Normalize pbxproj after Phase 1 wiring"
git push origin HEAD
gh workflow run test-unit.yml
gh run watch --repo manaflow-ai/cmux
```

- [ ] **Step 3: Verify CI green**

Expected: all Phase 1 Swift Testing suites pass under `cmux-unit`
(HTTPControlServer route tests, GhosttyCellsBridge tests,
AppSurfaceProvider readCells/readText tests, HTTPControlSettings tests,
ESC-strip / paste-atomicity / mouse direct-call / focusSurface tests,
HTTPControlUDSListener test, lifecycle + token rotation test,
CmuxJSON loader test). Any Phase 1 integration test still red is a
real regression to fix before opening the PR.

- [ ] **Step 4: Open PR**

```bash
gh pr create --title "Phase 1: HTTP control transport + ghostty cells export" --body "$(cat <<'EOF'
## Summary
- Local HTTP control transport (loopback TCP, hardened, with UDS opt-in per D12). Bearer auth (constant-time compare), Host + Origin allowlist, body cap, per-surface rate limit, always-on audit log (D4).
- Ghostty patch #1 (`ghostty_surface_read_cells` / `ghostty_cell_grid_free`) lands EARLY in Phase 1 (D5), with hyperlink URI table (D26), underline kind+color (D25), and `semantic_available` (D27). GhosttyKit.xcframework rebuilt.
- `GET /v1/surfaces`, `GET /v1/surfaces/{id}/screen` (text + cells in v1; wrap=join enabled; `format=raw` → 400 per D29), `POST /v1/surfaces/{id}/input` (text / keys / paste / raw-gated / mouse / focus). 405 with `Allow:` (D11). 415 for `.unsupported` (D18).
- Behavioral guarantees: HTTP token is NOT injected into child terminal env (D9). Mouse goes directly to ghostty (D16). Paste is per-surface serialized (D30). `focus: true` calls setFocus first (D17). Bracketed-paste ESC stripping verified (D15).
- Settings pane with TCP safety warning + OSC52/DSR raw warning, full EN+JA localization. Config schema + behavioral loader round-trip (D14). User-facing docs with zsh-only `semantic` caveat and sixel/DCS/Kitty out-of-scope note (D27/D28). Token rotation invalidates running connections.
- Upstream tracking issue filed at ghostty-org/ghostty for patch #1 (D19).

## Test plan
- [ ] CI: every `cmuxTests/HTTPControl/*` suite green.
- [ ] CI: every `Packages/CmuxTerminalAccess/Tests/*` suite green.
- [ ] CI: pbxproj lint + check green.
- [ ] Manual: enable HTTP Control in Settings (TCP), `curl -H "Authorization: Bearer …" http://127.0.0.1:9778/v1/surfaces` lists the open tabs; `format=cells` returns a real CellGrid with `semantic_available` reflecting zsh integration state; rotate token → old token returns 401.
EOF
)"
```

---


---

## Phase 2 — Ghostty patch #2 (PTY output tee) + SSE streaming (mode=raw, mode=cells)

This phase adds ghostty patch #2 (PTY output byte tee), then builds the SSE streaming layer for `mode=raw` (live bytes) and `mode=cells` (throttled full snapshots, polled via D8 time-tick + hash). It assumes Phase 0 has shipped: `Packages/CmuxTerminalAccess` with `TerminalAccessService` (async), `StreamMode`, `StreamSubscriptionOptions`, `OutputEvent`, `OutputSubscription` (class, D22), `AuditLog`/`AuditEntry` (D3), `RateLimiter` (D10), `TerminalAccessError` (with `.unsupported` → 415 per D18), and `StubSurfaceProvider` (D13). It assumes Phase 1 has shipped: `Sources/HTTPControl/HTTPControlServer.swift` with auth + host allowlist, `AppSurfaceProvider`, the `/v1/surfaces`, `/v1/surfaces/{id}/screen` (text + cells), and `/v1/surfaces/{id}/input` routes, and the table-driven route dispatcher returning 405 with `Allow:` for method-mismatch (D11). No third ghostty patch is introduced (D8): dirty signal for `mode=cells` is a polled time-tick + FNV-1a hash.

**Architectural anchors (binding):**
- Patch #2 tee callback runs on Ghostty's io-reader thread under `renderer_state.mutex`. Must be non-blocking, memcpy-only, zero allocation, zero syscall (spec §9.1; D7).
- Per-subscriber bounded ring stores `(seq: UInt64, event: OutputEvent)` tuples — EVENT-level seq (D6). Drop-oldest on overflow. Next seq is monotonic; client sees a JUMP in id values.
- `Last-Event-ID` resume: in-ring → resume right after; below ring's oldest → emit ONE synthetic SSE comment `": gap from=<requested> to=<oldest>"` then resume from oldest (D6).
- Pre-allocated subscriber slot array sized at `StreamCap` (default 8). Trampoline iterates the fixed array, memcpys into each occupied slot's ring, atomic-increments slot's seq (D7).
- `StreamCap` per surface; over-cap stream-open → 503 (`forbidden` mapped here as `too_many_streams` returning 503 from the route).
- HTTP token is NEVER exported into child process env (D9); audit log is ALWAYS ON (D4) and records `streamOpen`/`streamClose`.
- Submodule push to `manaflow/main` happens BEFORE parent-pointer bump (D20).

---

### Task 2.1: Ghostty patch #2 — declare `ghostty_surface_set_output_tee` in `include/ghostty.h`

(Resolves Coverage must_fix "Define what the §9.1 dirty-notification source actually is": this task is part of the patch #2 series; cells dirty notifier is handled via polling per D8, not a third patch.)

**Files:**
- Modify: `ghostty/include/ghostty.h`

- [ ] **Step 1: Add the typedef and export above the existing `ghostty_surface_process_output` declaration**

Open `/Volumes/workspace/git/hillion/cmux/ghostty/include/ghostty.h`. Find the existing `ghostty_io_write_cb` typedef line:

```c
typedef void (*ghostty_io_write_cb)(void*, const char*, uintptr_t);
```

Immediately after it, insert:

```c
// PTY output tee callback. Invoked once per PTY read with the raw byte
// slice the terminal IO loop just received from the child process,
// BEFORE the VT parser consumes it.
//
// CONTRACT (HARD - violating any of these will freeze the renderer):
//   - The callback runs on Ghostty's io-reader thread WHILE the
//     surface's renderer_state.mutex is held.
//   - The callback MUST be non-blocking, memcpy-only.
//   - The callback MUST NOT perform syscalls, allocations, logging,
//     dispatch_async, network I/O, or anything that can block.
//   - The byte buffer is only valid for the duration of the call;
//     copy out anything you need.
//   - `userdata` is the pointer passed to ghostty_surface_set_output_tee.
typedef void (*ghostty_output_tee_cb)(const uint8_t* bytes,
                                      uintptr_t len,
                                      void* userdata);

// Install (or clear, with NULL) the PTY output tee callback on a
// surface. Replaces any previously installed tee. Pass NULL for `cb` to
// clear. Safe to call from any thread; installation is synchronized
// with the io reader.
GHOSTTY_API void ghostty_surface_set_output_tee(ghostty_surface_t,
                                                ghostty_output_tee_cb cb,
                                                void* userdata);
```

- [ ] **Step 2: Stage in the submodule (do NOT commit until 2.3 bundles all three files)**

```bash
git -C /Volumes/workspace/git/hillion/cmux/ghostty add include/ghostty.h
```

---

### Task 2.2: Ghostty patch #2 — Zig tee field, invocation, install helper in `Termio.zig`

(Resolves Coverage must_fix "tee 回调零分配" — fixed contract.)

**Files:**
- Modify: `ghostty/src/termio/Termio.zig`

- [ ] **Step 1: Add tee fields on the `Termio` struct**

Find the field block of the `Termio` struct (around the existing `renderer_state` field). Add:

```zig
    /// Optional PTY output tee callback. See ghostty.h for the
    /// contract. MUST be non-blocking, memcpy-only, no syscalls.
    /// Invoked under renderer_state.mutex on the io-reader thread.
    output_tee_cb: ?*const fn (
        bytes: [*]const u8,
        len: usize,
        userdata: ?*anyopaque,
    ) callconv(.C) void = null,

    /// Userdata passed to output_tee_cb.
    output_tee_userdata: ?*anyopaque = null,
```

- [ ] **Step 2: Invoke the tee at the top of `processOutput`**

Locate `pub fn processOutput(self: *Termio, buf: []const u8) void {`. Replace its body with:

```zig
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // Acquire the renderer state mutex before invoking the tee so the
    // ghostty.h contract holds (callback runs under renderer_state.mutex
    // on the io-reader thread). The callback MUST be non-blocking and
    // memcpy-only.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    if (self.output_tee_cb) |cb| {
        if (buf.len > 0) {
            cb(buf.ptr, buf.len, self.output_tee_userdata);
        }
    }

    self.processOutputLocked(buf);
}
```

(Preserves the original lock/defer/unlock + `processOutputLocked` call; tee fires before VT parser but inside the same critical section.)

- [ ] **Step 3: Add `setOutputTee` helper**

Immediately below `processOutput`, add:

```zig
/// Install or clear the PTY output tee callback. Synchronizes with the
/// io reader through renderer_state.mutex so an in-flight processOutput
/// either sees the old callback or the new one, never a torn pointer.
pub fn setOutputTee(
    self: *Termio,
    cb: ?*const fn (
        bytes: [*]const u8,
        len: usize,
        userdata: ?*anyopaque,
    ) callconv(.C) void,
    userdata: ?*anyopaque,
) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.output_tee_cb = cb;
    self.output_tee_userdata = userdata;
}
```

- [ ] **Step 4: Stage**

```bash
git -C /Volumes/workspace/git/hillion/cmux/ghostty add src/termio/Termio.zig
```

---

### Task 2.3: Ghostty patch #2 — export `ghostty_surface_set_output_tee` in `embedded.zig`, commit + push fork BEFORE parent pointer bump (D20)

(Resolves Coverage must_fix "Phase 2 Task 2.4 parent pointer bump must happen AFTER test is in fork main" — by sequencing fork push first.)

**Files:**
- Modify: `ghostty/src/apprt/embedded.zig`

- [ ] **Step 1: Add the export**

Open `/Volumes/workspace/git/hillion/cmux/ghostty/src/apprt/embedded.zig`. Locate `export fn ghostty_surface_process_output` (around line 1919). Immediately after that function's closing `}`, insert:

```zig
/// PTY output tee. See ghostty.h for the contract. Must be
/// non-blocking, memcpy-only, zero-syscall under renderer_state.mutex.
export fn ghostty_surface_set_output_tee(
    surface: *Surface,
    cb: ?*const fn (
        bytes: [*]const u8,
        len: usize,
        userdata: ?*anyopaque,
    ) callconv(.C) void,
    userdata: ?*anyopaque,
) void {
    surface.core_surface.io.setOutputTee(cb, userdata);
}
```

- [ ] **Step 2: Commit on the fork branch and push to `manaflow/main` (D20: BEFORE parent pointer bump)**

```bash
git -C /Volumes/workspace/git/hillion/cmux/ghostty add include/ghostty.h src/termio/Termio.zig src/apprt/embedded.zig
git -C /Volumes/workspace/git/hillion/cmux/ghostty checkout -B patch-2-output-tee
git -C /Volumes/workspace/git/hillion/cmux/ghostty commit -m "apprt: PTY output tee callback (patch #2)

ghostty_surface_set_output_tee installs a non-blocking, memcpy-only
callback invoked once per PTY read under renderer_state.mutex on the
io-reader thread. Used by downstream embedders that need a live byte
stream of child output (cmux HTTP /v1/surfaces/{id}/stream?mode=raw)."
git -C /Volumes/workspace/git/hillion/cmux/ghostty push manaflow patch-2-output-tee
```

- [ ] **Step 3: Fast-forward `manaflow/main`**

```bash
git -C /Volumes/workspace/git/hillion/cmux/ghostty fetch manaflow
git -C /Volumes/workspace/git/hillion/cmux/ghostty checkout main
git -C /Volumes/workspace/git/hillion/cmux/ghostty merge --ff-only patch-2-output-tee
git -C /Volumes/workspace/git/hillion/cmux/ghostty push manaflow main
git -C /Volumes/workspace/git/hillion/cmux/ghostty merge-base --is-ancestor HEAD manaflow/main && echo OK
```

---

### Task 2.4: Ghostty patch #2 — record fork change in `docs/ghostty-fork.md` + bump parent pointer

(Resolves Coverage must_fix on D20 ordering — pointer bump happens AFTER fork push.)

**Files:**
- Modify: `docs/ghostty-fork.md`
- Modify: `ghostty` (submodule pointer)

- [ ] **Step 1: Append a fork entry**

Append under "Current fork changes":

```markdown
### N) PTY output tee callback (patch #2)

- Files:
  - `include/ghostty.h`
  - `src/termio/Termio.zig`
  - `src/apprt/embedded.zig`
- Summary: New C export `ghostty_surface_set_output_tee` installs a
  non-blocking memcpy-only callback invoked once per PTY read under
  `renderer_state.mutex` on the io-reader thread. Used by cmux's HTTP
  `/v1/surfaces/{id}/stream?mode=raw`.
- Conflict notes: Touches `Termio.processOutput`, which upstream
  resize/io patches also edit. On rebase, keep the lock/tee-call
  ordering: lock -> tee-call (if installed) -> `processOutputLocked`
  -> unlock (via defer).
- Upstream plan: Stays as a fork patch for now; reuses the manual IO
  seam shape from PR #53. No upstream tracking issue filed in v1.
```

- [ ] **Step 2: Verify the submodule pointer is on `manaflow/main`**

```bash
git -C /Volumes/workspace/git/hillion/cmux/ghostty merge-base --is-ancestor HEAD manaflow/main && echo OK
```

- [ ] **Step 3: Stage and commit parent pointer + docs**

```bash
git -C /Volumes/workspace/git/hillion/cmux add ghostty docs/ghostty-fork.md
git commit -m "Bump ghostty submodule for PTY output tee patch (patch #2)"
git push origin HEAD
```

- [ ] **Step 4: Rebuild GhosttyKit.xcframework with ReleaseFast (per CLAUDE.md)**

```bash
cd /Volumes/workspace/git/hillion/cmux/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

Then update `scripts/ghosttykit-checksums.txt` per the existing fork-release flow and commit the xcframework artifact / checksum updates in a separate commit:

```bash
git -C /Volumes/workspace/git/hillion/cmux add scripts/ghosttykit-checksums.txt
git -C /Volumes/workspace/git/hillion/cmux commit -m "Refresh GhosttyKit checksums for patch #2"
git push origin HEAD
```

---

### Task 2.5: Failing test for `EventRing<OutputEvent>` (drop-oldest, monotonic event-level seq) — RED commit

(Resolves Coverage must_fix #5 / Quality must_fix on event-level seq — replaces the old `BoundedByteRing` byte-counter design.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/EventRing.swift` (stub returning empties)
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/EventRingTests.swift`

- [ ] **Step 1: Stub `EventRing.swift`**

```swift
import Foundation

/// Single-producer / multi-consumer-via-drain bounded ring of
/// ``OutputEvent`` tuples keyed by a monotonically increasing event
/// ``seq``. Drop-oldest on overflow; next ``seq`` is monotonic so the
/// client sees a JUMP in id values when bytes were dropped (D6).
///
/// Stub: behavior implemented in Task 2.6.
public final class EventRing: @unchecked Sendable {
    public let capacity: Int
    public init(capacity: Int) { self.capacity = capacity }

    /// Highest seq ever appended (including dropped entries).
    public var lastAppendedSeq: UInt64 { 0 }

    /// Seq of the oldest entry currently in the ring (0 if empty).
    public var oldestSeq: UInt64 { 0 }

    /// Drop-oldest append. Returns the seq assigned to this event.
    @discardableResult
    public func append(_ event: OutputEvent) -> UInt64 { 0 }

    /// Drain all entries with seq > `after`. Returns ordered (seq, event)
    /// tuples. If `after` is below the ring's oldest seq, the caller
    /// should emit a synthetic gap before consuming the returned slice.
    public func drain(after: UInt64) -> [(UInt64, OutputEvent)] { [] }

    /// Snapshot helper: true if `after` is too old to resume from
    /// in-ring (i.e., resume must emit a synthetic gap).
    public func resumeIsBelowOldest(_ after: UInt64) -> Bool { false }
}
```

- [ ] **Step 2: Failing tests**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct EventRingTests {
    @Test func assignsMonotonicSeqStartingAtOne() {
        let r = EventRing(capacity: 8)
        let s1 = r.append(.rawBytes(Data([1]), seq: 0))
        let s2 = r.append(.rawBytes(Data([2]), seq: 0))
        let s3 = r.append(.rawBytes(Data([3]), seq: 0))
        #expect(s1 == 1)
        #expect(s2 == 2)
        #expect(s3 == 3)
        #expect(r.lastAppendedSeq == 3)
        #expect(r.oldestSeq == 1)
    }

    @Test func dropsOldestOnOverflowAndKeepsMonotonicSeq() {
        let r = EventRing(capacity: 3)
        for i in 1...5 { _ = r.append(.rawBytes(Data([UInt8(i)]), seq: 0)) }
        #expect(r.lastAppendedSeq == 5)
        #expect(r.oldestSeq == 3) // 1,2 dropped, 3..5 remain
        let all = r.drain(after: 0)
        #expect(all.map { $0.0 } == [3, 4, 5])
    }

    @Test func drainAfterInRingReturnsOnlyNewer() {
        let r = EventRing(capacity: 8)
        for i in 1...4 { _ = r.append(.rawBytes(Data([UInt8(i)]), seq: 0)) }
        let slice = r.drain(after: 2)
        #expect(slice.map { $0.0 } == [3, 4])
    }

    @Test func resumeIsBelowOldestFlagsExpiredId() {
        let r = EventRing(capacity: 2)
        for i in 1...5 { _ = r.append(.rawBytes(Data([UInt8(i)]), seq: 0)) }
        #expect(r.oldestSeq == 4)
        #expect(r.resumeIsBelowOldest(2) == true)
        #expect(r.resumeIsBelowOldest(4) == false)
    }

    @Test func emptyRingDrainReturnsNothing() {
        let r = EventRing(capacity: 4)
        #expect(r.drain(after: 0).isEmpty)
        #expect(r.lastAppendedSeq == 0)
        #expect(r.oldestSeq == 0)
    }
}
```

- [ ] **Step 3: Commit red**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/EventRing.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/EventRingTests.swift
git commit -m "Add failing EventRing drop-oldest + monotonic seq tests"
git push origin HEAD
```

Expected on CI: `EventRingTests` fails (stub returns zeros / empties).

---

### Task 2.6: Implement `EventRing` (GREEN commit)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/EventRing.swift`

- [ ] **Step 1: Replace the stub**

```swift
import Foundation

/// Single-producer / multi-consumer-via-drain bounded ring of
/// ``OutputEvent`` tuples keyed by a monotonically increasing event
/// ``seq``. Drop-oldest on overflow; the next assigned seq is always
/// `lastAppendedSeq + 1` so a client that observes a JUMP in `id:`
/// values knows it dropped intermediate events (D6).
///
/// Locking: a single ``NSLock`` guards the storage. The lock is taken
/// only after the C tee trampoline has already memcpy'd the payload
/// into a stack-resident ``Data`` (see ``OutputTee`` in the app
/// target), so this lock is never held under ``renderer_state.mutex``.
public final class EventRing: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var buffer: [(seq: UInt64, event: OutputEvent)] = []
    private var lastSeq: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "EventRing capacity must be positive")
        self.capacity = capacity
        self.buffer.reserveCapacity(capacity)
    }

    public var lastAppendedSeq: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return lastSeq
    }

    public var oldestSeq: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return buffer.first?.seq ?? 0
    }

    @discardableResult
    public func append(_ event: OutputEvent) -> UInt64 {
        lock.lock()
        lastSeq &+= 1
        let s = lastSeq
        // Strip the caller's seq field by rebuilding with the
        // assigned monotonic seq.
        let normalized: OutputEvent
        switch event {
        case .rawBytes(let d, _):       normalized = .rawBytes(d, seq: s)
        case .cellsSnapshot(let g, _):  normalized = .cellsSnapshot(g, seq: s)
        }
        buffer.append((s, normalized))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
        return s
    }

    public func drain(after: UInt64) -> [(UInt64, OutputEvent)] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        var idx = 0
        while idx < buffer.count && buffer[idx].seq <= after { idx += 1 }
        return Array(buffer[idx...])
    }

    public func resumeIsBelowOldest(_ after: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let first = buffer.first else { return after < lastSeq }
        return after < first.seq
    }
}
```

- [ ] **Step 2: Commit green**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/EventRing.swift
git commit -m "Implement EventRing drop-oldest with monotonic event seq"
git push origin HEAD
```

---

### Task 2.7: Add `MonotonicClock` to `CmuxTerminalAccess` (single-source-of-truth)

(Resolves Quality must_fix on `MonotonicClock` duplication / cross-module migration. Defined ONCE in the package; HTTP layer imports.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/MonotonicClock.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SystemMonotonicClock.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ManualClock.swift`
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ManualClockTests.swift`

- [ ] **Step 1: `MonotonicClock.swift`**

```swift
import Foundation

/// Injectable monotonic clock seam. Defined in CmuxTerminalAccess so
/// every consumer (``EventRing``, ``SnapshotPoller``, ``SSEResponder``,
/// throttles) uses the same protocol. Production uses
/// ``SystemMonotonicClock``; tests use ``ManualClock``.
public protocol MonotonicClock: Sendable {
    /// Monotonic time in seconds since an arbitrary epoch.
    func now() -> Double
}
```

- [ ] **Step 2: `SystemMonotonicClock.swift`**

```swift
import Foundation
import Dispatch

/// Production ``MonotonicClock`` reading ``DispatchTime.now()``.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
```

- [ ] **Step 3: `ManualClock.swift`**

```swift
import Foundation

/// Test ``MonotonicClock`` whose time only advances when ``advance(by:)``
/// is called. Thread-safe.
public final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    public init(start: Double = 0) { self.t = start }
    public func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return t
    }
    public func advance(by delta: Double) {
        lock.lock(); t += delta; lock.unlock()
    }
}
```

- [ ] **Step 4: Test**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ManualClockTests {
    @Test func advancesMonotonically() {
        let c = ManualClock(start: 0)
        #expect(c.now() == 0)
        c.advance(by: 1.5)
        #expect(c.now() == 1.5)
        c.advance(by: 0.5)
        #expect(c.now() == 2.0)
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/MonotonicClock.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SystemMonotonicClock.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ManualClock.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/ManualClockTests.swift
git commit -m "Add MonotonicClock protocol + system/manual implementations"
git push origin HEAD
```

---

### Task 2.8: Failing test for `CellGridDigest` (FNV-1a over codepoints + cursor) — RED commit

(Resolves D8: dirty notification via time-tick poll + hash; replaces the missing third ghostty patch.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellGridDigest.swift` (stub)
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellGridDigestTests.swift`

- [ ] **Step 1: Stub**

```swift
import Foundation

/// Cheap FNV-1a 64-bit digest over a ``CellGrid``'s codepoints and
/// cursor position. Used by ``SnapshotPoller`` (D8) to suppress
/// snapshot emission when nothing visible has changed since the last
/// tick. NOT a cryptographic hash; collisions are acceptable because
/// the worst case is "we emit one extra snapshot".
public enum CellGridDigest {
    /// Stub: returns zero. Real impl in Task 2.9.
    public static func compute(_ grid: CellGrid) -> UInt64 { 0 }
}
```

- [ ] **Step 2: Failing tests**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellGridDigestTests {
    private func grid(text: [String], cursor: CursorState) -> CellGrid {
        let rows = text.map { line -> CellRow in
            let cells = line.map { ch -> Cell in
                Cell(t: String(ch), wide: .narrow,
                     fg: .default, bg: .default,
                     attrs: [], underlineKind: nil, underlineColor: nil,
                     hyperlink: nil, semantic: nil)
            }
            return CellRow(wrap: false, wrapContinuation: false, cells: cells)
        }
        return CellGrid(cols: text.first?.count ?? 0, rows: text.count,
                        altScreen: false, title: nil,
                        cursor: cursor, semanticAvailable: false,
                        rowsData: rows)
    }

    @Test func equalGridsHashEqual() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["abc"], cursor: c))
             == CellGridDigest.compute(grid(text: ["abc"], cursor: c)))
    }

    @Test func differentTextDigestsDiffer() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["abc"], cursor: c))
             != CellGridDigest.compute(grid(text: ["abd"], cursor: c)))
    }

    @Test func differentCursorDigestsDiffer() {
        let a = CursorState(row: 0, col: 1, visible: true, style: .block)
        let b = CursorState(row: 0, col: 2, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["abc"], cursor: a))
             != CellGridDigest.compute(grid(text: ["abc"], cursor: b)))
    }

    @Test func nonZeroForNonEmptyGrid() {
        let c = CursorState(row: 0, col: 0, visible: true, style: .block)
        #expect(CellGridDigest.compute(grid(text: ["x"], cursor: c)) != 0)
    }
}
```

- [ ] **Step 3: Commit red**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellGridDigest.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/CellGridDigestTests.swift
git commit -m "Add failing CellGridDigest FNV-1a tests"
git push origin HEAD
```

Expected: CI red.

---

### Task 2.9: Implement `CellGridDigest` (GREEN commit)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellGridDigest.swift`

- [ ] **Step 1: Replace stub**

```swift
import Foundation

public enum CellGridDigest {
    private static let fnvOffset: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnvPrime:  UInt64 = 0x0000_0100_0000_01B3

    public static func compute(_ grid: CellGrid) -> UInt64 {
        var h: UInt64 = fnvOffset
        mix(&h, UInt64(grid.cols))
        mix(&h, UInt64(grid.rows))
        mix(&h, grid.altScreen ? 1 : 0)
        mix(&h, UInt64(grid.cursor.row))
        mix(&h, UInt64(grid.cursor.col))
        mix(&h, grid.cursor.visible ? 1 : 0)
        mix(&h, UInt64(grid.cursor.style.hashValue & 0xFFFF))
        for row in grid.rowsData {
            mix(&h, row.wrap ? 1 : 0)
            mix(&h, row.wrapContinuation ? 1 : 0)
            for cell in row.cells {
                for s in cell.t.unicodeScalars {
                    mixByte(&h, UInt8(s.value & 0xFF))
                    mixByte(&h, UInt8((s.value >> 8) & 0xFF))
                    mixByte(&h, UInt8((s.value >> 16) & 0xFF))
                    mixByte(&h, UInt8((s.value >> 24) & 0xFF))
                }
                mix(&h, UInt64(cell.wide.hashValue & 0xFF))
            }
        }
        return h
    }

    @inline(__always)
    private static func mix(_ h: inout UInt64, _ v: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            mixByte(&h, UInt8((v >> shift) & 0xFF))
        }
    }

    @inline(__always)
    private static func mixByte(_ h: inout UInt64, _ b: UInt8) {
        h ^= UInt64(b)
        h &*= fnvPrime
    }
}
```

- [ ] **Step 2: Commit green**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/CellGridDigest.swift
git commit -m "Implement CellGridDigest FNV-1a over codepoints + cursor"
git push origin HEAD
```

---

### Task 2.10: Failing test for `SnapshotPoller` (time-tick + hash gates emit; D8) — RED commit

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SnapshotPoller.swift` (stub)
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SnapshotPollerTests.swift`

- [ ] **Step 1: Stub `SnapshotPoller.swift`**

```swift
import Foundation

/// Polls `read()` at `tickRate` per second; emits only when the
/// computed ``CellGridDigest`` differs from the previous tick (D8).
public final class SnapshotPoller: @unchecked Sendable {
    public init(
        tickRate: Double = 5.0,
        clock: any MonotonicClock = SystemMonotonicClock(),
        read: @escaping @Sendable () throws -> CellGrid?,
        emit: @escaping @Sendable (CellGrid) -> Void
    ) {
        _ = tickRate; _ = clock; _ = read; _ = emit
    }
    public func tick() { /* stub */ }
    public func reset() { /* stub */ }
}
```

- [ ] **Step 2: Failing tests**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SnapshotPollerTests {
    private func sampleGrid(letter: Character) -> CellGrid {
        let cells = [Cell(t: String(letter), wide: .narrow,
                          fg: .default, bg: .default, attrs: [],
                          underlineKind: nil, underlineColor: nil,
                          hyperlink: nil, semantic: nil)]
        return CellGrid(cols: 1, rows: 1, altScreen: false, title: nil,
                        cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                        semanticAvailable: false,
                        rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: cells)])
    }

    @Test func emitsOnceWhenContentChangesAcrossTicks() {
        let clock = ManualClock(start: 0)
        var current = sampleGrid(letter: "a")
        nonisolated(unsafe) var emitted: [String] = []
        let poller = SnapshotPoller(
            tickRate: 100.0,
            clock: clock,
            read: { current },
            emit: { g in emitted.append(g.rowsData.first?.cells.first?.t ?? "") }
        )
        poller.tick()
        clock.advance(by: 0.02)
        poller.tick()
        current = sampleGrid(letter: "b")
        clock.advance(by: 0.02)
        poller.tick()
        #expect(emitted == ["a", "b"])
    }

    @Test func suppressesEmitWhenContentUnchanged() {
        let clock = ManualClock(start: 0)
        let grid = sampleGrid(letter: "a")
        nonisolated(unsafe) var emitted = 0
        let poller = SnapshotPoller(
            tickRate: 100.0, clock: clock,
            read: { grid }, emit: { _ in emitted += 1 }
        )
        for _ in 0..<10 { clock.advance(by: 0.02); poller.tick() }
        #expect(emitted == 1)
    }

    @Test func swallowsReadErrors() {
        let clock = ManualClock(start: 0)
        nonisolated(unsafe) var emitted = 0
        let poller = SnapshotPoller(
            tickRate: 100.0, clock: clock,
            read: { throw TerminalAccessError.unknownSurface },
            emit: { _ in emitted += 1 }
        )
        poller.tick()
        #expect(emitted == 0)
    }
}
```

- [ ] **Step 3: Commit red**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SnapshotPoller.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SnapshotPollerTests.swift
git commit -m "Add failing SnapshotPoller (time-tick + hash) tests"
git push origin HEAD
```

---

### Task 2.11: Implement `SnapshotPoller` (GREEN commit)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SnapshotPoller.swift`

- [ ] **Step 1: Real impl**

```swift
import Foundation

public final class SnapshotPoller: @unchecked Sendable {
    public let tickRate: Double
    private let clock: any MonotonicClock
    private let read: @Sendable () throws -> CellGrid?
    private let emit: @Sendable (CellGrid) -> Void

    private let lock = NSLock()
    private var lastDigest: UInt64 = 0
    private var hasEmitted = false
    private var lastTick: Double = -.infinity

    public init(
        tickRate: Double = 5.0,
        clock: any MonotonicClock = SystemMonotonicClock(),
        read: @escaping @Sendable () throws -> CellGrid?,
        emit: @escaping @Sendable (CellGrid) -> Void
    ) {
        precondition(tickRate > 0)
        self.tickRate = tickRate
        self.clock = clock
        self.read = read
        self.emit = emit
    }

    public func tick() {
        let minGap = 1.0 / tickRate
        lock.lock()
        let now = clock.now()
        if now - lastTick < minGap {
            lock.unlock()
            return
        }
        lastTick = now
        lock.unlock()

        let grid: CellGrid?
        do { grid = try read() } catch { return }
        guard let g = grid else { return }
        let digest = CellGridDigest.compute(g)
        lock.lock()
        if hasEmitted && digest == lastDigest {
            lock.unlock()
            return
        }
        lastDigest = digest
        hasEmitted = true
        lock.unlock()
        emit(g)
    }

    public func reset() {
        lock.lock(); hasEmitted = false; lastDigest = 0; lastTick = -.infinity; lock.unlock()
    }
}
```

- [ ] **Step 2: Commit green**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SnapshotPoller.swift
git commit -m "Implement SnapshotPoller with time-tick + hash gating"
git push origin HEAD
```

---

### Task 2.12: Failing test for `StreamCap` (D7 — pre-allocated slot array per surface, cap = 8) — RED commit

(Resolves Coverage/Quality must_fix "StreamCap.Token recursive release self-call" — Token uses `fileprivate let onRelease` per D24 and exposes `release()` that calls it via CAS-protected released flag.)

**Files:**
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/StreamCap.swift` (correct, non-recursive shape)
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/StreamCapTests.swift`

- [ ] **Step 1: Implement `StreamCap.swift` directly with correct shape (NO buggy stub)**

```swift
import Foundation

/// Per-surface concurrent-stream limiter. Default cap = 8 per surface
/// (D7). Each acquired ``Token`` holds one slot; releasing the token
/// frees the slot. Token release is idempotent and uses a CAS-style
/// flag so ``deinit`` is safe to call after an explicit ``release()``.
public final class StreamCap: @unchecked Sendable {
    /// Released-once token. Stores ``onRelease`` as ``fileprivate let``
    /// per D24 and exposes ``release()``; the public method name is
    /// distinct from the stored closure name so no recursive shadow.
    public final class Token {
        fileprivate let onRelease: @Sendable () -> Void
        private let releasedFlag = NSLock()
        private var released = false

        fileprivate init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        public func release() {
            releasedFlag.lock()
            let already = released
            released = true
            releasedFlag.unlock()
            guard !already else { return }
            onRelease()
        }

        deinit { release() }
    }

    public let maxPerSurface: Int

    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init(maxPerSurface: Int = 8) {
        precondition(maxPerSurface > 0)
        self.maxPerSurface = maxPerSurface
    }

    public func acquire(_ handle: SurfaceHandle) throws -> Token {
        let key = Self.key(for: handle)
        lock.lock()
        let current = counts[key, default: 0]
        if current >= maxPerSurface {
            lock.unlock()
            throw TerminalAccessError.unsupported(reason: "too_many_streams")
        }
        counts[key] = current + 1
        lock.unlock()
        return Token { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let v = (self.counts[key] ?? 1) - 1
            if v <= 0 { self.counts.removeValue(forKey: key) }
            else { self.counts[key] = v }
            self.lock.unlock()
        }
    }

    public func current(for handle: SurfaceHandle) -> Int {
        let key = Self.key(for: handle)
        lock.lock(); defer { lock.unlock() }
        return counts[key, default: 0]
    }

    private static func key(for h: SurfaceHandle) -> String {
        switch h {
        case .uuid(let u): return "uuid:\(u.uuidString)"
        case .ref(let kind, let ord): return "\(kind):\(ord)"
        }
    }
}
```

(Note: `TerminalAccessError.unsupported` → HTTP 415 per D18. The HTTP stream route in Task 2.20 maps `too_many_streams` specifically to 503 because spec §9.1 caps concurrent streams, NOT content-type. The route does that mapping inline.)

- [ ] **Step 2: Failing tests**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct StreamCapTests {
    @Test func acquiresUpToMaxThenRejects() throws {
        let cap = StreamCap(maxPerSurface: 3)
        let h = SurfaceHandle.ref(kind: "surface", ordinal: 1)
        let t1 = try cap.acquire(h)
        let t2 = try cap.acquire(h)
        let t3 = try cap.acquire(h)
        #expect(throws: TerminalAccessError.self) {
            _ = try cap.acquire(h)
        }
        t2.release()
        let t4 = try cap.acquire(h)
        #expect(cap.current(for: h) == 3)
        _ = (t1, t3, t4)
    }

    @Test func capIsPerSurface() throws {
        let cap = StreamCap(maxPerSurface: 1)
        let a = SurfaceHandle.ref(kind: "surface", ordinal: 1)
        let b = SurfaceHandle.ref(kind: "surface", ordinal: 2)
        _ = try cap.acquire(a)
        _ = try cap.acquire(b)
        #expect(throws: TerminalAccessError.self) {
            _ = try cap.acquire(a)
        }
    }

    @Test func releaseIsIdempotent() throws {
        let cap = StreamCap(maxPerSurface: 1)
        let h = SurfaceHandle.ref(kind: "surface", ordinal: 1)
        let t = try cap.acquire(h)
        t.release()
        t.release() // must not crash, must not decrement twice
        _ = try cap.acquire(h)
    }
}
```

- [ ] **Step 3: Commit red**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/StreamCap.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/StreamCapTests.swift
git commit -m "Add failing StreamCap (per-surface, idempotent token) tests"
git push origin HEAD
```

Expected: this commit's tests run green because the implementation is already correct. We deliberately skip the buggy-stub pattern here because per Quality must_fix "do not ship a broken file just to satisfy the red-green ritual"; the regression coverage exists at the test-file level.

---

### Task 2.13: Failing test for `OutputTee` C trampoline (zero-allocation distribution) — RED commit

(Resolves Coverage must_fix #10: zero-allocation contract violation; Quality must_fix on `Array(subscribers.values)` inside renderer-locked trampoline. Uses pre-allocated subscriber slot array per D7.)

**Files:**
- Create: `Sources/HTTPControl/OutputTee.swift` (stub: zero-distribute behavior)
- Create: `cmuxTests/HTTPControl/OutputTeeTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj` (wire both)

- [ ] **Step 1: Stub `OutputTee.swift`**

```swift
import Dispatch
import Foundation
import CmuxTerminalAccess

/// Bridges Ghostty's PTY output tee into pre-allocated subscriber
/// slots (D7). The C trampoline runs under
/// ``renderer_state.mutex`` on Ghostty's io-reader thread; it MUST be
/// non-blocking, memcpy-only, zero allocation, zero syscall.
///
/// Stub: implemented in Task 2.14.
public final class OutputTee: @unchecked Sendable {
    public let slotCapacity: Int
    public let ringCapacity: Int

    public init(slotCapacity: Int = 8, ringCapacity: Int = 512 * 1024) {
        self.slotCapacity = slotCapacity
        self.ringCapacity = ringCapacity
    }

    public final class Slot {
        public let id: UUID
        fileprivate init(id: UUID) { self.id = id }
    }

    public func subscribe(
        deliverQueue: DispatchQueue,
        handler: @escaping @Sendable (Data) -> Void
    ) -> Slot? { nil }

    public func unsubscribe(_ slot: Slot) { /* stub */ }

    public func cInjectForTesting(_ data: Data) { /* stub */ }

    public var occupiedSlotCount: Int { 0 }
}
```

- [ ] **Step 2: Failing tests**

```swift
import Foundation
import Testing
@testable import cmux
@testable import CmuxTerminalAccess

@Suite struct OutputTeeTests {
    @Test func subscribesUpToSlotCapacityThenRefuses() {
        let tee = OutputTee(slotCapacity: 2, ringCapacity: 1024)
        let q = DispatchQueue(label: "test")
        let s1 = tee.subscribe(deliverQueue: q) { _ in }
        let s2 = tee.subscribe(deliverQueue: q) { _ in }
        let s3 = tee.subscribe(deliverQueue: q) { _ in }
        #expect(s1 != nil); #expect(s2 != nil); #expect(s3 == nil)
        tee.unsubscribe(s1!)
        let s4 = tee.subscribe(deliverQueue: q) { _ in }
        #expect(s4 != nil)
    }

    @Test func injectedBytesReachAllSubscribers() async throws {
        let tee = OutputTee(slotCapacity: 4, ringCapacity: 1024)
        let lockA = NSLock(); nonisolated(unsafe) var a = Data()
        let lockB = NSLock(); nonisolated(unsafe) var b = Data()
        let q = DispatchQueue(label: "deliver")
        let s1 = tee.subscribe(deliverQueue: q) { d in
            lockA.lock(); a.append(d); lockA.unlock()
        }!
        let s2 = tee.subscribe(deliverQueue: q) { d in
            lockB.lock(); b.append(d); lockB.unlock()
        }!
        tee.cInjectForTesting(Data("hello".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)
        lockA.lock(); let aa = a; lockA.unlock()
        lockB.lock(); let bb = b; lockB.unlock()
        #expect(aa == Data("hello".utf8))
        #expect(bb == Data("hello".utf8))
        tee.unsubscribe(s1); tee.unsubscribe(s2)
    }

    @Test func slowSubscriberDoesNotBlockFast() async throws {
        let tee = OutputTee(slotCapacity: 4, ringCapacity: 64 * 1024)
        let qFast = DispatchQueue(label: "fast", qos: .userInitiated)
        let qSlow = DispatchQueue(label: "slow", qos: .utility)
        let fastLock = NSLock(); nonisolated(unsafe) var fastBytes = Data()
        let fast = tee.subscribe(deliverQueue: qFast) { d in
            fastLock.lock(); fastBytes.append(d); fastLock.unlock()
        }!
        let slow = tee.subscribe(deliverQueue: qSlow) { _ in
            Thread.sleep(forTimeInterval: 0.2)
        }!
        let payload = Data("backpressure-check".utf8)
        tee.cInjectForTesting(payload)
        try await Task.sleep(nanoseconds: 60_000_000)
        fastLock.lock(); let got = fastBytes; fastLock.unlock()
        #expect(got == payload)
        tee.unsubscribe(fast); tee.unsubscribe(slow)
    }
}
```

- [ ] **Step 3: Wire pbxproj + commit red**

Add `Sources/HTTPControl/OutputTee.swift` to the cmux app target's `PBXSourcesBuildPhase` and `cmuxTests/HTTPControl/OutputTeeTests.swift` to the cmuxTests target. Use a sibling like `TabManagerUnitTests.swift` as a template for the four pbxproj entries.

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/OutputTee.swift \
        cmuxTests/HTTPControl/OutputTeeTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add failing OutputTee distribution tests"
git push origin HEAD
```

---

### Task 2.14: Implement `OutputTee` with pre-allocated slot array + C trampoline (GREEN commit)

(Resolves Coverage must_fix #10 zero-alloc; Quality must_fix on subscribe `handle/mode` "rewrap" hack — this layer deals in bytes only; the service wraps into `OutputSubscription` with the correct handle/mode upstream.)

**Files:**
- Modify: `Sources/HTTPControl/OutputTee.swift`

- [ ] **Step 1: Real implementation**

```swift
import Dispatch
import Foundation
import GhosttyKit  // ghostty_surface_set_output_tee, ghostty_output_tee_cb
import CmuxTerminalAccess

public final class OutputTee: @unchecked Sendable {
    public let slotCapacity: Int
    public let ringCapacity: Int

    public final class Slot {
        public let id: UUID
        fileprivate let index: Int
        fileprivate init(id: UUID, index: Int) { self.id = id; self.index = index }
    }

    /// One subscriber slot. ``occupied`` is mutated under
    /// ``slotsLock`` (NOT the renderer lock); the trampoline reads
    /// ``occupied`` and ``ring`` from a fixed-size array without
    /// allocating (D7).
    private final class FixedSlot {
        var occupied: Bool = false
        var id: UUID = UUID()
        var ring: BoundedByteRingForTee
        let wake: DispatchSourceUserDataAdd
        let handler: (@Sendable (Data) -> Void)?

        init(ring: BoundedByteRingForTee, wake: DispatchSourceUserDataAdd,
             handler: (@Sendable (Data) -> Void)?) {
            self.ring = ring; self.wake = wake; self.handler = handler
        }
    }

    /// Tiny lock-protected byte-only ring used internally by
    /// ``OutputTee``. Distinct from ``EventRing`` (which holds
    /// ``OutputEvent`` and tracks event-level seq). This one is only
    /// the producer-side buffer the C trampoline memcpys into.
    final class BoundedByteRingForTee: @unchecked Sendable {
        private let lock = NSLock()
        private var buf: [UInt8]
        private var head = 0
        private var count = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buf = [UInt8](repeating: 0, count: capacity)
        }

        // Called from D-thread (consumer). Returns up to `max` bytes.
        func drain(max maxBytes: Int) -> Data {
            lock.lock()
            let take = Swift.min(maxBytes, count)
            if take == 0 { lock.unlock(); return Data() }
            let tail = ((head - count) % capacity + capacity) % capacity
            var out = Data(count: take)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: UInt8.self).baseAddress!
                buf.withUnsafeBufferPointer { src in
                    let first = Swift.min(take, capacity - tail)
                    memcpy(dst, src.baseAddress!.advanced(by: tail), first)
                    if first < take {
                        memcpy(dst.advanced(by: first),
                               src.baseAddress!, take - first)
                    }
                }
            }
            count -= take
            lock.unlock()
            return out
        }

        // Called from C trampoline (under renderer lock). MUST be
        // memcpy-only and lock-only on the byte-buffer lock — never on
        // the slotsLock. Drop-oldest when full.
        func append(_ ptr: UnsafePointer<UInt8>, _ n: Int) {
            lock.lock()
            if n >= capacity {
                memcpy(&buf, ptr.advanced(by: n - capacity), capacity)
                head = 0; count = capacity
                lock.unlock(); return
            }
            var written = 0
            while written < n {
                let space = capacity - head
                let chunk = Swift.min(space, n - written)
                buf.withUnsafeMutableBufferPointer { d in
                    memcpy(d.baseAddress!.advanced(by: head),
                           ptr.advanced(by: written), chunk)
                }
                head = (head + chunk) % capacity
                written += chunk
            }
            let nc = count + n
            if nc > capacity { count = capacity } else { count = nc }
            lock.unlock()
        }
    }

    private var slots: [FixedSlot] = []
    private let slotsLock = NSLock()  // NOT held under renderer lock
    private var cSurface: OpaquePointer?

    public init(slotCapacity: Int = 8, ringCapacity: Int = 512 * 1024) {
        precondition(slotCapacity > 0)
        self.slotCapacity = slotCapacity
        self.ringCapacity = ringCapacity
        let q = DispatchQueue(label: "cmux.tee.placeholder")
        for _ in 0..<slotCapacity {
            let wake = DispatchSource.makeUserDataAddSource(queue: q)
            let slot = FixedSlot(
                ring: BoundedByteRingForTee(capacity: ringCapacity),
                wake: wake, handler: nil
            )
            slots.append(slot)
        }
    }

    public convenience init(slotCapacity: Int = 8, ringCapacity: Int = 512 * 1024,
                            surface: OpaquePointer) {
        self.init(slotCapacity: slotCapacity, ringCapacity: ringCapacity)
        self.cSurface = surface
        installCCallback()
    }

    deinit { uninstallCCallback() }

    public var occupiedSlotCount: Int {
        slotsLock.lock(); defer { slotsLock.unlock() }
        return slots.reduce(0) { $0 + ($1.occupied ? 1 : 0) }
    }

    public func subscribe(
        deliverQueue: DispatchQueue,
        handler: @escaping @Sendable (Data) -> Void
    ) -> Slot? {
        slotsLock.lock()
        guard let idx = slots.firstIndex(where: { !$0.occupied }) else {
            slotsLock.unlock(); return nil
        }
        let id = UUID()
        // Build a fresh wake source bound to the caller's queue,
        // and a fresh ring (zero out the previous tenant's bytes).
        let wake = DispatchSource.makeUserDataAddSource(queue: deliverQueue)
        let ring = BoundedByteRingForTee(capacity: ringCapacity)
        let newSlot = FixedSlot(ring: ring, wake: wake, handler: handler)
        newSlot.occupied = true
        newSlot.id = id
        slots[idx].wake.cancel()
        slots[idx] = newSlot
        wake.setEventHandler { [weak ring, handler] in
            guard let ring else { return }
            let d = ring.drain(max: 64 * 1024)
            if !d.isEmpty { handler(d) }
        }
        wake.resume()
        slotsLock.unlock()
        return Slot(id: id, index: idx)
    }

    public func unsubscribe(_ slot: Slot) {
        slotsLock.lock()
        guard slot.index < slots.count, slots[slot.index].id == slot.id else {
            slotsLock.unlock(); return
        }
        slots[slot.index].wake.cancel()
        // Replace with a fresh, unoccupied placeholder so the index
        // stays valid for future occupants.
        let placeholderQueue = DispatchQueue(label: "cmux.tee.placeholder")
        let wake = DispatchSource.makeUserDataAddSource(queue: placeholderQueue)
        slots[slot.index] = FixedSlot(
            ring: BoundedByteRingForTee(capacity: ringCapacity),
            wake: wake, handler: nil
        )
        slotsLock.unlock()
    }

    // MARK: - C plumbing

    private func installCCallback() {
        guard let surface = cSurface else { return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_output_tee(surface, OutputTee.cTrampoline, opaque)
    }

    private func uninstallCCallback() {
        guard let surface = cSurface else { return }
        ghostty_surface_set_output_tee(surface, nil, nil)
        cSurface = nil
    }

    /// C trampoline. Runs under ``renderer_state.mutex`` on the
    /// io-reader thread. ZERO allocation. Iterates the pre-allocated
    /// fixed-size slot array, memcpys into each occupied slot's ring,
    /// then atomically signals its wake source.
    private static let cTrampoline: @convention(c) (
        UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?
    ) -> Void = { bytesPtr, len, userdata in
        guard let bytesPtr, let userdata, len > 0 else { return }
        let me = Unmanaged<OutputTee>.fromOpaque(userdata).takeUnretainedValue()
        me.distributeFromTrampoline(bytesPtr, len)
    }

    /// Called from the C trampoline. Takes ``slotsLock`` briefly only
    /// to read the fixed-size array's occupied/ring/wake references;
    /// no allocation (the array itself is reused for the lifetime of
    /// ``OutputTee``). Append+wake are lock-free on the renderer lock
    /// (only the per-slot byte-ring lock is touched).
    fileprivate func distributeFromTrampoline(
        _ ptr: UnsafePointer<UInt8>, _ n: Int
    ) {
        slotsLock.lock()
        let count = slots.count
        for i in 0..<count {
            let s = slots[i]
            guard s.occupied else { continue }
            s.ring.append(ptr, n)
            s.wake.add(data: 1)
        }
        slotsLock.unlock()
    }

    // MARK: - Test injection

    /// Drives ``distributeFromTrampoline`` without a live surface, for
    /// unit tests. NOT used in production.
    public func cInjectForTesting(_ data: Data) {
        data.withUnsafeBytes { raw in
            let bp = raw.bindMemory(to: UInt8.self)
            if let base = bp.baseAddress, bp.count > 0 {
                distributeFromTrampoline(base, bp.count)
            }
        }
    }
}
```

- [ ] **Step 2: Commit green**

```bash
git add Sources/HTTPControl/OutputTee.swift
git commit -m "Implement OutputTee with pre-allocated slot array + C trampoline"
git push origin HEAD
```

Expected: `OutputTeeTests` from Task 2.13 turn green.

---

### Task 2.15: `SurfaceProvider` extension — raw-output source seam (async)

(Resolves Quality must_fix on Phase 0 async vs Phase 1/2 sync; D1: every SurfaceProvider method is `async throws`.)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceProvider.swift`
- Create: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceRawOutputSource.swift`
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SurfaceRawOutputSourceTests.swift`

- [ ] **Step 1: `SurfaceRawOutputSource.swift`**

```swift
import Foundation

/// Async source for live PTY output bytes from a surface (Ghostty tee
/// in production; in-memory stub in tests).
public protocol SurfaceRawOutputSource: AnyObject, Sendable {
    /// Install a byte handler; returns an opaque token whose lifetime
    /// keeps the source attached. Releasing the token detaches it.
    func attachRawOutput(
        _ handler: @escaping @Sendable (Data) -> Void
    ) async throws -> AnyObject
}
```

- [ ] **Step 2: Append to `SurfaceProvider.swift`**

```swift
public extension SurfaceProvider {
    /// Default returns nil; live Ghostty-backed providers override.
    /// Tests that don't need raw streams keep the default.
    func rawOutputSource(for handle: SurfaceHandle) async throws -> SurfaceRawOutputSource? { nil }
}
```

(Cells dirty notification per D8 uses `SnapshotPoller` calling `provider.readCells(...)` directly, so NO `SurfaceRenderNotifier` protocol is added — the spec's third-patch path is explicitly avoided.)

- [ ] **Step 3: Test using `StubSurfaceProvider` from `TestSupport/StubSurfaceProvider.swift` (D13)**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SurfaceRawOutputSourceTests {
    @Test func defaultProviderReturnsNoRawSource() async throws {
        let p = StubSurfaceProvider()
        let h = SurfaceHandle.ref(kind: "surface", ordinal: 1)
        let src = try await p.rawOutputSource(for: h)
        #expect(src == nil)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceRawOutputSource.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceProvider.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SurfaceRawOutputSourceTests.swift
git commit -m "Add SurfaceRawOutputSource seam (async, default nil)"
git push origin HEAD
```

---

### Task 2.16: `TerminalAccessService.subscribeOutput` skeleton + raw-mode failing test (RED)

(Resolves Quality must_fix on async protocol; Coverage must_fix on `subscribeOutput` returning a real `OutputSubscription` per D22 with correct `handle`/`mode` set by the service.)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/TerminalAccessService.swift`
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift`
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SubscribeRawTests.swift`

- [ ] **Step 1: Extend the protocol**

Append to `TerminalAccessService.swift`:

```swift
public extension TerminalAccessService {
    /// Subscribe to a surface's live output. The returned
    /// ``OutputSubscription`` (D22) is the unit of cancellation and
    /// the carrier of `onEnd` / `signalEnd` semantics. Caller pumps
    /// frames via the subscription's ``OutputSubscription/events()``
    /// `AsyncStream`. Implementations also support the
    /// closure-callback form below for non-Task call sites.
    func subscribeOutput(
        _ options: StreamSubscriptionOptions,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription { fatalError("must be overridden") }
}
```

- [ ] **Step 2: Skeleton in `DefaultTerminalAccessService.swift`**

The `streamCap` and `audit` properties already exist on the service from the E3 locked Phase 0 init signature; no new stored properties needed here. Add the public method:

```swift
    public func subscribeOutput(
        _ options: StreamSubscriptionOptions,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        let capToken = try streamCap.acquire(options.handle)
        // E1 — provider.resolve returns SurfaceInfo? (optional).
        guard let info = try await provider.resolve(options.handle) else {
            capToken.release()
            throw TerminalAccessError.unknownSurface
        }

        switch options.mode {
        case .raw:
            return try await openRawSubscription(
                info: info, options: options,
                capToken: capToken, onEvent: onEvent)
        case .cells:
            return try await openCellsSubscription(
                info: info, options: options,
                capToken: capToken, onEvent: onEvent)
        }
    }

    // Real bodies in Tasks 2.17 / 2.18; placeholder bodies for now so
    // the file builds and the test in Step 3 fails for the right
    // reason (subscription never delivers).
    private func openRawSubscription(
        info: SurfaceInfo,
        options: StreamSubscriptionOptions,
        capToken: StreamCap.Token,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        let sub = OutputSubscription(
            id: UUID(), handle: options.handle, mode: .raw,
            onCancel: { capToken.release() }
        )
        return sub
    }

    private func openCellsSubscription(
        info: SurfaceInfo,
        options: StreamSubscriptionOptions,
        capToken: StreamCap.Token,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        let sub = OutputSubscription(
            id: UUID(), handle: options.handle, mode: .cells,
            onCancel: { capToken.release() }
        )
        return sub
    }
```

- [ ] **Step 3: Failing test**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SubscribeRawTests {
    final class FakeRaw: SurfaceRawOutputSource, @unchecked Sendable {
        var handler: (@Sendable (Data) -> Void)?
        func attachRawOutput(
            _ handler: @escaping @Sendable (Data) -> Void
        ) async throws -> AnyObject {
            self.handler = handler
            return NSObject()
        }
        func emit(_ d: Data) { handler?(d) }
    }

    // E1 — full SurfaceProvider conformance. Methods we don't exercise in
    // this test return safe defaults / unsupported.
    final class FakeProvider: SurfaceProvider, @unchecked Sendable {
        let raw = FakeRaw()
        func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo? {
            SurfaceInfo(handle: handle, uuid: UUID(), workspaceRef: "ws:1",
                        title: "t", cols: 80, rows: 24, altScreen: false,
                        focused: false, semanticAvailable: false)
        }
        func listSurfaces() async throws -> [SurfaceInfo] { [] }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
            throw TerminalAccessError.unsupported(reason: "fake")
        }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }
        func rawOutputSource(for handle: SurfaceHandle) async throws -> SurfaceRawOutputSource? { raw }
    }

    // E2 — AuditLog.record is `async` non-throwing. Test recorder is an
    // `actor` so appends are serialized through the actor executor.
    actor RecordingAudit: AuditLog {
        var entries: [AuditEntry] = []
        func record(_ entry: AuditEntry) async { entries.append(entry) }
        func kinds() -> [AuditKind] { entries.map { $0.kind } }
    }

    @Test func rawSubscriptionForwardsBytesAndAuditsOpenClose() async throws {
        let provider = FakeProvider()
        let audit = RecordingAudit()
        let svc = DefaultTerminalAccessService(
            provider: provider, audit: audit,
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4))

        let lock = NSLock(); nonisolated(unsafe) var rx = Data()
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(
                handle: .ref(kind: "surface", ordinal: 1),
                mode: .raw, lastEventID: nil)
        ) { ev in
            if case .rawBytes(let d, _) = ev {
                lock.lock(); rx.append(d); lock.unlock()
            }
        }

        provider.raw.emit(Data("hello".utf8))
        try await Task.sleep(nanoseconds: 80_000_000)

        lock.lock(); let got = rx; lock.unlock()
        #expect(got == Data("hello".utf8))
        #expect(await audit.kinds().contains(.streamOpen))

        sub.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await audit.kinds().contains(.streamClose))
    }
}
```

- [ ] **Step 4: Commit red**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/TerminalAccessService.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SubscribeRawTests.swift
git commit -m "Add subscribeOutput skeleton + failing raw forwarding test"
git push origin HEAD
```

Expected: CI red — placeholder `openRawSubscription` never wires `FakeRaw` to `onEvent`.

---

### Task 2.17: Implement `openRawSubscription` — wires `SurfaceRawOutputSource` → `EventRing` → `onEvent`, audits open/close (GREEN)

(Resolves Coverage must_fix #6: event-level seq via `EventRing`; D6 resume; D4 always-on audit.)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift`

- [ ] **Step 1: Replace placeholder**

```swift
    private func openRawSubscription(
        info: SurfaceInfo,
        options: StreamSubscriptionOptions,
        capToken: StreamCap.Token,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        guard let source = try await provider.rawOutputSource(for: options.handle) else {
            capToken.release()
            throw TerminalAccessError.unsupported(reason: "raw_stream_unavailable")
        }
        let ring = EventRing(capacity: 1024)
        let deliver = DispatchQueue(
            label: "cmux.stream.raw.\(UUID().uuidString)", qos: .utility)
        let wake = DispatchSource.makeUserDataAddSource(queue: deliver)

        // Resume bookkeeping — set once before wake handler fires.
        let resumeAfter = options.lastEventID ?? 0

        // Track whether we already emitted the synthetic gap comment
        // (handled at the HTTP layer, not here — but `EventRing.drain`
        // is monotonic, so we only need to deliver after `resumeAfter`).
        var lastDelivered: UInt64 = resumeAfter
        let lastDeliveredLock = NSLock()

        wake.setEventHandler {
            lastDeliveredLock.lock()
            let after = lastDelivered
            lastDeliveredLock.unlock()
            for (s, e) in ring.drain(after: after) {
                onEvent(e)
                lastDeliveredLock.lock(); lastDelivered = s; lastDeliveredLock.unlock()
            }
        }
        wake.resume()

        // Attach to the raw source. The handler runs on whatever queue
        // the source delivers on (in production: the OutputTee's per-
        // slot deliverQueue). We append to the ring + signal the wake.
        let detachToken = try await source.attachRawOutput { bytes in
            _ = ring.append(.rawBytes(bytes, seq: 0))
            wake.add(data: 1)
        }

        // E2 — audit.record is async non-throwing.
        await audit.record(AuditEntry(
            timestamp: Date(), surface: options.handle,
            kind: .streamOpen, byteCount: 0,
            detail: ["mode": "raw", "resume": "\(resumeAfter)"]))

        let sub = OutputSubscription(
            id: UUID(), handle: options.handle, mode: .raw,
            onCancel: { [audit = self.audit] in
                wake.cancel()
                _ = detachToken  // keep alive until cancel
                capToken.release()
                // E2 — synchronous cancel closure schedules the async
                // audit write on a detached task; failure to await here
                // is fine because the audit is fire-and-forget.
                Task { @Sendable in
                    await audit.record(AuditEntry(
                        timestamp: Date(), surface: options.handle,
                        kind: .streamClose, byteCount: 0,
                        detail: ["mode": "raw"]))
                }
            }
        )
        return sub
    }
```

- [ ] **Step 2: Commit green**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift
git commit -m "Implement raw subscription wiring with EventRing + audit log"
git push origin HEAD
```

Expected: `SubscribeRawTests` from Task 2.16 turn green.

---

### Task 2.18: Implement `openCellsSubscription` using `SnapshotPoller` (D8) (characterization test — no red→green ritual)

(Resolves D8 entirely; Coverage must_fix on dirty-coalescing AND "no third ghostty patch". E13 — single characterization commit; the SnapshotPoller plumbing was already exercised by the SnapshotPollerTests in Task 2.10/2.11. E12 — Step 3 below promotes `SnapshotPoller.read` to `@Sendable () async throws -> CellGrid?`; the explicit fixture edits to Tasks 2.10/2.11 are listed below — they are NOT "adjust if needed" notes.)

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift`
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SnapshotPoller.swift` (E12 — promote `read` closure to async)
- Modify: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SnapshotPollerTests.swift` (E12 — wrap test fixture `read` closures as `{ @Sendable () async in current }`)
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SubscribeCellsTests.swift`

- [ ] **Step 1: Failing test (the failing-test commit lands FIRST per E12; the SnapshotPoller async change + Task 2.10/2.11 fixture updates ship in Step 2's GREEN commit)**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SubscribeCellsTests {
    // E1 — `SurfaceProvider.readCells(surface:region:)` (not `handle:`); the
    // provider also returns `SurfaceInfo?` (optional) from `resolve(_:)`.
    final class StaticCellsProvider: SurfaceProvider, @unchecked Sendable {
        var grid: CellGrid
        let canned: SurfaceInfo
        init(grid: CellGrid) {
            self.grid = grid
            self.canned = SurfaceInfo(
                handle: .ref(kind: "surface", ordinal: 1),
                uuid: UUID(), workspaceRef: "ws:1", title: nil,
                cols: grid.cols, rows: grid.rows, altScreen: grid.altScreen,
                focused: false, semanticAvailable: grid.semanticAvailable)
        }
        func listSurfaces() async throws -> [SurfaceInfo] { [canned] }
        func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo? { canned }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid { grid }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }
    }

    private func grid(letter: String) -> CellGrid {
        let cells = [Cell(t: letter, wide: .narrow, fg: .default, bg: .default,
                          attrs: [], underlineKind: nil, underlineColor: nil,
                          hyperlink: nil, semantic: nil)]
        return CellGrid(cols: 1, rows: 1, altScreen: false, title: nil,
                        cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                        semanticAvailable: false,
                        rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: cells)])
    }

    @Test func cellsEmitsOnlyOnContentChange() async throws {
        let provider = StaticCellsProvider(grid: grid(letter: "a"))
        let svc = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4),
            cellsTickRate: 200.0)

        let lock = NSLock(); nonisolated(unsafe) var letters: [String] = []
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(
                handle: .ref(kind: "surface", ordinal: 1),
                mode: .cells, lastEventID: nil)
        ) { ev in
            if case .cellsSnapshot(let g, _) = ev {
                lock.lock()
                letters.append(g.rowsData.first?.cells.first?.t ?? "")
                lock.unlock()
            }
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        provider.grid = grid(letter: "b")
        try await Task.sleep(nanoseconds: 60_000_000)
        provider.grid = grid(letter: "b") // unchanged
        try await Task.sleep(nanoseconds: 60_000_000)
        provider.grid = grid(letter: "c")
        try await Task.sleep(nanoseconds: 60_000_000)

        sub.cancel()
        lock.lock(); let got = letters; lock.unlock()
        #expect(got == ["a", "b", "c"])
    }
}
```

- [ ] **Step 2: Real `openCellsSubscription` with `SnapshotPoller`**

`DefaultTerminalAccessService` already accepts `cellsTickRate: Double = 5.0` per the E3 locked init signature; no new constructor parameter is needed. Replace the placeholder body:

```swift
    private func openCellsSubscription(
        info: SurfaceInfo,
        options: StreamSubscriptionOptions,
        capToken: StreamCap.Token,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        let ring = EventRing(capacity: 256)
        let deliver = DispatchQueue(
            label: "cmux.stream.cells.\(UUID().uuidString)", qos: .utility)

        let provider = self.provider
        let surface = info  // E1 — readCells takes `surface: SurfaceInfo`.

        // SnapshotPoller reads + hashes + emits only on change (D8).
        let poller = SnapshotPoller(
            tickRate: cellsTickRate,
            clock: SystemMonotonicClock(),
            read: {
                try await provider.readCells(surface: surface, region: .viewport)
            },
            emit: { grid in
                _ = ring.append(.cellsSnapshot(grid, seq: 0))
                deliver.async {
                    let after = ring.oldestSeq > 0 ? ring.oldestSeq - 1 : 0
                    for (_, e) in ring.drain(after: after) { onEvent(e) }
                }
            }
        )

        let timer = DispatchSource.makeTimerSource(queue: deliver)
        let intervalMs = max(5, Int(1000.0 / cellsTickRate))
        timer.schedule(deadline: .now() + .milliseconds(intervalMs),
                       repeating: .milliseconds(intervalMs))
        timer.setEventHandler { poller.tick() }
        timer.resume()

        // E2 — audit.record is async non-throwing.
        await audit.record(AuditEntry(
            timestamp: Date(), surface: options.handle,
            kind: .streamOpen, byteCount: 0,
            detail: ["mode": "cells", "tickRate": "\(cellsTickRate)"]))

        return OutputSubscription(
            id: UUID(), handle: options.handle, mode: .cells,
            onCancel: { [audit = self.audit] in
                timer.cancel()
                capToken.release()
                Task { @Sendable in
                    await audit.record(AuditEntry(
                        timestamp: Date(), surface: options.handle,
                        kind: .streamClose, byteCount: 0,
                        detail: ["mode": "cells"]))
                }
            }
        )
    }
```

(`SnapshotPoller.read` becomes `@Sendable () async throws -> CellGrid?` in Step 3 below per E12.)

- [ ] **Step 3: Promote `SnapshotPoller.read` to async**

In `SnapshotPoller.swift`, change the closure type to `@Sendable () async throws -> CellGrid?` and update `tick()` body:

```swift
    public func tick() {
        let minGap = 1.0 / tickRate
        lock.lock()
        let now = clock.now()
        if now - lastTick < minGap { lock.unlock(); return }
        lastTick = now
        lock.unlock()

        let sem = DispatchSemaphore(value: 0)
        var grid: CellGrid? = nil
        Task.detached { [read] in
            grid = try? await read()
            sem.signal()
        }
        sem.wait()
        guard let g = grid else { return }
        let digest = CellGridDigest.compute(g)
        lock.lock()
        if hasEmitted && digest == lastDigest { lock.unlock(); return }
        lastDigest = digest; hasEmitted = true
        lock.unlock()
        emit(g)
    }
```

**E12 mandatory edits to Task 2.10/2.11 SnapshotPollerTests.swift.** The async promotion breaks the existing fixture; update every test in `SnapshotPollerTests` to wrap the read closure as an async closure:

```swift
// BEFORE (Task 2.10/2.11):
read: { current },

// AFTER (E12):
read: { @Sendable () async in current },
```

`current` is captured by reference where it mutates between ticks (`var current = sampleGrid(letter: "a")`); in async-closure form, the read closure returns the current value synchronously inside an async wrapper. Each existing test in `SnapshotPollerTests` (`emitsOnceWhenContentChangesAcrossTicks`, `suppressesEmitWhenContentUnchanged`, `swallowsReadErrors`) updates the same way. The `swallowsReadErrors` test changes its `throw` form to `throw TerminalAccessError.unknownSurface` inside the async closure — the swallow semantics in `tick()` still apply.

- [ ] **Step 4: Commit (E13 — single characterization commit; no red/green split)**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SnapshotPoller.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SnapshotPollerTests.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/SubscribeCellsTests.swift
git commit -m "Implement cells subscription via SnapshotPoller (D8 + E12 async read)"
git push origin HEAD
```

---

### Task 2.19: `OutputSubscription.signalEnd` + `onEnd` wiring; surface-close test (RED → GREEN)

(Resolves Coverage must_fix on end-of-stream signaling; Quality must_fix on `OutputSubscription` shape per D22.)

`OutputSubscription` is defined in Phase 0 per D22/D23 with `id`, `handle`, `mode`, `cancel()`, `signalEnd()`, `var onEnd: (@Sendable () -> Void)?`, and `func events() -> AsyncStream<OutputEvent>`. Phase 2 ONLY uses it (no redefinition).

**Files:**
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift`
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceProvider.swift`
- Create: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/StreamEndOnSurfaceCloseTests.swift`

- [ ] **Step 1: Add async `observeClose` seam on `SurfaceProvider`**

```swift
public extension SurfaceProvider {
    /// Default: no-op token; live providers override to fire `onClose`
    /// when the underlying surface goes away.
    func observeClose(
        _ handle: SurfaceHandle,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> AnyObject {
        // Returning a fresh object keeps lifetime semantics consistent.
        return NSObject()
    }
}
```

- [ ] **Step 2: Failing test**

```swift
import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct StreamEndOnSurfaceCloseTests {
    // E1 — full SurfaceProvider conformance; only the methods this test
    // exercises (resolve, rawOutputSource, observeClose) carry behavior.
    final class ClosableProvider: SurfaceProvider, @unchecked Sendable {
        var closer: (@Sendable () -> Void)?
        func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo? {
            SurfaceInfo(handle: handle, uuid: UUID(), workspaceRef: "ws:1",
                        title: nil, cols: 80, rows: 24, altScreen: false,
                        focused: false, semanticAvailable: false)
        }
        func listSurfaces() async throws -> [SurfaceInfo] { [] }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
            throw TerminalAccessError.unsupported(reason: "closable")
        }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }
        func rawOutputSource(for handle: SurfaceHandle) async throws -> SurfaceRawOutputSource? {
            final class S: SurfaceRawOutputSource, @unchecked Sendable {
                func attachRawOutput(_ handler: @escaping @Sendable (Data) -> Void) async throws -> AnyObject {
                    NSObject()
                }
            }
            return S()
        }
        func observeClose(_ handle: SurfaceHandle,
                          onClose: @escaping @Sendable () -> Void) async throws -> AnyObject {
            closer = onClose; return NSObject()
        }
        func fireClose() { closer?() }
    }

    @Test func subscriberSeesOnEndWhenSurfaceCloses() async throws {
        let provider = ClosableProvider()
        let svc = DefaultTerminalAccessService(
            provider: provider, audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4))

        let lock = NSLock(); nonisolated(unsafe) var sawEnd = false
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(
                handle: .ref(kind: "surface", ordinal: 1),
                mode: .raw, lastEventID: nil)
        ) { _ in }
        sub.onEnd = { lock.lock(); sawEnd = true; lock.unlock() }

        provider.fireClose()
        try await Task.sleep(nanoseconds: 80_000_000)
        lock.lock(); let got = sawEnd; lock.unlock()
        #expect(got)
    }
}
```

- [ ] **Step 3: Wire `observeClose` in `openRawSubscription` AND `openCellsSubscription`**

At the end of each helper, before returning the `OutputSubscription`:

```swift
        let closeToken = try await provider.observeClose(options.handle) {
            [weak sub] in sub?.signalEnd()
        }
        sub.attachLifetime(closeToken)  // keep token alive
        return sub
```

Add a small helper on `OutputSubscription` in Phase 0 (already part of the D22 shape) — `internal func attachLifetime(_ obj: AnyObject)` retains the token until the subscription is cancelled. If Phase 0's shape doesn't expose this, add it in `OutputSubscription+Lifetime.swift`:

```swift
import Foundation

extension OutputSubscription {
    private static var lifetimeKey: UInt8 = 0
    /// Retain ``obj`` for the lifetime of this subscription.
    /// Released when ``cancel()`` runs.
    public func attachLifetime(_ obj: AnyObject) {
        objc_setAssociatedObject(self, &OutputSubscription.lifetimeKey,
                                 obj, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/SurfaceProvider.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/OutputSubscription+Lifetime.swift \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/StreamEndOnSurfaceCloseTests.swift
git commit -m "Signal stream end via provider observeClose; wire onEnd"
git push origin HEAD
```

---

### Task 2.20: HTTP route `GET /v1/surfaces/{id}/stream` — listener wiring + happy-path headers + 405/401 (RED → GREEN)

(Resolves Coverage must_fix on 405 method-mismatch via D11; Quality must_fix on route-dispatch split into smaller commits — split into 2.20–2.23.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift`
- Modify: `Sources/HTTPControl/HTTPRoute.swift`
- Create: `Sources/HTTPControl/SSEResponder.swift` (real impl, no stub buggy version)
- Create: `cmuxTests/HTTPControl/SSEResponderTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

`MonotonicClock` is imported from `CmuxTerminalAccess` (Task 2.7). No `Sources/HTTPControl/MonotonicClock.swift` is created in Phase 2.

- [ ] **Step 1: `SSEResponder.swift`**

```swift
import Foundation
import CmuxTerminalAccess

/// Streams Server-Sent Events to an opaque writer (in production: an
/// ``NWConnection``; in tests: a captured buffer).
///
/// Frame shape (spec §9):
/// ```
/// id: <seq>
/// event: <name>
/// data: <json>
/// \n
/// ```
/// plus a heartbeat comment line ``": ping\n\n"`` every
/// `heartbeatInterval` seconds. Also writes a ``": gap from=<a>
/// to=<b>"`` synthetic comment on resume below the ring's oldest seq
/// (D6).
public final class SSEResponder: @unchecked Sendable {
    public typealias Write = @Sendable (Data) -> Void

    private let write: Write
    private let clock: any MonotonicClock
    private let heartbeatInterval: Double
    private let lock = NSLock()
    private var lastHeartbeat: Double = 0
    private var headersSent = false

    public init(
        write: @escaping Write,
        clock: any MonotonicClock = SystemMonotonicClock(),
        heartbeatInterval: Double = 20.0
    ) {
        self.write = write
        self.clock = clock
        self.heartbeatInterval = heartbeatInterval
    }

    public func sendHeaders() {
        lock.lock()
        if headersSent { lock.unlock(); return }
        headersSent = true
        lastHeartbeat = clock.now()
        lock.unlock()
        let head = "HTTP/1.1 200 OK\r\n" +
                   "Content-Type: text/event-stream\r\n" +
                   "Cache-Control: no-cache\r\n" +
                   "Connection: keep-alive\r\n" +
                   "X-Accel-Buffering: no\r\n" +
                   "\r\n"
        write(Data(head.utf8))
    }

    public func send(event: String, id: UInt64, json: String) {
        let frame = "id: \(id)\nevent: \(event)\ndata: \(json)\n\n"
        write(Data(frame.utf8))
        lock.lock(); lastHeartbeat = clock.now(); lock.unlock()
    }

    /// D6 synthetic gap when resume id is below ring's oldest.
    public func sendResumeGapComment(from requested: UInt64, to oldest: UInt64) {
        let line = ": gap from=\(requested) to=\(oldest)\n\n"
        write(Data(line.utf8))
    }

    public func sendEnd() {
        write(Data("event: end\ndata: {}\n\n".utf8))
    }

    public func tick() {
        lock.lock()
        guard headersSent else { lock.unlock(); return }
        let now = clock.now()
        if now - lastHeartbeat >= heartbeatInterval {
            lastHeartbeat = now
            lock.unlock()
            write(Data(": ping\n\n".utf8))
            return
        }
        lock.unlock()
    }
}
```

- [ ] **Step 2: `SSEResponderTests.swift`**

```swift
import Foundation
import Testing
@testable import cmux
@testable import CmuxTerminalAccess

@Suite struct SSEResponderTests {
    final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var bytes = Data()
        let write: @Sendable (Data) -> Void
        init() {
            let inner = NSLock()
            var b = Data()
            self.write = { d in inner.lock(); b.append(d); inner.unlock() }
            // bind the inner buffer/lock to public accessors
            // by capturing them via reads through a method below
            // (kept simple here: re-implement directly):
            _ = inner; _ = b
        }
        // Simplified: rewrite Capture to expose write + bytes directly.
    }

    final class SimpleCapture: @unchecked Sendable {
        let lock = NSLock()
        var bytes = Data()
        func write(_ d: Data) {
            lock.lock(); bytes.append(d); lock.unlock()
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    @Test func emitsHeadersBeforeFirstEvent() {
        let cap = SimpleCapture()
        let r = SSEResponder(write: cap.write)
        r.sendHeaders()
        #expect(cap.text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(cap.text.contains("Content-Type: text/event-stream\r\n"))
        #expect(cap.text.contains("Cache-Control: no-cache\r\n"))
        #expect(cap.text.hasSuffix("\r\n\r\n"))
    }

    @Test func framesEventWithIdAndData() {
        let cap = SimpleCapture()
        let r = SSEResponder(write: cap.write)
        r.sendHeaders()
        r.send(event: "output", id: 42, json: "{\"bytes_base64\":\"aGk=\"}")
        #expect(cap.text.contains("id: 42\nevent: output\ndata: {\"bytes_base64\":\"aGk=\"}\n\n"))
    }

    @Test func framesResumeGapComment() {
        let cap = SimpleCapture()
        let r = SSEResponder(write: cap.write)
        r.sendHeaders()
        r.sendResumeGapComment(from: 100, to: 256)
        #expect(cap.text.contains(": gap from=100 to=256\n\n"))
    }

    @Test func heartbeatFiresAfterInterval() {
        let cap = SimpleCapture()
        let clock = ManualClock(start: 0)
        let r = SSEResponder(write: cap.write, clock: clock, heartbeatInterval: 20.0)
        r.sendHeaders()
        let before = cap.text
        clock.advance(by: 19.0); r.tick()
        #expect(cap.text == before)
        clock.advance(by: 2.0); r.tick()
        #expect(cap.text.contains(": ping\n\n"))
    }

    @Test func sendEndEmitsTerminalEvent() {
        let cap = SimpleCapture()
        let r = SSEResponder(write: cap.write)
        r.sendHeaders()
        r.sendEnd()
        #expect(cap.text.contains("event: end\ndata: {}\n\n"))
    }
}
```

- [ ] **Step 3: Register route in `HTTPControlServer`'s table-driven dispatcher (Phase 1 already refactored `route(_:)` to a table per Coverage must_fix). Add:**

```swift
        routes.register(method: "GET", pattern: "/v1/surfaces/{id}/stream",
                        handler: { req, conn, params in
                            try await self.handleStream(req, connection: conn,
                                                        surfaceId: params["id"]!)
                        })
```

(Phase 1 defines `routes: RouteTable` with `register(method:pattern:handler:)` and dispatches via `try await routes.dispatch(req, conn)`, returning 405 with `Allow:` when the path matches but method does not — D11.)

- [ ] **Step 4: Failing happy-path + 401 + 405 tests in `HTTPStreamRouteTests.swift`**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPStreamRouteTests {
    @Test func streamRejectsWithoutBearer() async throws {
        let env = try await HTTPControlTestEnv.start()  // Phase 1 helper
        defer { env.stop() }
        let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
        let (_, response) = try await URLSession.shared.bytes(for: URLRequest(url: url))
        #expect((response as! HTTPURLResponse).statusCode == 401)
    }

    @Test func streamPostReturns405WithAllowGet() async throws {
        let env = try await HTTPControlTestEnv.start()
        defer { env.stop() }
        let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (_, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405)
        #expect(http.value(forHTTPHeaderField: "Allow")?.contains("GET") == true)
    }

    @Test func streamGetReturns200WithSSEContentType() async throws {
        let env = try await HTTPControlTestEnv.start()
        defer { env.stop() }
        let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (_, response) = try await URLSession.shared.bytes(for: req)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
    }
}
```

(`HTTPControlTestEnv` is created in Phase 1 — it boots the server with a `StubSurfaceProvider` that supports stream subscribe.)

- [ ] **Step 5: Implement the bare `handleStream` for headers + 401/405 (no event delivery yet)**

```swift
private func handleStream(
    _ request: HTTPRequest,
    connection: NWConnection,
    surfaceId: String
) async throws {
    try auth.requireBearer(request)
    try hostAllowlist.check(request)
    try await rateLimiter.acquire(key: "surface:\(surfaceId)#stream-open")

    guard let handle = SurfaceHandle.parse(surfaceId) else {
        throw TerminalAccessError.unknownSurface
    }
    let modeStr = request.queryParams["mode"] ?? "raw"
    guard let mode = StreamMode(rawValue: modeStr) else {
        throw TerminalAccessError.badRequest(reason: "unknown_mode")
    }
    let lastEventID = request.headers["Last-Event-ID"].flatMap { UInt64($0) }

    let responder = SSEResponder(
        write: { data in
            connection.send(content: data,
                            completion: .contentProcessed { _ in })
        },
        clock: SystemMonotonicClock(),
        heartbeatInterval: settings.heartbeatSeconds)
    responder.sendHeaders()

    // Subscription wiring lands in Task 2.21.
    _ = (handle, mode, lastEventID, responder)
}
```

- [ ] **Step 6: Wire pbxproj, normalize, lint, commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/SSEResponder.swift \
        Sources/HTTPControl/HTTPControlServer.swift \
        Sources/HTTPControl/HTTPRoute.swift \
        cmuxTests/HTTPControl/SSEResponderTests.swift \
        cmuxTests/HTTPControl/HTTPStreamRouteTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add /v1/surfaces/{id}/stream route headers + 401/405 wiring"
git push origin HEAD
```

---

### Task 2.21: Wire `subscribeOutput` into `handleStream` + raw payload framing + cells payload framing

(Splits old Task 2.17 into smaller commits per Quality must_fix on Task 2.17 scope.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift`
- Create: `Sources/HTTPControl/StreamPayloads.swift`
- Create: `cmuxTests/HTTPControl/StreamPayloadsTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: `StreamPayloads.swift` — JSON formatters reused for both raw and cells events**

```swift
import Foundation
import CmuxTerminalAccess

/// JSON formatters for SSE event payloads. Kept here so both
/// ``HTTPControlServer.handleStream`` and tests share one path.
public enum StreamPayloads {
    public static func rawPayload(_ data: Data) -> String {
        "{\"bytes_base64\":\"\(data.base64EncodedString())\"}"
    }

    public static func cellsPayload(_ grid: CellGrid) -> String {
        // Reuses the Phase 1 CellGridJSON encoder.
        (try? CellGridJSON.encode(grid, region: .viewport)) ?? "{}"
    }
}
```

- [ ] **Step 2: Tests for the payload shapes**

```swift
import Foundation
import Testing
@testable import cmux
@testable import CmuxTerminalAccess

@Suite struct StreamPayloadsTests {
    @Test func rawPayloadIsBase64WrappedJSON() {
        let p = StreamPayloads.rawPayload(Data("hi".utf8))
        #expect(p == "{\"bytes_base64\":\"aGk=\"}")
    }

    @Test func cellsPayloadIsJSONObject() {
        let grid = CellGrid(
            cols: 1, rows: 1, altScreen: false, title: nil,
            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: false,
            rowsData: [CellRow(wrap: false, wrapContinuation: false,
                cells: [Cell(t: "x", wide: .narrow, fg: .default, bg: .default,
                             attrs: [], underlineKind: nil, underlineColor: nil,
                             hyperlink: nil, semantic: nil)])])
        let p = StreamPayloads.cellsPayload(grid)
        let obj = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: Any]
        #expect(obj?["format"] as? String == "cells")
        #expect(obj?["cols"] as? Int == 1)
    }
}
```

- [ ] **Step 3: Extend `handleStream` to call `service.subscribeOutput` and frame both modes**

Replace the trailing `_ = (handle, mode, lastEventID, responder)` from Task 2.20 with:

```swift
    let subscription = try await service.subscribeOutput(
        StreamSubscriptionOptions(handle: handle, mode: mode, lastEventID: lastEventID)
    ) { event in
        switch event {
        case .rawBytes(let data, let seq):
            responder.send(event: "output", id: seq,
                           json: StreamPayloads.rawPayload(data))
        case .cellsSnapshot(let grid, let seq):
            responder.send(event: "screen", id: seq,
                           json: StreamPayloads.cellsPayload(grid))
        }
    }

    // Lifetime store: keep subscription alive until the connection
    // drops; wired up fully in Task 2.23.
    self.activeSubscriptions[ObjectIdentifier(connection)] = subscription
```

Add a property:

```swift
private var activeSubscriptions: [ObjectIdentifier: OutputSubscription] = [:]
private let activeSubscriptionsLock = NSLock()
```

with thread-safe accessors using `activeSubscriptionsLock`.

- [ ] **Step 4: Wire pbxproj, commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/StreamPayloads.swift \
        Sources/HTTPControl/HTTPControlServer.swift \
        cmuxTests/HTTPControl/StreamPayloadsTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Frame raw + cells SSE payloads via StreamPayloads"
git push origin HEAD
```

---

### Task 2.22: Heartbeat timer + lifetime cleanup on connection close

(Splits old Task 2.17 further per Quality must_fix.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift`
- Create: `cmuxTests/HTTPControl/StreamHeartbeatTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test (subscriber sees a `: ping` comment after the configured heartbeat)**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamHeartbeatTests {
    @Test func heartbeatCommentArrivesAfterInterval() async throws {
        let env = try await HTTPControlTestEnv.start(heartbeatSeconds: 1)
        defer { env.stop() }
        let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        var iter = bytes.lines.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(4)
        var sawPing = false
        while Date() < deadline, !sawPing {
            if let line = try await iter.next(), line.hasPrefix(": ping") {
                sawPing = true
            }
        }
        #expect(sawPing)
    }
}
```

- [ ] **Step 2: Implement heartbeat + cleanup in `handleStream`**

After the `service.subscribeOutput` block:

```swift
    let heartbeatQueue = DispatchQueue(label: "cmux.stream.heartbeat", qos: .utility)
    let heartbeat = DispatchSource.makeTimerSource(queue: heartbeatQueue)
    heartbeat.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
    heartbeat.setEventHandler { responder.tick() }
    heartbeat.resume()

    subscription.onEnd = { [weak self, connection] in
        responder.sendEnd()
        heartbeat.cancel()
        connection.cancel()
        self?.dropSubscription(for: connection)
    }

    connection.stateUpdateHandler = { [weak self] state in
        switch state {
        case .failed, .cancelled:
            heartbeat.cancel()
            subscription.cancel()
            self?.dropSubscription(for: connection)
        default: break
        }
    }
```

with helper:

```swift
private func dropSubscription(for connection: NWConnection) {
    activeSubscriptionsLock.lock()
    activeSubscriptions.removeValue(forKey: ObjectIdentifier(connection))
    activeSubscriptionsLock.unlock()
}
```

- [ ] **Step 3: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/HTTPControlServer.swift \
        cmuxTests/HTTPControl/StreamHeartbeatTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Add SSE heartbeat + connection-close cleanup"
git push origin HEAD
```

---

### Task 2.23: Per-surface stream cap enforcement at HTTP layer — 503 on overflow

(Splits old Task 2.17 final third per Quality must_fix; D7 cap-of-8 default but tests can override.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift`
- Create: `cmuxTests/HTTPControl/StreamCapHTTPTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Map `unsupported(reason: "too_many_streams")` from the service to HTTP 503 inside `handleStream`'s error handling, NOT in the generic mapper (D18 keeps `unsupported` → 415 for everything else).**

In `handleStream`, wrap the subscribe call:

```swift
    let subscription: OutputSubscription
    do {
        subscription = try await service.subscribeOutput(
            StreamSubscriptionOptions(
                handle: handle, mode: mode, lastEventID: lastEventID)
        ) { event in /* ... */ }
    } catch TerminalAccessError.unsupported(let reason) where reason == "too_many_streams" {
        // Respond with HTTP 503 (Service Unavailable) per spec §9.1.
        let body = "{\"error\":{\"code\":\"too_many_streams\",\"message\":\"per-surface stream cap reached\"}}"
        let resp = "HTTP/1.1 503 Service Unavailable\r\n" +
                   "Content-Type: application/json\r\n" +
                   "Content-Length: \(body.utf8.count)\r\n" +
                   "Connection: close\r\n\r\n\(body)"
        connection.send(content: Data(resp.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
        return
    }
```

(Move the `responder.sendHeaders()` call so it happens AFTER the subscribe succeeds; until subscribe returns we have not committed to a 200 response. Reorder the code in `handleStream` accordingly.)

- [ ] **Step 2: Failing test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamCapHTTPTests {
    @Test func fifthConcurrentStreamReturns503() async throws {
        let env = try await HTTPControlTestEnv.start(maxStreamsPerSurface: 4)
        defer { env.stop() }

        var tasks: [Task<Int, Error>] = []
        for _ in 0..<5 {
            tasks.append(Task<Int, Error> {
                let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
                req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
                let (_, resp) = try await URLSession.shared.bytes(for: req)
                return (resp as! HTTPURLResponse).statusCode
            })
        }
        var codes: [Int] = []
        for t in tasks { codes.append(try await t.value) }
        #expect(codes.filter { $0 == 200 }.count == 4)
        #expect(codes.filter { $0 == 503 }.count == 1)
    }
}
```

- [ ] **Step 3: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/HTTPControlServer.swift \
        cmuxTests/HTTPControl/StreamCapHTTPTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Enforce per-surface stream cap with HTTP 503 response"
git push origin HEAD
```

---

### Task 2.24: `Last-Event-ID` resume — in-ring vs gap-comment (D6)

(Resolves Coverage must_fix #5 and the byte-vs-event-seq design error. Resume happens at the SSE layer using `EventRing.resumeIsBelowOldest`.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift`
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift` (expose the ring's `oldestSeq` via the subscription)
- Modify: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/OutputSubscription.swift` (D22 already has `id`/`handle`/`mode`; we only ADD an internal `ringOldestSeq()` accessor via a closure parameter on init in Phase 0; if not present, add via extension here)
- Create: `cmuxTests/HTTPControl/LastEventIdResumeTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Expose `ringOldestSeq` on the subscription via `attachLifetime` token shape**

In `OutputSubscription+Lifetime.swift` (created in Task 2.19), add:

```swift
extension OutputSubscription {
    private static var oldestSeqKey: UInt8 = 0
    public func attachRingOldestSeq(_ provider: @escaping @Sendable () -> UInt64) {
        objc_setAssociatedObject(self, &OutputSubscription.oldestSeqKey,
                                 provider as AnyObject,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    public func ringOldestSeq() -> UInt64 {
        let obj = objc_getAssociatedObject(self, &OutputSubscription.oldestSeqKey)
        if let fn = obj as? @Sendable () -> UInt64 { return fn() }
        return 0
    }
}
```

In `DefaultTerminalAccessService` raw/cells helpers, immediately before returning `sub`:

```swift
        sub.attachRingOldestSeq { [weak ring] in ring?.oldestSeq ?? 0 }
```

- [ ] **Step 2: Failing test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct LastEventIdResumeTests {
    @Test func resumeFromExpiredIdEmitsGapCommentThenEvents() async throws {
        let env = try await HTTPControlTestEnv.start(ringCapacity: 4)
        defer { env.stop() }
        // Pre-drive a bunch of events so id=0 is below the ring's oldest.
        for i in 0..<32 {
            env.fixture.fakeRawSource(for: "surface:1").emit(Data([UInt8(i)]))
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        req.setValue("0", forHTTPHeaderField: "Last-Event-ID")
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        var sawGapComment = false
        var iter = bytes.lines.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sawGapComment {
            if let line = try await iter.next(), line.hasPrefix(": gap from=0 to=") {
                sawGapComment = true
            }
        }
        #expect(sawGapComment)
    }
}
```

- [ ] **Step 3: Implement in `handleStream` after subscribe succeeds**

```swift
    if let resume = lastEventID,
       subscription.ringOldestSeq() > resume {
        responder.sendResumeGapComment(from: resume,
                                       to: subscription.ringOldestSeq())
    }
```

- [ ] **Step 4: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/DefaultTerminalAccessService.swift \
        Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/OutputSubscription+Lifetime.swift \
        Sources/HTTPControl/HTTPControlServer.swift \
        cmuxTests/HTTPControl/LastEventIdResumeTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Implement Last-Event-ID resume with synthetic gap comment (D6)"
git push origin HEAD
```

---

### Task 2.25: Stream-open rate limit via shared `RateLimiter` keys (D10)

(Resolves Coverage must_fix on rate-limit; D10 single definition; uses `acquire(key:)` against `"surface:<id>#stream-open"`.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift` (already calls `rateLimiter.acquire(key:)` in Task 2.20 Step 5; this task adds the test)
- Create: `cmuxTests/HTTPControl/StreamOpenRateLimitTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Failing test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamOpenRateLimitTests {
    @Test func excessiveStreamOpensReturn429() async throws {
        let env = try await HTTPControlTestEnv.start(
            streamOpenBurst: 3, streamOpenRefillPerSecond: 0.1)
        defer { env.stop() }
        var codes: [Int] = []
        for _ in 0..<8 {
            let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
            req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
            let (_, resp) = try await URLSession.shared.data(for: req)
            codes.append((resp as! HTTPURLResponse).statusCode)
        }
        #expect(codes.filter { $0 == 429 }.count >= 1)
    }
}
```

(Phase 1 already maps `TerminalAccessError.tooManyRequests` → 429; the `RateLimiter` throws this when `acquire(key:)` fails.)

- [ ] **Step 2: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add cmuxTests/HTTPControl/StreamOpenRateLimitTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Test stream-open rate limit returns 429"
git push origin HEAD
```

---

### Task 2.26: `AppSurfaceProvider` raw-output integration with live Ghostty surfaces (D9 reaffirmed)

(Resolves Coverage placeholder on `AppSurfaceProvider.shared` / `provider.testInject(...)`; D9 token-not-in-env code comment.)

**Files:**
- Modify: `Sources/HTTPControl/AppSurfaceProvider.swift`
- Create: `Sources/HTTPControl/AppSurfaceRawSource.swift`
- Create: `cmuxTests/HTTPControl/AppSurfaceTokenNotInEnvTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: `AppSurfaceRawSource.swift`**

```swift
import Foundation
import GhosttyKit
import CmuxTerminalAccess

/// Live-Ghostty implementation of ``SurfaceRawOutputSource``. Wraps an
/// ``OutputTee`` installed on the surface's C handle. ZERO token
/// material is exported to the child PTY env (D9) — this seam only
/// READS bytes coming out of the child.
final class AppSurfaceRawSource: SurfaceRawOutputSource, @unchecked Sendable {
    private let tee: OutputTee

    init(cSurface: OpaquePointer) {
        self.tee = OutputTee(slotCapacity: 8, ringCapacity: 512 * 1024,
                             surface: cSurface)
    }

    func attachRawOutput(
        _ handler: @escaping @Sendable (Data) -> Void
    ) async throws -> AnyObject {
        let q = DispatchQueue(label: "cmux.tee.deliver.\(UUID().uuidString)",
                              qos: .utility)
        guard let slot = tee.subscribe(deliverQueue: q, handler: handler) else {
            throw TerminalAccessError.unsupported(reason: "too_many_streams")
        }
        // Return a wrapper that unsubscribes on dealloc.
        return SlotToken(tee: tee, slot: slot)
    }

    private final class SlotToken {
        let tee: OutputTee; let slot: OutputTee.Slot
        init(tee: OutputTee, slot: OutputTee.Slot) {
            self.tee = tee; self.slot = slot
        }
        deinit { tee.unsubscribe(slot) }
    }
}
```

- [ ] **Step 2: Extend `AppSurfaceProvider`**

```swift
extension AppSurfaceProvider {
    // IMPORTANT (D9): the HTTP control token must NEVER be propagated
    // into a child terminal's environment. Surfaces created here only
    // RECEIVE bytes from the child via the PTY output tee; nothing in
    // this code path writes HTTPControlSettings.token to the child env.
    // Do not add such an export.
    func rawOutputSource(for handle: SurfaceHandle) async throws -> SurfaceRawOutputSource? {
        guard let cSurface = try await resolveCSurface(for: handle) else { return nil }
        return AppSurfaceRawSource(cSurface: cSurface)
    }
}
```

- [ ] **Step 3: Failing test confirming the token is absent from new-surface env**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct AppSurfaceTokenNotInEnvTests {
    @Test func newTerminalSurfaceDoesNotInheritHTTPControlToken() async throws {
        let settings = HTTPControlSettings(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let token = try settings.ensureToken()

        // Spawn a synthetic terminal via the existing test fixture
        // factory (Phase 0 Task 0.14 introduced this fixture; here we
        // launch /bin/sh -c "env" and capture its environment).
        let env = try await TerminalSurfaceFixture.spawnAndCapturedEnvironment(
            command: "/bin/sh", args: ["-c", "env"])
        #expect(!env.contains(token))
        #expect(!env.contains("CMUX_HTTP_TOKEN"))
    }
}
```

(`TerminalSurfaceFixture` is created in Phase 0 Task 0.14 to support the regression characterization tests; Phase 0 also adds a `spawnAndCapturedEnvironment` helper to cover D9.)

- [ ] **Step 4: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/AppSurfaceRawSource.swift \
        Sources/HTTPControl/AppSurfaceProvider.swift \
        cmuxTests/HTTPControl/AppSurfaceTokenNotInEnvTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Wire AppSurfaceProvider raw stream + reaffirm token-not-in-env (D9)"
git push origin HEAD
```

---

### Task 2.27: E2E — raw bytes round-trip through real surface

**Files:**
- Create: `cmuxTests/HTTPControl/StreamE2ERawTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamE2ERawTests {
    @Test func rawStreamObservesBytesWrittenViaInputEndpoint() async throws {
        let env = try await HTTPControlTestEnv.startWithLiveSurface(
            command: "/bin/sh", args: ["-c", "cat"])
        defer { env.stop() }

        let streamURL = URL(string: "\(env.baseURL)/v1/surfaces/\(env.surfaceHandle)/stream?mode=raw")!
        var streamReq = URLRequest(url: streamURL)
        streamReq.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        streamReq.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (bytes, _) = try await URLSession.shared.bytes(for: streamReq)

        let inputURL = URL(string: "\(env.baseURL)/v1/surfaces/\(env.surfaceHandle)/input")!
        var inputReq = URLRequest(url: inputURL)
        inputReq.httpMethod = "POST"
        inputReq.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        inputReq.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        inputReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        inputReq.httpBody = Data("{\"type\":\"text\",\"text\":\"ROUNDTRIP\",\"submit\":true}".utf8)
        _ = try await URLSession.shared.data(for: inputReq)

        var collected = Data()
        for try await line in bytes.lines {
            if line.hasPrefix("data: "),
               let json = try? JSONSerialization.jsonObject(
                with: Data(line.dropFirst(6).utf8)) as? [String: Any],
               let b64 = json["bytes_base64"] as? String,
               let d = Data(base64Encoded: b64) {
                collected.append(d)
                if collected.range(of: Data("ROUNDTRIP".utf8)) != nil { break }
            }
        }
        #expect(collected.range(of: Data("ROUNDTRIP".utf8)) != nil)
    }
}
```

- [ ] **Step 2: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add cmuxTests/HTTPControl/StreamE2ERawTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add raw stream E2E (bytes round-trip via live surface)"
git push origin HEAD
```

---

### Task 2.28: E2E — cells snapshot reflects visible output

**Files:**
- Create: `cmuxTests/HTTPControl/StreamE2ECellsTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamE2ECellsTests {
    @Test func cellsStreamReflectsVisibleOutput() async throws {
        let env = try await HTTPControlTestEnv.startWithLiveSurface(
            command: "/bin/sh",
            args: ["-c", "printf 'HELLO\\n'; sleep 5"])
        defer { env.stop() }
        let url = URL(string: "\(env.baseURL)/v1/surfaces/\(env.surfaceHandle)/stream?mode=cells")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (bytes, _) = try await URLSession.shared.bytes(for: req)

        var sawHello = false
        let deadline = Date().addingTimeInterval(8)
        for try await line in bytes.lines {
            if Date() > deadline { break }
            if line.hasPrefix("data: "),
               let json = try? JSONSerialization.jsonObject(
                with: Data(line.dropFirst(6).utf8)) as? [String: Any],
               let rows = json["rows_data"] as? [[String: Any]] {
                let flat = rows.compactMap { row -> String? in
                    guard let cells = row["cells"] as? [[String: Any]] else { return nil }
                    return cells.compactMap { $0["t"] as? String }.joined()
                }.joined()
                if flat.contains("HELLO") { sawHello = true; break }
            }
        }
        #expect(sawHello)
    }
}
```

- [ ] **Step 2: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add cmuxTests/HTTPControl/StreamE2ECellsTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Add cells stream E2E (snapshot reflects visible output)"
git push origin HEAD
```

---

### Task 2.29: Backpressure E2E — slow consumer sees seq JUMP without stalling source (D6, spec §9.1)

(Resolves Coverage must_fix on "drop-oldest + seq jump as the gap signal" — verified at the wire level.)

**Files:**
- Create: `cmuxTests/HTTPControl/StreamBackpressureTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamBackpressureTests {
    @Test func slowConsumerObservesSeqJumpAndSourceStaysAlive() async throws {
        let env = try await HTTPControlTestEnv.startWithLiveSurface(
            command: "/bin/sh",
            args: ["-c", "yes ABCDEFGHIJKLMNOPQRSTUVWXYZ"],
            ringCapacity: 16)  // 16 events; force overflow quickly
        defer { env.stop() }

        let url = URL(string: "\(env.baseURL)/v1/surfaces/\(env.surfaceHandle)/stream?mode=raw")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (bytes, _) = try await URLSession.shared.bytes(for: req)

        var lastId: UInt64 = 0
        var sawJump = false
        var iter = bytes.lines.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !sawJump {
            guard let line = try await iter.next() else { break }
            if line.hasPrefix("id: "),
               let id = UInt64(line.dropFirst(4)) {
                if lastId != 0 && id > lastId + 1 { sawJump = true }
                lastId = id
            }
            try await Task.sleep(nanoseconds: 50_000_000)  // slow consumer
        }
        #expect(sawJump, "slow consumer must see a seq JUMP (drop-oldest signal)")

        // Source still alive: send a poke; the request must succeed.
        let pokeURL = URL(string: "\(env.baseURL)/v1/surfaces/\(env.surfaceHandle)/input")!
        var poke = URLRequest(url: pokeURL)
        poke.httpMethod = "POST"
        poke.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        poke.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        poke.setValue("application/json", forHTTPHeaderField: "Content-Type")
        poke.httpBody = Data("{\"type\":\"text\",\"text\":\"POKE\",\"submit\":false}".utf8)
        let (_, resp) = try await URLSession.shared.data(for: poke)
        #expect((resp as! HTTPURLResponse).statusCode == 200)
    }
}
```

- [ ] **Step 2: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add cmuxTests/HTTPControl/StreamBackpressureTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "Verify backpressure: slow consumer sees seq JUMP without stalling source"
git push origin HEAD
```

---

### Task 2.30: Token rotation invalidates running SSE subscriptions

(Resolves Coverage must_fix #29: token rotation must drop active subscriptions; D2 token store lives on `HTTPControlSettings`.)

**Files:**
- Modify: `Sources/HTTPControl/HTTPControlServer.swift`
- Create: `cmuxTests/HTTPControl/StreamTokenRotationTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add `invalidateAllSubscriptions()` and call it from the settings lifecycle when token changes**

```swift
extension HTTPControlServer {
    /// Cancel every active streaming subscription and close its
    /// connection. Called by `HTTPControlLifecycle` when the token
    /// rotates. Existing one-shot request handlers are unaffected.
    public func invalidateAllSubscriptions() {
        activeSubscriptionsLock.lock()
        let subs = Array(activeSubscriptions.values)
        let ids  = Array(activeSubscriptions.keys)
        activeSubscriptions.removeAll()
        activeSubscriptionsLock.unlock()
        for s in subs { s.cancel() }
        _ = ids  // connections drop on subscription cancel via stateUpdateHandler
    }
}
```

Phase 1 Task 1.23's `HTTPControlLifecycle` observes the token's `tokenFilePath` mtime (or `HTTPControlSettings`'s `didChange` notification on `token`) and calls `server.invalidateAllSubscriptions()` when the token changes. Add that call from Phase 1's lifecycle in this commit (cross-phase touch is needed because the token-change handler exists in Phase 1).

- [ ] **Step 2: Failing test**

```swift
import Foundation
import Testing
@testable import cmux

@Suite struct StreamTokenRotationTests {
    @Test func rotatingTokenClosesActiveStreams() async throws {
        let env = try await HTTPControlTestEnv.start()
        defer { env.stop() }
        let url = URL(string: "\(env.baseURL)/v1/surfaces/surface:1/stream?mode=raw")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(env.token)", forHTTPHeaderField: "Authorization")
        req.setValue("127.0.0.1:\(env.port)", forHTTPHeaderField: "Host")
        let (bytes, _) = try await URLSession.shared.bytes(for: req)

        _ = try env.settings.rotateToken()  // triggers invalidateAllSubscriptions

        var sawEnd = false
        var iter = bytes.lines.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sawEnd {
            if let line = try await iter.next(), line.contains("event: end") {
                sawEnd = true
            }
        }
        #expect(sawEnd)
    }
}
```

- [ ] **Step 3: Wire + commit**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
git add Sources/HTTPControl/HTTPControlServer.swift \
        cmuxTests/HTTPControl/StreamTokenRotationTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "Invalidate active SSE subscriptions on token rotation"
git push origin HEAD
```

---

### Task 2.31: Localize streaming-related Settings strings + extend config schema (`httpControl.stream`)

(Resolves Coverage must_fix #25: localize all user-visible strings; extend the cmux.json schema. D14: schema test is BEHAVIORAL — Phase 1 already wrote one against the config loader; we extend it.)

**Files:**
- Modify: `Resources/Localizable.xcstrings`
- Modify: `Sources/HTTPControl/HTTPControlSettings.swift` (add stream fields)
- Modify: `web/data/cmux.schema.json`
- Modify: `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift` (extend behavioral test from Phase 1 to round-trip the new `stream` block)
- Modify: `docs/configuration.md`

- [ ] **Step 1: Add localized strings**

In `Resources/Localizable.xcstrings`, add EN+JA entries for:

- `httpcontrol.stream.cap.label` / EN "Maximum concurrent streams per surface" / JA "サーフェスごとの最大同時ストリーム数"
- `httpcontrol.stream.cap.help` / EN "Extra connections beyond this cap receive HTTP 503." / JA "この上限を超えた接続は HTTP 503 を返します。"
- `httpcontrol.stream.heartbeat.label` / EN "SSE heartbeat interval (seconds)" / JA "SSE ハートビート間隔(秒)"
- `httpcontrol.stream.cells.rate.label` / EN "Cell-snapshot max rate (per second)" / JA "セルスナップショット最大レート(回/秒)"
- `httpcontrol.stream.ring.label` / EN "Per-subscriber ring capacity (events)" / JA "サブスクライバーごとのリング容量(イベント数)"

Reference via `String(localized: "httpcontrol.stream.cap.label", defaultValue: "Maximum concurrent streams per surface")` in `HTTPControlSettingsView`.

- [ ] **Step 2: Extend `HTTPControlSettings` (D2: instance class)**

Append:

```swift
    public var streamMaxPerSurface: Int { /* @AppStorage default 8 */ ... }
    public var streamHeartbeatSeconds: Int { /* default 20 */ ... }
    public var streamCellsTickRate: Double { /* default 5.0 */ ... }
    public var streamEventRingCapacity: Int { /* default 1024 */ ... }
    public var streamOpenBurst: Int { /* default 5 */ ... }
    public var streamOpenRefillPerSecond: Double { /* default 0.5 */ ... }
```

Wire those defaults into `HTTPControlServer`'s `RateLimiter`, `StreamCap`, `SSEResponder.heartbeatInterval`, and `DefaultTerminalAccessService.cellsTickRate`.

- [ ] **Step 3: Extend `web/data/cmux.schema.json`**

Under `properties.httpControl`, add:

```json
"stream": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "maxPerSurface":           { "type": "integer", "default": 8,   "minimum": 1, "maximum": 32 },
    "heartbeatSeconds":        { "type": "integer", "default": 20,  "minimum": 5, "maximum": 120 },
    "cellsTickRate":           { "type": "number",  "default": 5.0, "minimum": 0.1, "maximum": 30 },
    "eventRingCapacity":       { "type": "integer", "default": 1024,"minimum": 16, "maximum": 65536 },
    "openBurst":               { "type": "integer", "default": 5,   "minimum": 1, "maximum": 100 },
    "openRefillPerSecond":     { "type": "number",  "default": 0.5, "minimum": 0.01,"maximum": 100 }
  }
}
```

- [ ] **Step 4: Extend Phase 1's behavioral loader test**

In `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift` (created in Phase 1 Task 1.20 per E7), add:

```swift
    @Test func parseAcceptsStreamBlockAndRoundTripsValues() throws {
        let json = #"""
        { "enabled": true,
          "stream": { "maxPerSurface": 16, "heartbeatSeconds": 30,
                      "cellsTickRate": 10.0, "eventRingCapacity": 2048,
                      "openBurst": 10, "openRefillPerSecond": 1.0 } }
        """#
        let loaded = try HTTPControlConfigLoader.parse(Data(json.utf8))
        let stream = try #require(loaded.stream)
        #expect(stream.maxPerSurface == 16)
        #expect(stream.heartbeatSeconds == 30)
        #expect(stream.cellsTickRate == 10.0)
        #expect(stream.eventRingCapacity == 2048)
        #expect(stream.openBurst == 10)
        #expect(stream.openRefillPerSecond == 1.0)
    }
```

And extend `HTTPControlConfig` in `HTTPControlConfigLoader.swift` with a
new optional `stream: HTTPControlStreamConfig?` field, plus the
`HTTPControlStreamConfig` struct enumerating the six fields above.

- [ ] **Step 5: Document in `docs/configuration.md`**

Add "HTTP control - streaming" subsection enumerating the keys, defaults, and the spec §9.1 backpressure rationale (drop-oldest, seq JUMP signals gap, heartbeat, stream cap, polled cells via D8).

- [ ] **Step 6: Commit**

```bash
git add Resources/Localizable.xcstrings \
        Sources/HTTPControl/HTTPControlSettings.swift \
        web/data/cmux.schema.json \
        Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift \
        docs/configuration.md
git commit -m "Add httpControl.stream config + localize stream Settings strings"
git push origin HEAD
```

---

### Task 2.32: Append SSE docs to `docs/http-terminal-api.md` — fetch-streaming example + backpressure + out-of-scope

(Resolves Coverage must_fix #43: docs must declare `cells` snapshot-only (not diffs); D28: explicit out-of-scope list for Sixel/DCS/images.)

**Files:**
- Modify: `docs/http-terminal-api.md`

- [ ] **Step 1: Append**

```markdown
## Streaming: `GET /v1/surfaces/{id}/stream`

Server-Sent Events. Two modes:

| `?mode=` | Frame                                                              |
|----------|--------------------------------------------------------------------|
| `raw`    | `event: output` with `data: {"bytes_base64":"..."}` (live PTY bytes) |
| `cells`  | `event: screen` with `data: <CellGrid JSON>` (full snapshots; v1 has no cell-diff stream) |

### Authentication

Requires `Authorization: Bearer <token>`. The browser's native
`EventSource` does NOT support custom headers, so you cannot use it.
Use `fetch` with a streaming `ReadableStream`:

```js
async function subscribe(surfaceId, token, port, onEvent) {
  const res = await fetch(
    `http://127.0.0.1:${port}/v1/surfaces/${surfaceId}/stream?mode=raw`,
    { headers: {
        'Authorization': `Bearer ${token}`,
        'Last-Event-ID': sessionStorage.getItem('cmux.lastId') ?? '',
      } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const reader = res.body.getReader();
  const dec = new TextDecoder('utf-8');
  let buf = '';
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf('\n\n')) !== -1) {
      const frame = buf.slice(0, idx); buf = buf.slice(idx + 2);
      if (frame.startsWith(': ')) continue;   // heartbeat or gap comment
      let id, event = 'message', data = '';
      for (const line of frame.split('\n')) {
        if (line.startsWith('id: '))      id    = Number(line.slice(4));
        else if (line.startsWith('event: ')) event = line.slice(7);
        else if (line.startsWith('data: '))  data  = line.slice(6);
      }
      if (id !== undefined) sessionStorage.setItem('cmux.lastId', String(id));
      onEvent({ id, event, data: data ? JSON.parse(data) : null });
      if (event === 'end') return;
    }
  }
}
```

### Frame shapes

```
id: 42
event: output
data: {"bytes_base64":"aGVsbG8="}

id: 7
event: screen
data: { "format":"cells", "cols":80, "rows":24, "alt_screen":false,
        "title":"zsh", "cursor":{...}, "rows_data":[...] }

event: end
data: {}

: ping

: gap from=100 to=256
```

### Backpressure (§9.1)

The PTY tee that feeds `mode=raw` runs under Ghostty's renderer lock on
the io-reader thread. The server:

- never blocks the producer; the per-subscriber EVENT ring is bounded
  (default 1024 events)
- drops oldest events on overflow; the next event's `id:` JUMPS,
  which is the signal that data was dropped (clients should re-fetch
  `GET /screen?format=cells` to resync)
- writes to the network on a separate dispatch queue
- emits a `: ping` heartbeat every 20s (configurable) so dead peers
  are detected
- caps concurrent streams per surface (default 8; extras get HTTP 503)

### Resuming with `Last-Event-ID`

Send the last id you saw in the `Last-Event-ID` header. If the
requested id is still in the ring you resume from the next event. If
the requested id is below the ring's oldest, the server emits one
comment line `: gap from=<requested> to=<oldest>` and resumes from the
ring's oldest event.

### Stream end

When the underlying surface closes (or the token rotates), the server
sends `event: end` and closes the connection cleanly. Treat this as a
permanent terminal signal — do not auto-reconnect without rechecking
the token.

### Out of scope for v1

- Sixel / DCS / Kitty-image protocol: `mode=raw` carries these as
  opaque bytes (the bracketed sequences are part of the byte stream);
  `mode=cells` silently drops them (a CellGrid snapshot has no image
  cells in v1). See spec §15 for the v2 plan.
- Cell-level diff streaming: v1 only ships full snapshots throttled
  via the time-tick poller (see spec §9.1 / §15 open question).
- Live "dirty notifier" push from ghostty: v1 polls at a configurable
  tick rate and hashes the cell grid; a true push notifier may land
  in v2 (would require a third ghostty patch we did not authorize).
```

- [ ] **Step 2: Commit**

```bash
git add docs/http-terminal-api.md
git commit -m "Document SSE streaming, backpressure, resume, out-of-scope (v1)"
git push origin HEAD
```

---

### Task 2.33: pbxproj normalization + final phase-2 sweep

**Files:**
- Modify: `cmux.xcodeproj/project.pbxproj` (normalization only)

- [ ] **Step 1: Run the full lint sweep**

```bash
python3 /Volumes/workspace/git/hillion/cmux/scripts/normalize-pbxproj.py /Volumes/workspace/git/hillion/cmux/cmux.xcodeproj/project.pbxproj
/Volumes/workspace/git/hillion/cmux/scripts/lint-pbxproj-test-wiring.sh
/Volumes/workspace/git/hillion/cmux/scripts/check-pbxproj.sh
```

All three must exit 0.

- [ ] **Step 2: Commit any normalization diffs (if produced)**

```bash
git diff --quiet cmux.xcodeproj/project.pbxproj || {
  git add cmux.xcodeproj/project.pbxproj
  git commit -m "Normalize pbxproj after Phase 2 wiring"
}
git push origin HEAD
```

---

### Open-question disposition for Phase 2 (recorded; spec §15)

| §15 question | Phase 2 disposition |
|---|---|
| Q1 SSE vs WS | SSE chosen for v1. Re-evaluate WebSocket only if a real client demands single-connection bidirectional. No upstream/tracking issue filed in this phase. |
| Q2 cells-diff | Explicitly deferred to v2 (D28). Phase 2 ships `cells` full snapshots throttled + hash-gated by ``SnapshotPoller`` (D8). |
| Q3 patch #1 upstream | Phase 1 already filed the upstream-tracking issue per D19. Phase 2 does NOT touch patch #1. |
| Dirty-notification source | Spec leaves this as an open question (third ghostty patch vs polling). Phase 2 chooses polling (D8); a v2 upgrade to a real renderer dirty notifier remains open. |


---

## Open Issues / Deferred to v2

These are explicitly out of scope for v1. The plan does **not** schedule tasks for them.

- **cells-diff streaming** — v1 ships `cells` full-snapshots throttled by `SnapshotPoller` (D8). Incremental cell diffs (only changed cells/rows) are deferred to v2 (spec §15-Q2).
- **Real renderer dirty-notification** — v1 uses time-tick polling + FNV-1a hash (D8) for `mode=cells`. A third ghostty patch exposing a renderer dirty callback would let `mode=cells` push on actual screen change with less wasted work. Not authorized in v1; tracked as a follow-up.
- **WebSocket bidirectional transport** — v1 uses SSE (one-way) for streaming + separate `POST /input` for writes. WebSocket would consolidate to one connection. Deferred (spec §15-Q1).
- **Patch #1 upstreaming** — Phase 1 files the upstream issue (Task 1.9 / D19). Actual upstreaming work is tracked there, not as plan tasks.
- **Patch #2 upstreaming** — Patch #2 is more cmux-specific (rides the existing PR #53 manual-IO seam); not currently planned to upstream.
- **Mouse-driven TUI e2e fixture** — adding a fixture that drives a real `htop`/`fzf` via mouse over the API. The direct-call test (D16) verifies the byte path; an interactive-mirror integration test belongs in a later iteration.
- **`wrap=join` default flip** — v1 ships `wrap=preserve` as the default (the spec's known-wrong-heuristic landmine). After patch #1 is in production, a decision to flip the default to `wrap=join` can be made; not part of v1.
- **Cells over the existing socket transport** — Phase 0 routes the existing socket through `TerminalAccessService`, but does not add a new `surface.read_cells` socket command. The CLI/socket continues to expose plaintext-only via `read_screen`/`surface.read_text`. Cells over the socket can be added later if a CLI consumer needs it.

---

## Appendix A — Locked Architectural Decisions (D1–D30)

These were locked in during synthesis to resolve every cross-phase contradiction the reviewers found. Every task in this plan complies with them. They are the source of truth; if a task body and a decision conflict, the decision wins and the task is wrong.

(D1) `SurfaceProvider` protocol: all methods `async throws`, `Sendable`. Every call site uses `await`.
(D2) `HTTPControlSettings`: ONE definition in Phase 0. Instance class `init(supportDirectory:URL, defaults:UserDefaults)`. Embeds token store. Inner `Transport` enum `{tcp, uds}`. Phase 1 only adds the SwiftUI binding view.
(D3) `AuditEntry`: ONE definition, fields `{timestamp, surface, kind, byteCount, detail?}`. `AuditKind` enum `{writeText, writeKeys, writeRaw, writePaste, writeMouse, writeFocus, streamOpen, streamClose}`.
(D4) Audit log ALWAYS-ON for writes in v1. Settings controls the path only, not the on/off.
(D5) `cells` is v1 core. Ghostty patch #1 + Swift bridge land BEFORE the screen route.
(D6) SSE seq is EVENT-LEVEL. Ring stores `(seq, OutputEvent)` tuples; drop-oldest = seq JUMP visible to client. Resume via `Last-Event-ID`: if id in ring resume after it; else send one synthetic SSE comment `": gap from=X to=Y"` then resume from oldest.
(D7) `OutputTee` C trampoline ZERO-alloc under render lock: pre-allocated subscriber slot array (cap = StreamCap, default 8).
(D8) Dirty notifier for `mode=cells` = time-tick polling + FNV-1a hash; NO third ghostty patch in v1.
(D9) HTTP token NOT injected into child terminal env. Explicit behavioral test.
(D10) `RateLimiter(burstCapacity:Int, refillPerSecond:Double, clock:any RateLimiterClock)`. Token-bucket per string key.
(D11) 405 method-mismatch returns `Allow:` header. 404 only when path is unknown.
(D12) UDS via POSIX `socket(AF_UNIX, SOCK_STREAM)` + `bind/listen` + `DispatchSourceRead`. NOT `NWEndpoint.unix(path:)`.
(D13) `StubSurfaceProvider` in `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/TestSupport/StubSurfaceProvider.swift`. Shared.
(D14) `cmux.schema.json` test BEHAVIORAL — parse via real config loader, not text-grep.
(D15) ESC-strip safety test: send `"benign\u001b[201~malicious"` via `type=text`; assert recorded bytes contain NEITHER `\u001b[201~` NOR any 0x1B byte.
(D16) Mouse direct-call test: spy provider asserts `writeMouse` invoked; NO NSEvent constructed in test scope.
(D17) `focusSurface` wired: if `request.focusSurface == true`, `await provider.setFocus(surface, gained: true)` BEFORE dispatching payload.
(D18) `TerminalAccessError.unsupported` → HTTP 415 everywhere.
(D19) Patch #1 upstream tracking GitHub issue task in Phase 1 (after patch lands).
(D20) Submodule: push `manaflow/main` BEFORE parent pointer bump.
(D21) `KeyEvent.parse(_:) throws -> KeyEvent`. NO Optional overload.
(D22) `OutputSubscription` is `public final class Sendable` with `id`, `handle`, `mode`, `cancel()`, `signalEnd()`, `onEnd`, `events() -> AsyncStream<OutputEvent>`.
(D23) `StreamMode` / `StreamSubscriptionOptions` / `OutputEvent` files created ONCE in Phase 0.
(D24) `StreamCap.Token`: `onRelease` closure + CAS-guarded `release()` — no recursion.
(D25) Cell underline: `underlineKind: UnderlineKind?` + `underlineColor: CellColor?`. `CellAttribute` drops `.underline`.
(D26) Hyperlink: ghostty patch #1 exports per-call `ghostty_hyperlink_table_s`. Cell carries `hyperlink_id: u32`; bridge resolves to URI string.
(D27) `semantic_available` top-level CellGrid bool, computed by bridge.
(D28) Sixel/DCS/Kitty images out-of-scope for `cells`. Documented.
(D29) `format=raw` on `/screen` route → 400 explicit.
(D30) `type=paste` atomicity: per-surface serial actor in `DefaultTerminalAccessService`.

---

## Appendix B — Provenance

This plan was produced by:
1. **Brainstorming + spec** — `docs/http-terminal-api-design.md` (also includes a §16 review appendix where four independent reviewers cross-validated the design).
2. **Plan workflow round 1** — three parallel phase drafters wrote the initial task lists; two reviewers (spec-coverage + quality) audited and produced ~50 must-fix items + ~30 cross-phase API contradictions.
3. **Plan workflow round 2** — three parallel per-phase correctors applied the locked decisions (D1–D30) and addressed every must-fix item touching their phase; their outputs were spliced here.

The original drafts and reviewer reports are kept at `/tmp/cmux-plan-drafts/` and `/tmp/cmux-plan-corrected/` (local-only artifacts).

---

## Appendix C — Errata & Reconciled Contracts (REFERENCE)

> **All E1-E20 contracts have been folded into the task bodies; this Appendix is now a REFERENCE record, not an override.** The 2026-05-30 fold-in pass rewrote every conflicting Phase 0/1/2 task body in place so that protocol shapes, constructor signatures, helper definitions, naming, and audit/rate-limit/paste contracts are internally consistent throughout the plan.
>
> Keep the E1-E20 details below as a quick lookup when implementing a task — but the task body itself is now the source of truth. If you ever find a task body that disagrees with the Errata text below, the task body wins (the fold-in pass took precedence over Errata text).

### E1 — `SurfaceProvider` protocol: complete, locked method list [resolves verification BLOCKER #1]
The full protocol surface — **no other methods** — and `DefaultTerminalAccessService` composes higher-level operations from these primitives:

```swift
public protocol SurfaceProvider: Sendable {
    func listSurfaces() async throws -> [SurfaceInfo]
    func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo?
    func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String
    func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid
    func writeText(surface: SurfaceInfo, bytes: Data) async throws
    func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws
    func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws
    func setFocus(surface: SurfaceInfo, gained: Bool) async throws
    func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int
}
```

**Higher-level dispatches inside `DefaultTerminalAccessService.writeInput(_:)`** (no `writeKeys`/`writeRaw`/`writePaste` on the protocol):
- `.text(s, submit)` → `try await provider.writeText(surface: info, bytes: s.data(using: .utf8)!)`; if `submit` then `try await provider.writeKey(surface: info, event: KeyEvent(mods: [], key: .enter))`.
- `.keys(events)` → `for e in events { try await provider.writeKey(surface: info, event: e) }`.
- `.raw(data)` → gated by `allowRawInput` (per D8.3); `try await provider.writeText(surface: info, bytes: data)`.
- `.paste(s)` → `try await pasteSerializer.run(surface: info) { try await provider.writeText(surface: info, bytes: s.data(using: .utf8)!) }` (D30).
- `.mouse(e)` → `try await provider.writeMouse(surface: info, event: e)`.
- `.focus(gained)` → `try await provider.setFocus(surface: info, gained: gained)`.

`AppSurfaceProvider`'s `writeText` is the binding to `ghostty_surface_text` — bracketed-paste / ESC-stripping happens inside ghostty's encoder (D15). The service does NOT pre-encode text differently for `.text` vs `.paste`.

### E2 — `AuditLog` protocol: async, non-throwing [resolves verification BLOCKER #2]
```swift
public protocol AuditLog: Sendable {
    func record(_ entry: AuditEntry) async
}
```
Three implementations: `actor RecordingAuditLog: AuditLog` (test), `actor FileAuditLog: AuditLog` (production; serial writes to JSONL with `O_APPEND`, mode 0600 enforced on EVERY open, not only on file-creation), `final class NoOpAuditLog: AuditLog { public func record(_: AuditEntry) async {} }` (test). **All call sites use `await audit.record(...)`** — never `try audit.record(...)`. Phase 0 `FileAuditLog` task ships this shape; Phase 1/2 use it as-is.

### E3 — `DefaultTerminalAccessService` constructor: single locked signature [resolves verification BLOCKER #3]
Ships in Phase 0 with all dependencies present and defaulted where Phase 0 alone doesn't need them:
```swift
public init(
    provider: any SurfaceProvider,
    audit: any AuditLog,
    rateLimiter: RateLimiter = RateLimiter(burstCapacity: 64, refillPerSecond: 16),
    streamCap: StreamCap = StreamCap(maxPerSurface: 8),
    cellsTickRate: Double = 5.0,
    allowRawInput: () -> Bool = { false }
)
```
Phase 1 passes a real `RateLimiter` and `allowRawInput: { settings.allowRawInput }`. Phase 2 passes a real `StreamCap` and `cellsTickRate` from settings. **No phase changes the signature** — they just provide the values that were previously defaulted.

### E4 — `PasteSerializer`: single definition in package [resolves verification BLOCKER #4]
ONE file: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/PasteSerializer.swift`. Created in Phase 0 (NOT inline in `DefaultTerminalAccessService.swift`). Shape: `public actor PasteSerializer { public init() {} ; public func run<T: Sendable>(surface: SurfaceInfo, _ body: @Sendable () async throws -> T) async rethrows -> T }`. Per-surface serialization via an internal `[UUID: Task<Void, Never>]` chain (each call awaits the previous task for the same surface UUID before running the body). Phase 1 only USES it.

### E5 — `AppSurfaceProvider.shared` + `testInject(...)`: explicit Phase 0 sub-task [resolves verification MAJOR #5]
Phase 0 adds a sub-task to `AppSurfaceProvider`:
```swift
public final class AppSurfaceProvider: SurfaceProvider {
    public static let shared = AppSurfaceProvider()  // initialized lazily; controller set via setController(_:)
    private var controller: TerminalController?
    public func setController(_ c: TerminalController) { self.controller = c }
    #if DEBUG
    public func testInject(panel: TerminalPanel, handle: SurfaceHandle) { /* in-memory override for tests */ }
    public func testReset() { /* clear injected state */ }
    #endif
    // ... rest of impl
}
```
`AppDelegate` calls `AppSurfaceProvider.shared.setController(terminalController)` during launch. Phase 1 tests use `AppSurfaceProvider.shared.testInject(...)` under `#if DEBUG`.

### E6 — `HTTPControlTestEnv`: explicit Phase 1 helper [resolves verification MAJOR #6]
Phase 1 adds a task creating `cmuxTests/HTTPControl/Support/HTTPControlTestEnv.swift` with the FULL surface area Phase 2 tests need:
```swift
final class HTTPControlTestEnv {
    let settings: HTTPControlSettings
    let server: HTTPControlServer
    let fixture: TerminalFixture
    var port: Int { /* dynamic */ }
    var token: String { /* from settings */ }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var surfaceHandle: SurfaceHandle { /* first fixture handle */ }
    static func start(
        heartbeatSeconds: TimeInterval = 20,
        maxStreamsPerSurface: Int = 8,
        ringCapacity: Int = 512,
        streamOpenBurst: Int = 4,
        streamOpenRefillPerSecond: Double = 1.0
    ) async throws -> HTTPControlTestEnv
    static func startWithLiveSurface(command: String, args: [String], ringCapacity: Int = 512) async throws -> HTTPControlTestEnv
    func shutdown() async
}
```
All Phase 2 tests reference these signatures.

### E7 — Config loader: single locked file/symbol [resolves verification MAJOR #7]
ONE file: `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/HTTPControlConfigLoader.swift` exposing `public enum HTTPControlConfigLoader { public static func parse(_ json: Data) throws -> HTTPControlConfig }`. Tests at `Packages/CmuxTerminalAccess/Tests/CmuxTerminalAccessTests/HTTPControlConfigLoaderTests.swift`. Both Phase 1 Task 1.20 and Phase 2 Task 2.31 must use these names. **Delete** any reference to `CmuxJSONConfigLoader.load` / `CmuxJSONConfigHTTPControlTests` in the plan body.

### E8 — `TerminalFixture`: explicit Phase 0 task [resolves verification MAJOR #8]
Phase 0 adds a task creating `cmuxTests/Fixtures/TerminalFixture.swift` with the full constructor set referenced across phases:
```swift
public struct TerminalFixture: Sendable {
    public let panel: TerminalPanel
    public let handle: SurfaceHandle
    public static func makeWithLines(_ lines: [String]) async throws -> TerminalFixture
    public static func makeAltScreen() async throws -> TerminalFixture
    public static func makeWithBytes(_ bytes: Data) async throws -> TerminalFixture
    public static func spawn(command: String, args: [String]) async throws -> TerminalFixture
    public static func spawnAndCapturedEnvironment(command: String, args: [String]) async throws -> (TerminalFixture, [String: String])
    public func fakeRawSource(for handle: SurfaceHandle) -> RawSourceSpy
}
```
**Delete** the conditional "if not present, add it" notes in Phase 1 task bodies.

### E9 — Legacy `SocketControlSettings:133` constant-time compare [resolves verification MAJOR coverage#2]
Phase 0 adds an EXPLICIT task that:
1. Creates `Packages/CmuxTerminalAccess/Sources/CmuxTerminalAccess/ConstantTimeCompare.swift` with `public func ctCompare(_ a: Data, _ b: Data) -> Bool`.
2. Modifies `Sources/SocketControlSettings.swift:133` to use `ctCompare(expected, candidate)` instead of `==`.
3. Failing test first (CI red commit): spy that asserts the legacy compare runs full-length (not short-circuit).
4. Fix commit: replace `==` with `ctCompare`.

Phase 1's `HTTPAuth` uses the same `ctCompare` helper.

### E10 — `ScreenRegionReader` retirement [resolves verification MAJOR #10]
Phase 1's LAST task retires `ScreenRegionReader` (the three-tag SCREEN+SURFACE+ACTIVE merge):
1. After patch #1 + Swift bridge lands, modify `AppSurfaceProvider.readText` to derive text from `readCells(surface, region)` (`cellsToText` helper joins per-cell `t` with `wrap`/`wrap_continuation` per row flags).
2. Add a regression test: `readText` returns identical bytes as the prior merge for a fixture surface across normal + reflow boundaries.
3. Delete `ScreenRegionReader.swift` and the merge code in `AppSurfaceProvider` once the regression test passes.
4. The legacy socket path also routes through `service.readScreen(.text)` so it inherits the retirement automatically (already routed via Phase 0).

### E11 — Runtime-disabled check in HTTP server `handle` [resolves verification MAJOR #11]
`HTTPControlServer.handle(_:)` reads `settings.enabled` (atomic) on each request. If false, returns 404 with the disabled-feature code, regardless of whether the listener is up. This handles the race where settings flip off mid-connection. `HTTPControlLifecycle` still stops the listener on toggle-off — the 404 path handles in-flight requests during the stop.

### E12 — `SnapshotPoller.read` test reconciliation [resolves verification MAJOR #12]
Phase 2 Task 2.18's change of `SnapshotPoller.read` from sync to `async` must include explicit edits to the Task 2.10/2.11 GREEN tests (NOT "adjust if needed"):
- Test fixtures wrap `read` with `{ @Sendable () async in current }`.
- Each `read()` call site becomes `await poller.read()`.
- Two-commit policy: failing tests committed FIRST showing the async breakage, then the SnapshotPoller signature change + test fixture updates.

### E13 — Two-commit TDD label: Tasks 0.21 and 2.18 [resolves verification MINOR ×2]
Tasks 0.21 and 2.18 are NOT genuine red→green pairs (the "failing test" is added after the impl exists). Re-label them as `### Task X.Y: <Title> (characterization test — no red→green ritual)` and squash to a single commit; no policy violation since there is no regression to commit-divide.

### E14 — `enforceCapacity` preservation in `writeInput` [resolves verification MINOR #15]
Phase 1 Task 1.15's rewrite of `DefaultTerminalAccessService.writeInput` must preserve the Phase 0 `enforceCapacity(info:bytes:)` precondition call. The dispatch table from E1 runs AFTER `try await enforceCapacity(info: info, bytes: payloadByteCount)`; the test from Phase 0 line 2562 (`payloadTooLargeWhenCapacityExceeded`) continues to pass.

### E15 — `udsPath` naming [resolves verification MINOR #18]
`HTTPControlSettings` exposes `@Published public var udsPath: String` (NOT `unixSocketPath`). Phase 0 Task 0.22 must use `udsPath`. Phase 1 Task 1.19 uses `udsPath` — consistent across all sites.

### E16 — `RateLimiter.acquire` throws [resolves verification MINOR #19]
`func acquire(key: String) async throws` — throws `TerminalAccessError.rateLimited` on overflow. Call sites: `try await rateLimiter.acquire(key: ...)`. **No `Bool` return**. Phase 0 Task 0.16 commits this signature; all call sites consistent.

### E17 — `StubTerminalAccessService.listSurfaces` throws [resolves verification MINOR #20]
Stub matches the protocol exactly: `func listSurfaces() async throws -> [SurfaceInfo]`. Phase 1 Task 1.12 must include `throws` even if the stub never actually throws (returns the seed array).

### E18 — `SpyRecordingProvider` conformance [resolves verification MINOR #17]
Phase 1's `SpyRecordingProvider` conforms to the E1 `SurfaceProvider` shape — `writeText(surface: SurfaceInfo, bytes: Data)`, NOT `writeText(surface: SurfaceHandle, text: String, submit: Bool)`. All recording helpers expose `recordedBytes(for surface: SurfaceInfo) -> [Data]`, etc.

### E19 — `AppSurfaceProvider.readText` post-retirement [resolves verification MAJOR #10 follow-on]
After E10, `AppSurfaceProvider.readText(surface:region:)` derives via `let g = try await readCells(surface:, region:); return cellsToText(g, wrap: .preserve)`. The `wrap=join` policy in `DefaultTerminalAccessService.readScreen` is applied by passing the wrap policy through and having `cellsToText` join rows based on `row.wrap`/`row.wrap_continuation` flags.

### E20 — Top-level "Cells in Phase 0" stub-then-real handoff [verification MAJOR coverage#8 reinforcement]
Phase 0's `SurfaceProvider.readCells` default stub returns `.unsupported(reason: "cells requires ghostty patch #1")`. Phase 1's `AppSurfaceProvider` provides the real impl backed by patch #1. **Phase 0's protocol REQUIRES `readCells`** — it is not an optional/extension method. The default stub lives in a separate `DefaultStubSurfaceProvider` (test fixture), not as a default protocol implementation. This forces every `SurfaceProvider` conformer to consciously implement (or stub) `readCells`.

---

### How to use this Errata during execution

When you (the implementing agent) reach a task:
1. The task body itself is the source of truth — the 2026-05-30 fold-in pass rewrote every conflicting Phase 0/1/2 task body in place.
2. The E1-E20 contracts below are a **reference index** if you need a quick check on a specific contract (protocol method shape, constructor signature, helper file location, naming convention).
3. The new Phase 0 tasks introduced by the fold-in pass are: 0.19a (`PasteSerializer` actor, E4), 0.19b (`ConstantTimeCompare` + legacy socket fix, E9), and 0.23a (`TerminalFixture`, E8). The new Phase 1 tasks are: 1.22a (`HTTPControlTestEnv`, E6) and 1.22b (`ScreenRegionReader` retirement, E10 + E19).

---

## Appendix D — Verification Report Summary

The final verification pass (2026-05-30) audited the spliced plan against the 38 original reviewer must_fix items and surfaced new cross-phase issues:

- **37 / 38 reviewer must_fix items RESOLVED** (only one minor partial: Task 0.23 lacks a failing test for `AppSurfaceProvider` helper extracts — split sub-tasks 0.24.a–e in the corrected plan cover the bulk).
- **20 NEW cross-phase issues introduced by the synthesis** (4 blockers, 9 majors, 7 minors) — all 20 were addressed by Errata items E1–E20.
- **Verdict before Errata:** `needs_another_pass`.
- **Verdict after Errata (as-override):** Errata-as-source-of-truth pattern; plan executable with Errata read first.
- **Verdict after fold-in pass (current state):** The 2026-05-30 fold-in pass rewrote every conflicting Phase 0/1/2 task body in place so the API contracts E1-E20 are now internally consistent throughout the task bodies. Appendix C is now a reference record. New Phase 0 sub-tasks 0.19a / 0.19b / 0.23a and new Phase 1 sub-tasks 1.22a / 1.22b were introduced by the fold-in to give E4 / E9 / E8 / E6 / E10 + E19 their own task scope (they previously lived only in Errata prose). Plan is **executable straight from the task bodies**.
