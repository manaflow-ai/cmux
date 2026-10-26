# Opt-in hang reports from cmux NEXT Nightly

Status: design and v1, 2026-10-23. Owner: PL-telemetry (Performance Lead). Branch `feat-cmux-next`
(app), `main` (web route, table, script).
Lawrence (2026-10-23): "collect opt-in hang reports from nightly users. Make sure to redact privacy
stuff."

Related: `perf-lead.md` (the lab numbers these reports check in the field),
`hang-reports-privacy-policy-DRAFT.md` (the privacy policy change; legal step, not published),
`CmuxNextControl/Diagnostics/MainThreadWatchdog.swift` (the in-process detector),
`CmuxNextCrashReporting` (Sentry crash reports: a separate, opt-out channel this does not change).

## 1. What the person sees

- Off by default, on every channel. Only NIGHTLY builds (`com.cmuxterm.app.nightly`, tagged
  nightlies too) ever send. Other channels keep the setting and send nothing.
- `diagnostics.hangReports` (cmux-next.json, boolean, default `false`). Settings > Privacy and
  Security > Hang Reports has the switch, and the category ends with a **View Hang Report** button. `cmux settings set
  diagnostics.hangReports true --confirm` and the palette's Toggle Setting write the same key
  through `SettingsController.setSetting` (one write path). The key is agent-refused
  (`AgentRefusal.privacy`): an agent cannot turn it on without the person's confirmation sheet.
