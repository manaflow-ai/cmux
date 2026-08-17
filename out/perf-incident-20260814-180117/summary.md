# iOS terminal render freeze incident

Symptom: Terminal pixels intermittently stop updating during ordinary cmux use on iOS.
User impact: The terminal appears frozen and can no longer be trusted to show current output.
Source: User report on 2026-08-14, prior freeze PRs, and current open fix PR https://github.com/manaflow-ai/cmux/pull/10125.
Target surface: iOS terminal renderer and its Mac-to-iOS output pipeline.
Build/version/tag: Reported build unknown. Candidate cmux head is `d3e47dcabf`; the verified runtime overlays Ghostty `3da10da73ae848c0310e3e0f0cb29e509c2f6963` under tag `iosfrz`.
Repro workload: Active terminal output plus local scroll, geometry changes, foreground/background transitions, replay, reconnect, and surface remount.
Expected bad behavior: A frame, replay barrier, output consumer, or viewport transaction remains unresolved, so visible pixels stay stale while later work is blocked or hidden.

## Repeatable workload

1. Attach an isolated iOS Simulator to a same-tag macOS host.
2. Generate deterministic terminal output while exercising scroll, viewport resize, background/foreground, and surface remount transitions.
3. Record transport receipt, output application, render submission, Ghostty disposition, presentation, and replay reveal.
4. Fail if output advances without a corresponding current-generation presentation, or if any gate remains armed after its owner reports discard/failure/teardown.

Stop condition: The same workload completes with every admitted frame reaching a terminal disposition and newer work remaining deliverable.

## Candidate owner boundaries

- Mac producer and event queue: frame emission, subscriber lifetime, and backpressure.
- iOS output consumer: stream lifetime, chunk serialization, replay admission, and continuity.
- Viewport scheduler: generation changes, stale acknowledgements, and resize cancellation.
- Terminal surface: mount ownership, scroll generations, render submission, and teardown.
- Ghostty renderer: submitted-frame disposition and Metal presentation callback.
- Visibility lifecycle: foreground/background and verified-replay snapshot reveal.

## Existing evidence

- https://github.com/manaflow-ai/cmux/pull/7098 added recovery for render pipeline stalls.
- https://github.com/manaflow-ai/cmux/pull/7666 fixed a surface teardown deadlock.
- https://github.com/manaflow-ai/cmux/pull/8106 made verified replay atomic until presentation.
- https://github.com/manaflow-ai/cmux/pull/9146 fixed a replay loop caused by missing history continuity and added latency tracing.
- https://github.com/manaflow-ai/cmux/pull/10125 identifies discarded tokened render submissions as an unresolved terminal-disposition gap.

## Root causes and fixes

The primary freeze was a missing terminal disposition. Ghostty could accept a tokened frame and later discard it after a layer-size or generation change without notifying cmux. The iOS presentation gate retained that impossible token, so every newer frame remained queued behind stale pixels. Ghostty now gives every accepted tokened frame exactly one terminal outcome: presented, discarded, or backend-failed. cmux replaces discarded current-generation work, resolves failed work immediately, and bounds all retries.

The audit found additional independent stalls in the same end-to-end path:

- A finished `AsyncStream` left its non-nil consumer task attached to a still-mounted UIKit surface. Mount ownership now reclaims and generation-guards finished consumers.
- One malformed verified chunk returned from the consumer, ending all later delivery. It now drops only that chunk.
- Replay could start while prior output was still applying, lose an ordinary dirty frame under suppression, or reveal old pixels when a re-fence failed. Replay now waits for an idle delivery queue, retains suppressed dirty work, and reveals only after the matching current-generation presentation.
- Local-scroll drain and its continuation could remain unbounded during momentum or after its producer vanished. Scroll work is generation-owned, bounded, and released on reset.
- Prompt scroll-to-bottom blocked the output queue on Ghostty's state lock. It is now a non-blocking attempt retried by the display pump.
- Detach, foreground restoration, geometry replacement, backend failure, and watchdog recovery could leave stale presentation ownership. They now reset exact generations and resolve every pending token.
- Ghostty's asynchronous request path could accept tokened work in iOS/external-drain mode even though no renderer consumed it. That path now rejects synchronously, preserves explicit callback userdata, and releases the delivery gate even when no failure callback is installed.

## Verification

- Focused state-machine coverage passes for terminal presentation gating, verified replay, mount ownership, and output delivery.
- The Ghostty framework built from source, its focused disposition tests passed, and release checksum `6a02a2ec3794de79a02af993083292a89517d2533eb20c746deca377f23456bd` validated after download.
- The tagged macOS cloud build passed and the main-thread Core Animation transaction verifier passed.
- Isolated simulator `cmux-iosfrz-verify` (`692208EC-FAEA-46F7-BAAD-E51B0DEDA30D`) completed 200 forced recovery, output, resize, and surface-free cycles with every pending free drained. No heartbeat or free-drain deadline fired.
- The bottom-scroll harness deliberately produced `render.callback_failed token=2 status=1`, proving the formerly silent discard reached cmux. Rendering recovered and remained live through `bottom-scroll-repro line 260`; screenshot: `/Users/abdulazizalbahar/Dev/Manaflow/cmuxterm-hq/cmux-assets/issue-terminal-scroll-refresh/preflight/bottom-scroll.png`.
- The isolated simulator and Aziz (`4A52829D-6427-599F-A166-4058881D2DF4`) both passed signed-in plus paired usable-RPC readiness for tag `iosfrz`.
- Sentry searches over 90 days found no matching iOS hang, watchdog, terminal-freeze, or ANR issue, consistent with a render-only stale-pixel failure rather than an app-wide stall.

The first hosted replay UI run stopped before tests because the remote cmux head still pins the unmerged Ghostty dependency and lacks that dependency's checksum. Merge Ghostty PR https://github.com/manaflow-ai/ghostty/pull/200, commit the already-validated pointer and checksum, then rerun the same hosted test before merging cmux PR https://github.com/manaflow-ai/cmux/pull/10125.

Residual risk is an unobserved field-only interleaving. The audited pipeline now gives each asynchronous owner a terminal state and a bounded recovery deadline, so a future unknown path should recover instead of freezing indefinitely.
