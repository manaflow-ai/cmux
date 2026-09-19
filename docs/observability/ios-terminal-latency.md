# iOS terminal latency

The iOS app records bounded timing samples locally and sends one `ios_terminal_latency_window` event per active surface every ten seconds through `/api/observability/mobile-network`. It also flushes on background. Ordinary output, without typing, contributes rendering samples. No key text, terminal content, surface identifiers, or input markers enter these events.

## What the measurements mean

- **Input dispatch to received output:** from a submitted input batch to the first delivered output whose cumulative watermark acknowledges it. Earlier waiting batches are included when one output acknowledges several inputs. The measurement includes network, Mac queueing, and program execution. The Mac accepting input does not prove that input caused the output.
- **Input dispatch to visible:** the same start, ending at the renderer's confirmed presentation.
- **Output receipt to visible:** from admission into the iOS output queue to confirmed presentation, including queueing, application, and rendering.

Inputs use opaque, session-randomized, increasing markers. Capable hosts advertise `terminal.input.latency.v1`; marked input frames preserve the existing ordered stream, and legacy peers keep their original framing. RPC input carries the same marker. A host echoes a marker only after accepting input. Every input contributes at most once to each timing distribution. Missing output expires as missing coverage, not a latency incident.

Measurements currently cover delivered render-grid output correlation. Older/raw-byte-only hosts still contribute rendering timings but may have no input correlation. Input batching before dispatch is outside the timing boundary. Queue acknowledgment is not counted as a visible presentation. App suspension, inactive scenes, and redraws without new output are excluded.

## Volume and controls

The reporter retains at most 16 surfaces and 512 pending markers per surface. Histograms have 17 fixed buckets, with upper bounds 1, 2, 4, ..., 32768 ms and a final overflow bucket displayed at 60000 ms. `histogram_version=1` fixes this schema. The dashboard sums buckets before computing approximate p50/p95/p99, so busy and quiet windows are weighted by sample count.

Windows also report input/output counts, failed sends, presented outputs, correlated inputs, output bytes, peak pending output queue, and output resets. App/build/bundle/OS/device metadata comes from the existing telemetry composition. The authenticated server assigns account identity. Existing consent, bounded queues, and upload failure behavior apply.

PostHog flag `ios-terminal-latency-enabled` defaults on and can stop collection remotely. Disabling clears pending samples and cancels the timer. No per-frame network or disk work is added.

## Live-path traces (local diagnosis)

The diagnostic spine also records per-event breadcrumbs for the live typing
path: a `liveInput` trace per marked input batch (dispatch, send settlement,
watermark echo, on-screen presentation, each stamped with milliseconds since
dispatch) and `liveFrame` records for delivered frames, including every gate
discard with its reason (stale sequence, behind pending input, replaced,
overflow). Ordinary sessions keep the default 120-per-minute trace cap and
sample frames one-in-eight; discards are always recorded.

For an explicit local diagnosis session, launch the app with
`CMUX_TERMINAL_TRACE_VERBOSE=1` (or set the `cmux.debug.terminalTraceVerbose`
user default) to raise the cap and trace every frame while a typed input is
still unacknowledged. Reproduce the latency, then export the timeline from
Settings > Diagnostics and summarize it with
`scripts/terminal-live-trace-report.py <export.txt> [/tmp/cmux-debug-<tag>.log]`,
which prints per-keystroke waterfalls, stage percentiles, discard counts, and
the dominant stage. Traces carry only opaque markers, sequence numbers, and
surface handles, never key text or terminal content.

## Incidents and dashboard

Axiom receives slow-response observations at 1000 ms, and rendering observations after three consecutive presentations at or above 250 ms. Each stage is limited to one anomaly per surface per minute. Only sustained rendering lag goes to Sentry through the existing incident policy (ten-minute signature cooldown and shared hourly budget). Rendering incidents do not advance the connectivity outage streak.

The internal admin sidebar has **iOS → Connectivity / Latency**. Latency includes weighted timing percentiles, correlation volume, recent minute buckets with queue pressure and failures, and the latest spike observations. Missing samples remain missing. The dashboard uses its existing authenticated Axiom reader and five-minute query cache. `AXIOM_CONNECTIVITY_DATASET` selects the backend dataset; use the exact app bundle filter to isolate a tagged soak.