- Consent is per Mac (`HangReportAskPolicy`). cmux-next.json is synced between Macs and agents
  can edit it, so the setting alone never sends: this Mac also needs its consent record
  (`cmux.next.hangReports.consentedAt` in the app's defaults), which the app writes only from
  the person's own yes: the card's Send Hang Reports, or a `SettingWriter.user` write of the key
  (`SettingsController.userWillWrite`: the Settings switch, Toggle Setting, a CLI call the
  confirmation sheet approved; the hook runs before the file write and its undo takes the
  record back if the write fails). So Not Now on the invitation, then the switch in the same
  launch, sends with no second card. Sending also stops when the record goes while cmux runs. It is a guard against a synced or agent-edited
  file, not against a process of the same user (`defaults write` can set it; so can any program
  that can already read the user's files). Each send also re-reads the managed
  `DisableTelemetry` (a profile installed while cmux runs stops sending and drops what was
  recorded), and a queued report from another build, or one today's leak scan refuses, is
  dropped, never sent. A file that turns reports on without it shows the confirm
  card and sends nothing. Turning reports off (or a managed `DisableTelemetry`, read once per
  launch) removes the record, the queued reports and the install id. MetricKit payloads that
  began before the consent time are dropped (MetricKit hands over kept payloads at the first
  subscription).
- The one-time invitation is never shown to a person who turned off anonymous telemetry
  (`sendAnonymousTelemetry`; lead decision 2026-10-23); they can still turn reports on in
  Settings (their own write records the consent; no card). The invitation: a sidebar notice card (`SidebarAsks`, the same card as an agent's
  Cloud machine request; no dialog, no sheet) with **Send Hang Reports** and **Not Now**. Either
  answer, or the x, records that it was asked (`cmux.next.hangReports.asked` in the app's
  defaults); it never shows again. The card waits for the first window and never takes focus.
- **View Hang Report** (`diagnostics.viewHangReport`, palette, Settings button, `cmux settings
  view-hang-report`) opens the exact JSON of the last report sent, in a cmux file tab. Before
  any report was sent it opens a preview: what would be sent now.

## 2. Sources

| Source | What we take | Cost |
|---|---|---|
| MetricKit `MXHangDiagnostic` | hang duration, main-thread call stack | none: the OS records it; delivered to our subscriber (at most daily, diagnostics usually at the next launch) |
| MetricKit `MXCPUExceptionDiagnostic` | total CPU and sampled time, heaviest call stack | none |
| MetricKit `MXAppLaunchMetric` | time-to-first-draw, resume, optimized and extended launch histograms | none |
| MetricKit `MXAppResponsivenessMetric` | hang-time histogram | none |
| MetricKit `MXAnimationMetric` | scroll hitch ratio, hitch ratio (macOS 26) | none |
| MetricKit `MXSignpostMetric` | duration histograms and hitch ratio of allowlisted Release intervals (below) | none: aggregated by the OS |
| `MainThreadWatchdog` (in process) | each finished stall over 50 ms into a duration histogram; the stacks of the 8 longest stalls of 250 ms and more; each 2 s hang's stack | one lock and a few integer adds per finished stall, on the stall's own end; nothing while the app is idle |
| `InputLatencyReporter` field report (in process, p04-input-010; schema 3) | input latency histograms per kind, target, entrypoint, presentation source and display (refresh rate, whether it varies); Chrome's scroll jank counts | while on, a second `InputLatencyLedger` folds the same closed-slot batches on the reporter's utility reader; nothing on the main thread, nothing while idle |

`MXAppLaunchDiagnostic` is iOS only (`API_UNAVAILABLE(macos)` in the macOS 26 SDK): launch on
the Mac is the launch metric histograms plus watchdog stalls during launch.

**Release intervals.** PL-arch's always-on catalog (`CmuxNextSignposts`, subsystem
`com.cmuxterm.app.next`: `action.perform`, `action.commit`, `motion.frame`, `key.frame`,
`switch.workspace`, `switch.tab`, `create.tab`, `cef.pump`, ...) emits `OSSignposter` intervals,
which MetricKit does not see: it aggregates only `mxSignpost` intervals on a log from
`MXMetricManager.makeLogHandle(category:)`. While hang reports are on, the catalog mirrors each
interval's begin and end (name only, no message) to that log, so MetricKit hands back a duration
histogram per name. A report includes an interval only when its category is in
`HangReportSignposts.categories` (`action`, `motion`, `key`, `switch`, `create`, `cef`, `launch`;
not `stall`) and its name matches `[a-z0-9_.-]{1,48}`; histograms only, never one event.

## 3. Redaction (privacy first)

The report is built by allow-list: `HangReportBuilder` copies only the fields in section 4
from typed inputs. Nothing from a MetricKit payload passes through as text; the call stack JSON
is read for five keys (`binaryName`, `binaryUUID`, `offsetIntoBinaryTextSegment`, `sampleCount`,
`subFrames`) and the rest is never read.

Sent: call-stack frames as (image name, image UUID, offset), app version and build, channel,
macOS version (major.minor.patch), hardware class (architecture, chip family, core count,
memory rounded to a standard size), durations, coarse counts (windows, workspaces, panes, tabs,
each a bucket: `0`, `1`, `2-5`, `6-10`, `11-30`, `31-100`, `101+`), the UTC day.

Never sent: file paths, user names, the home folder, URLs, page titles, terminal text, window
titles, workspace names, host names, IP addresses, environment variables, emails, tokens,
clipboard, chat content, process command lines, locale or region, process ids, exact times.

**Frames.** An image is kept by name only when it is ours or Apple's:
- ours: an image loaded from inside the running app bundle (the executable, its frameworks,
  helpers), or a name in our own list (`cmux*`, `CmuxNext*`, `GhosttyKit`, `Chromium Embedded
  Framework`, `Sparkle`, `Sentry`);
- Apple's: an image loaded from `/System/`, `/usr/lib/` or the dyld shared cache.

Every other image (an input method, a plug-in, an injected library, anything under a home
folder or `/Applications/Other.app`) becomes `{"image": "other"}` with no UUID and no offset.
A kept name is the last path component, must match `[A-Za-z0-9 ._+()-]{1,64}`, and must not
contain the user's short or full name. MetricKit frames are classified by matching their UUID
against the images loaded now; an unknown UUID with a name in neither list is `other`.

**Last check.** `PrivacyLeakScanner` walks every string of the encoded report and refuses the
whole report when one looks like a path (`/`, `~`), an email, a URL (`://`), an IP address, the
user's name or home folder, the host name, or a token (long base64/hex runs other than a UUID).
A refused report is not sent and not stored; the refusal is logged as a count.

**Identity.** `installId` is a random UUID made on this Mac, replaced every 30 days
(`InstallIdentity`), never derived from the hardware, the account or the Sentry id. No account,
cookie or device token is sent. The request carries fixed headers only (`User-Agent:
cmux-hang-reports/1`, `Accept-Language: en`, `Accept: */*`, `Content-Type`), never URLSession's
own language list. The route stores no IP address and logs none (section 5), but the client IP
reaches Vercel's edge, its request logs and the firewall rate limit like any HTTPS request; the
privacy text must say so.

Unit tests (`CmuxNextHangReportsTests`) feed realistic MetricKit call stack trees and watchdog
samples with planted paths (`/Users/alice/...`, an input method under `~/Library`), emails,
URLs, host names, tokens and environment text, and check that no planted string appears in the
encoded report, that third-party frames lose their name, UUID and offset, and that the scanner
refuses a report that carries one.

## 4. Wire format (schema 2; schema 3 adds blocking sites)

`POST https://cmux.com/api/hang-reports`, `content-type: application/json`, body at most 64 KiB,
user agent `cmux-hang-reports/1`. Answers: `204` stored (or a duplicate `reportId`), `400`
invalid, `413` too large, `429` rate limited (`retry-after`). The client keeps a failed report
in its outbox (at most 3, at most 14 days) and tries again at the next trigger.

```json
{
  "schema": 2,
  "reportId": "5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11",
  "installId": "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20",
  "day": "2026-10-23",
  "app": {"version": "0.70.0", "build": "2123456789012", "channel": "nightly"},
  "os": {"version": "15.7.4"},
  "hardware": {"arch": "arm64", "chip": "Apple M4 Pro", "cores": 14, "memoryGB": 48},
  "counts": {"windows": "1", "workspaces": "11-30", "panes": "6-10", "tabs": "31-100"},
  "hangs": [
    {"source": "metrickit", "kind": "hang", "durationMs": 2340, "cpuMs": null,
     "frames": [{"image": "AppKit", "uuid": "8B1E...", "offset": 1234567}, {"image": "other"}]}
  ],
  "cpuExceptions": [{"cpuMs": 90000, "sampledMs": 180000, "frames": []}],
  "stallHistogram": [{"lowMs": 50, "highMs": 100, "count": 12}],
  "metrics": {
    "hangTime": [{"lowMs": 0, "highMs": 100, "count": 40}],
    "launchFirstDraw": [], "launchResume": [], "launchOptimizedFirstDraw": [], "launchExtended": [],
    "scrollHitchMsPerS": 1.5, "hitchMsPerS": null
  },
  "intervals": [{"category": "motion", "name": "motion.frame", "count": 1200,
                 "buckets": [{"lowMs": 0, "highMs": 10, "count": 1100}], "hitchMsPerS": 0.4}]
}
```

Limits: 20 hangs, 5 CPU exceptions, 64 frames per stack, 32 buckets per histogram, 64
intervals. `hangs[].source` is `metrickit` or `watchdog`; `kind` is `hang` (2 s and more, or
a MetricKit hang) or `stall` (250 ms to 2 s, watchdog). Frames are innermost first; for a
MetricKit tree, the heaviest path (largest `sampleCount` at each level). `offset` is from the
start of the image's `__TEXT` segment (MetricKit's `offsetIntoBinaryTextSegment`; for the
watchdog, return address minus the image's load address). The server checks every field with
the same limits and patterns and rejects unknown keys.

Schema 2 has the same fields as schema 1. It marks a client with the review 1 and 2 privacy
fixes; the server refuses schema 1 (`400`, so the old client drops the report from its outbox),
so a report that an older NIGHTLY queued under the old image rules is never stored when the
endpoint opens. The client also drops a queued body whose schema or app is not its own.
`hardware.chip` is a closed set (`Apple M<n>[ Pro| Max| Ultra]`, `Intel`, `other`) and
`hardware.memoryGB` one of the sizes in `HardwareClass.memorySizesGB`, on both sides.

### Input latency (p04-input-010)

Chrome reads input latency in the field as distributions, never as single events (the
`EventLatency.*` and `Event.ScrollJank.*` UMA histograms; cc/metrics/event_metrics.h,
cc/metrics/scroll_jank_dropped_frame_tracker.cc). A schema-3 report carries the same, from the
`InputLatencyReporter` field ledger (p04-input-002), in three optional keys that are present
together or all absent (absent: no input was counted since the last report, or the report is
schema 2). They use the snake_case names of `debug.input` and the trace tools:

```json
{
  "input_latency_bucket_edges_ms": [1, 2, 4, 6, 8.3, 10, 12, 16.7, 24, 33, 50, 100, 250],
  "input_latency": [
    {"kind": "keyPress", "target": "terminal", "entrypoint": "person",
     "presentation_source": "estimatedVsync", "display": {"refresh_hz": 120, "vrr": true},
     "count": 940, "buckets": [0, 3, 120, 400, 300, 80, 20, 10, 5, 1, 1, 0, 0, 0], "max_ms": 41.25}
  ],
  "scroll_jank": {"presented_frames": 640, "delayed_frames": 9, "skipped_frames": 12,
                  "histograms": [{"name": "Event.ScrollJank.DelayedFramesPercentage.FixedWindow",
                                  "samples": [{"value": 0, "count": 7}, {"value": 4, "count": 3}]}]}
}
```

- `input_latency_bucket_edges_ms`: the upper edges of the buckets (`InputLatencyBuckets`), in
  milliseconds; 8.3 and 16.7 are one frame at 120 and 60 Hz.
- `input_latency[]`: at most 64 rows, the most frequent first. `kind` is an `InputEventKind`
  case name (`keyPress`, `keyRelease`, `flags`, `mousePress`, `mouseRelease`, `pointerMove`,
  `drag`, `scrollBegin`, `scrollFirstUpdate`, `scrollUpdate`, `scrollMomentum`, `scrollEnd`,
  `magnify`), `target` an `InputTarget` (`terminal`, `textView`, `chromiumPage`, `webkitPage`,
  `agentPane`, `layout`, `sidebar`, `palette`, `other`), `entrypoint` `person` or `automation`,
  `presentation_source` an `InputPresentationSource` (`estimatedVsync`, `metalPresented`,
  `hostFeedback`, `pageEstimated`). `display` is the display the row's inputs were presented on
  (`InputDisplayClass`, from each batch): `refresh_hz` its highest refresh rate in whole hertz,
  0 when unknown (above 1000 is sent as 0), and `vrr` true when the rate varies (ProMotion,
  adaptive sync), where `estimatedVsync` times are less exact. Inputs on a 120 Hz ProMotion
  panel and on a 60 Hz external display are different rows. `buckets` has one count per edge,
  then one count over the last edge (14 entries); bucket `i` counts latencies in
  (edge[i-1], edge[i]]. `count` is the sum of `buckets`: the inputs that reached a presented
  frame (oldest OS event to presented frame). `max_ms` is the longest, two decimals, at most one
  day. A row whose label is not one of these case names, or whose bucket count differs, is left
  out.
- `scroll_jank`: the person's scroll frames as Chrome counts them: `presented_frames`,
  `delayed_frames` (janky: the gap to the previous presentation is over 1.5 vsyncs and the
  input was there before it; at most `presented_frames`), `skipped_frames` (a scroll's first
  frame, out of order or inconsistent times). `histograms[]` lists only emitted ones by Chrome's
  name (`Event.ScrollJank.DelayedFramesPercentage.FixedWindow`, `.MissedVsyncsSum.FixedWindow`,
  `.MissedVsyncsMax.FixedWindow` and the three `.PerScroll`), in that order, each value with how
  often it was emitted; a percentage is at most 100, a missed vsync count at most 50 (Chrome's
  `kVsyncCountsMax`).

Nothing else: no event time, no key, no character, no coordinate, no window, no title. Every
string is an enum case name or a Chrome histogram name. The leak scan skips the personal-term
check only for a value that is exactly a member of its own field's closed set
(`PrivacyLeakScanner.closedSetValues`); every other string, image names included, keeps the
full term list, so a person named Mina still makes a `MinaTools.dylib` frame `other`.

The field ledger is the reporter's own (`debug.input reset` never changes what a report says)
and follows the report's on/off state: `HangReportService.setEnabled` calls
`HangReportInputLatencySource.setRecording`, so off drops every count not yet sent and nothing
recorded while reports were off or not allowed goes out later. A report takes counts as deltas,
the way UMA uploads histogram deltas (base/metrics/histogram_snapshot_manager.cc): the rows,
counters and emitted histograms move out, while the scroll in progress, its last presentation
and the fixed window not yet full stay, so a scroll that spans two reports is measured as one
(`InputLatencyLedger.takeCounts()`). Taken counts are held until the report is queued
(`commit()`); a report dropped by the daily cap, an off switch, the size cap or the leak scan
gives them to the next one. View Hang Report's preview reads `preview()`, which takes nothing,
so the preview has the same keys as the next send. A report over the body cap drops input
latency first (the least frequent rows, then the scroll jank histograms, then the whole block),
so hangs keep the room they had before input latency existed.

**Server first.** The route rejects unknown keys and other schema numbers. The input fields are
schema 3 only (`HangReport.WireSchema.carriesInputLatency`): a schema-2 build neither records
nor sends them. p09-observability-064 adds the schema-3 decoder, p04-input-103 adds these keys
to it (closed literal sets, the same limits, a fixture byte-identical to the Swift golden), and
p04-input-104 wires the reporter in behind the default-off feature `hangReportInputLatency` and
063's server-version flag.

**Schema 3 (blocking call sites, p02-threads-008).** Schema 3 also carries the blocking
detector's call sites (`base::ScopedBlockingCall`'s copy, plans/cmux-next/threading-model.md).
A site is one entry of `hangs`, before the timed ones (so the 64 KiB cut, which drops from the
end, takes the shortest stall first), at most 8 per report:

