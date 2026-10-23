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

## 4. Wire format (schema 2)

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
collector, identity, store, uploader, MetricKit adapter), `CmuxNextApp/HangReports/` (wiring,
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
