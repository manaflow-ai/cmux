# iOS Feed performance

Feed telemetry measures scroll callback pacing and Feed-update work. It does
not establish the root cause of visible stutter, measure rendered FPS, or
replace an Instruments Animation Hitches trace on a physical device.

## Collection and rollout

Deploy the authenticated `/api/observability/mobile-network` schema before
enabling PostHog `ios-feed-performance-release`. The flag defaults off; a
successful remote evaluation updates it live and caches the result. Turning
it off clears pending measurements and stops sampling. The existing anonymous
telemetry setting gates both Axiom and Sentry, including mid-session opt-out.

The client sends one `ios_feed_performance_window` per active ten-second
window, plus a partial window when Feed becomes hidden or the app goes
inactive. Empty windows produce no event. No per-frame network requests,
logging, row identifiers, Feed text, prompts, search terms, or URLs are sent.
The server attributes accepted batches to the authenticated account, validates
a strict schema, and emits `cmux.mobile.feed.performance` spans through the
existing Axiom exporter. These spans carry measurements in attributes; their
server-side span duration is ingestion work, **not scroll latency**.

On iOS 18+, a default-cadence `CADisplayLink` runs only during native Feed
interaction or deceleration. Its actual callback arrival intervals populate
`callback_gap_histogram`; the requested interval populates
`callback_budget_histogram`. The first callback after each scroll boundary is
excluded. Idle, hidden, and suspended time cannot bridge two samples. iOS 17
has update timings but no scroll callback samples. Missing samples are not a
zero-stutter result.

All histograms use schema version 1: ten noncumulative buckets with upper
bounds **8, 12, 17, 25, 34, 50, 100, 250, 1000, 60000 ms**. The last bucket
also contains overflow; maxima and individual durations cap at 60000 ms.
Sum bucket counts across windows before calculating approximate percentiles.
Never average per-window percentiles. `gaps_over_50ms / callback_count` is a
callback-gap fraction, not Apple's animation hitch ratio.

| Field family | Boundary |
| --- | --- |
| `fetch_*` | Successful `feed.list` request, including transport and host work |
| `decode_*` | Worker scheduling, decode, and return to the shell actor |
| `apply_*` | Synchronous snapshot application attempt, including revision checks and merged model projection |
| `projection_*` | Row preparation through publication, excluding search debounce |

Cancelled/obsolete projection results do not count as published work. Fetch
and decode timings omit requests cancelled or replaced before the response
reaches the shell actor. Update intervals spanning Feed visibility or
app-activity boundaries are excluded. `apply_*` includes attempts rejected by
revision checks; `updates_while_scrolling` counts those attempts during a
scroll. Stage counts therefore do not measure the same population. Apply item
counts describe the merged Feed across Macs, while fetch/decode counts describe
the response from one Mac. These are workload signals, not counts of active agents. Item counts
are bounded at 10000. Window IDs are random and contain no row/session IDs.

## Axiom comparisons

Use [the comparison query](ios-feed-comparison.apl) with the configured traces
dataset. The checked-in default is `cmux-prod-otel-traces`; substitute the dev
dataset for simulator experiments. Filter to the exact bundle, build, time
range, and workload before drawing conclusions. Signed bundle SHA is included
when present, alongside app version/build, OS, device category, simulator flag,
and observed cadence distribution. `device_model` currently identifies the
Apple device category, not its precise hardware model. Device category and
callback-budget histograms are available on individual events but are not
returned by the comparison query; query those separately when separating
device categories or 60/120 Hz populations.

Keep simulator and device observations separate. Compare repeated runs with
the same retained Feed, agent activity, scroll input method, and sampling
configuration. Inspect callback-budget histograms when comparing 60/120 Hz
populations. The comparison query returns summed buckets, callback count,
observed scroll time, >50/>100 ms gaps, worst gap, and update activity by build.
For p95/p99, find the first cumulative bucket reaching 95%/99% of the summed
callback count; the bucket bound is an upper-bound estimate.

The [incident query](ios-feed-incidents.apl) finds a window's numeric context
and its optional Sentry event ID. For later releases, save a comparison chart
grouped by build and OS, and a daily trend grouped by client observation time.
Require sufficient callbacks/scroll time before alerting on a regression.
The repository provides queries; creating a hosted dashboard or alert and
enabling the production flag are separate rollout actions.

## Sentry and privacy

A window containing a callback gap above 100 ms can produce a nonfatal Sentry
event, at most once per minute per app instance. The bridge waits until
scrolling settles and sends a constant message/fingerprint plus four fields:
window ID, worst gap, callback count, and item count. Axiom's
`ios_feed_scroll_anomaly` carries the same window ID and the returned Sentry
event ID. Both the Axiom anomaly record and Sentry bridge share the one-per-
minute limit and are suppressed when the app becomes inactive. Count stalls
from performance windows, which retain the gap counts and maxima even when
no anomaly record is emitted. Search the `cmux-ios` project for `feature:feed` and
`measurement:display_link_callback_gap`, or paste that event ID into Sentry.
An SDK event ID is a lookup key, not an upload receipt.

Replay retains its existing 10% session / 100% error sampling, low quality,
all-text/all-image masks, and disabled touch/network capture. The full Feed,
reply composer, and full-text sheet have explicit rectangular masks;
terminal/browser/simulator/camera masks remain required. Missing any required
class disables replay. The transparent mask views do not intercept touches.

Feed scrolling uses the existing replay-pause hook, because replay screen
capture itself can occupy the main thread. Therefore replay can show masked
context before and after a stall; it cannot show every scrolling frame or
prove smoothness. Replays may be absent because of sampling, test-run gating,
consent, backgrounding, or delivery failure. Unit/UI-test launches do not send
Sentry reports. Do not bypass that protection to populate a dashboard.

Before enabling broadly, run a tagged dev build with synthetic private text in
Feed, composer, and full-text sheet. Audit Sentry's local mask preview and the
resulting replay on supported iOS versions; confirm no content pixels escape.
Repeat scroll profiling with the flag off/on to measure the observer's cost.
Verify an opted-in numeric window reaches the dev Axiom dataset, its correlated
Sentry event resolves when available, and opt-out stops both paths. Production
delivery and a visual replay-mask audit are separate from parser/unit tests.

References: [Apple scroll-view guidance](https://developer.apple.com/design/human-interface-guidelines/scroll-views),
[Sentry replay overhead](https://docs.sentry.io/platforms/apple/guides/ios/session-replay/performance-overhead/),
[Sentry custom redaction](https://docs.sentry.io/platforms/apple/guides/ios/session-replay/customredact/),
[Axiom aggregation](https://axiom.co/docs/apl/tabular-operators/summarize-operator).