```json
{"source": "detector", "kind": "blocking", "durationMs": 0,
 "blocking": {"kind": "file-io", "context": "main"},
 "frames": [{"image": "cmux NEXT Nightly", "uuid": "3F0C...", "offset": 768}, {"image": "other"}]}
```

`source` adds `detector` and `kind` adds `blocking`; `blocking` is present exactly when the source
is `detector` and the kind `blocking`, and then `durationMs` is 0 (the detector reports the site,
not its time). `blocking.kind` is a `BlockingKind` raw value (`file-io`, `socket-read`,
`socket-write`, `sync-wait`, `ipc-reply`, `process-wait`, `process-spawn`, `lock-wait`,
`system-call`, ...: the Swift enum is the list) and `blocking.context` a `BlockingContext` raw value
(`main`, `pool`, `lane`, `dedicated`, `cpu-lane`), both closed sets with no other keys. The detector's frames
are at most 8, image UUID + offset, classified as every other frame.

Order of the change: the server accepts schema 2 and 3 first (`web/services/hangReports/wireSchema.ts`,
its schema 3 fixture next to `hang-report-schema2.json`), is deployed, and only then does the client's
`HangReport.WireSchema.deployed` move from `v2` to `v3`. Until then the client keeps no blocking site
for hang reports (the collector drops them and the builder writes schema 2), because the deployed
server refuses unknown keys and literals with a `400` and the client then drops the whole report.
`HangReportServerRules` (CmuxNextHangReportsTests) is the client's copy of these key and literal
sets; the goldens of both schemas pass it.

Schema 3 also adds `counts.userBlockingWaitP99Ms` (p02-threads-123,
`HangReport.WireSchema.carriesLaneWait`): the background lanes' user-blocking queue-wait p99 since
launch, one of `0-1`, `1-2`, `2-4`, `4-8`, `8-16`, `16-32`, `32-64`, `64+` (milliseconds,
`CoarseCounts.waitLabels`). The schema-3 decoder must list it as an optional closed literal set
before a build sends schema 3; a schema-2 report never has it.

## 5. Server

- `web/app/api/hang-reports/route.ts`: a thin Next route handler that runs one Effect program
  (`web/services/hangReports/`): size cap (64 KiB, read bounded), JSON parse, `effect/Schema`
  decode of schema 2 (strict; schema 1 refused), per-install daily cap (8 reports per UTC day), insert into
  `hang_reports` (`report_id` primary key, `on conflict do nothing`). Rate limit: the Vercel
  firewall rule `CMUX_HANG_REPORTS_RATE_LIMIT_ID` (per client at the edge; a limited request gets
  `429`). The handler reads no IP header, writes no IP into logs, spans or rows, and logs no
  body.
- Table `hang_reports` (PlanetScale Postgres `cmux-prod`, migration rehearsed on `staging`, then
  applied to `main` before the web PR merges): report id, install id, UTC day, app version and
  build, channel, macOS version, hardware class columns, counts and the validated report as
  `jsonb`, `received_at`. Rows older than 90 days are deleted by the daily
  `/api/cron/hang-reports-retention` job.
- `web/scripts/hang-reports-top-frames.ts` (read only, `DATABASE_URL`): groups hangs by their
  top frames (the first frames in our own images, else the top frame), with count, installs,
  p50 and p95 duration, versions and the frames; `--symbolicate DSYM_DIR` runs `atos` on our
  frames. The perf agents run it; there is no public dashboard.

## 6. Client cost

No timers and no polling. Triggers: a MetricKit delivery, and the launch (an outbox retry, or a
watchdog-only report when the last report is over 24 hours old). Off, the watchdog sink is one
atomic load per finished stall (stalls are already measured); on, a lock and a few adds per
finished stall, plus an array copy of the stack for the 8 longest stalls of the period. Report
building, image classification and upload run on a utility task when a trigger fires, at most a
few times a day. Idle: 0 extra wakeups, 0 extra CPU (measured in section 8).

## 7. Files

App: `Packages/macOS/CmuxNext/Sources/CmuxNextHangReports/` (builder, redaction, scanner,
collector, identity, store, uploader, MetricKit adapter; `HangReport+InputLatency.swift`,
`HangReportBuilder+InputLatency.swift` and the `HangReportInputLatencySource` seam for the input
fields), `CmuxNextApp/HangReports/` (wiring,
ask card, action handler; `WatchdogReporting` now holds all of the watchdog's sinks),
`CmuxNextSettings/HangReportsSetting.swift` and its schema row, the `diagnostics.viewHangReport`
action (`HangReportsActionCatalog`). Strings: `CmuxNextSettings/Localizable.xcstrings`,
`CmuxNextActions/HangReportsActions.xcstrings`, `CmuxNextApp/Resources/HangReports.xcstrings`
(all 21 catalog locales).

The ask uses `SidebarAsks`, the queue the agent Cloud requests use: while the person has not
answered, a later agent request waits behind it (one card at a time). Accepted: the card shows
once per Mac and takes one click.
Web: `web/app/api/hang-reports/`, `web/services/hangReports/`, `web/db/schema.ts`,
`web/db/migrations/<stamp>_hang_reports/`, `web/scripts/hang-reports-top-frames.ts`.

## 8. Results

- App (feat-cmux-next): CmuxNextHangReports target, Settings row, View Hang Report action,
  sidebar ask, WatchdogReporting, the Signposter MetricKit mirror (PL-arch agreed). Fleet:
  `cmux-ci compile-check --app` passed at d8b5cec67b2 (job 4db2acbad28f). Unit suites
  HangReportPrivacyTests, PrivacyLeakScannerTests, HangReportCollectorTests,
  HangReportServiceTests, HangReportWireFormatTests: 35 tests pass on cmuxs-Mac-mini-4 at
  d8b5cec67b2 (step 096c30d39b3e).
- Web (main, PR #24541, merged 108696d0d30): route, Effect services, retention cron, top-frames script; 32 bun
  tests pass, 3 Postgres behavior tests pass on local Postgres 17.
- Schema: `hang_reports` on PlanetScale `cmux-prod` `staging` (drizzle journal id 219, hash
  df1ee749...) and on `main` (production) as the same additive DDL, 2026-10-23, before the web
  merge. Production's table owner is `postgres` (pscale admin cannot SET ROLE to the app role);
  the app role `pscale_api_ms5ogh99zqn1` has SELECT, INSERT, UPDATE, DELETE. main's migrator
  replays the file as a no-op (`IF NOT EXISTS`). A later ALTER of this table must run as admin.
- Independent review (claude-reviewer): BLOCK at 1f722ecf / 56225de9 (interval categories,
  reentrancy after off, query params in error reports, and more), then SHIP at 8f715450 and
  d8b5cec6 after the fixes.
- Idle cost: off, the watchdog sink and every Signposter interval add one relaxed atomic load;
  no timer, no polling, no object built on Release/RC/DEV. The on/off idle bench
  (`bench-idle.sh --setting diagnostics.hangReports=true --env CMUX_NEXT_DEV_HANG_REPORTS=1`)
  could not run: the GUI host refused `--app-from-fleet` ("the host did not answer").
