# Check for Updates: where the time goes (2026-10-20)

Lawrence (cmux NIGHTLY): "I did check for updates ... It's slower than it should be ... Shouldn't
it just check the R2 payload? ... We need to make it 100 times faster."

## Timeline of one check (installed NIGHTLY 1.0.0-nightly.3939068198101, this Mac)

Taken from the updater's unified log (`log stream --info --predicate 'subsystem ==
"com.cmuxterm.app.next" AND category == "updater"'`) while `cmux action run
palette.checkForUpdates` ran. The build was already the newest, so the answer is "up to date".

| t (s)  | step                                                              |
|--------|-------------------------------------------------------------------|
| 0.000  | check requested; Sparkle ready, no session; foreground check starts |
| 0.006  | state -> checking ("Checking for Updates…" shows)                   |
| 0.244  | appcast loaded (1 item); Sparkle: no update (onLatestVersion)       |
| 0.245  | driver gets "update not found" ... and **holds it**                 |
| 2.016  | state -> notFound ("You're up to date" shows)                       |
| 7.021  | note hides; only now is Sparkle's "no update" acknowledged          |
| 7.022  | Sparkle cycle finished, session ends                                |

The feed itself is not the problem:

| path                                       | this Mac      | Mac mini cmux14 |
|--------------------------------------------|---------------|-----------------|
| `curl` appcast-arm64.xml (1,093 B), cold   | 120-225 ms    | 117-191 ms      |
| same, reused connection                    | 125 ms        | 93 ms           |
| same, `If-None-Match` (304)                | 147 ms        | 138 ms          |
| app's read-only probe (`updates.check`)    | 104-279 ms    | -               |
| Sparkle foreground check (feed to answer)  | 238 ms        | -               |

DNS 4-45 ms, TLS done by 30-100 ms, the rest is the Cloudflare -> R2 origin read
(`cf-cache-status: DYNAMIC`, `cache-control: no-cache, no-store`). No redirects.

## Causes

1. **A fixed 2 s minimum "Checking…" time** (`UpdateTiming.minimumCheckDisplayDuration`, applied
   in `UpdateDriver.setStateAfterMinimumCheckDelay`). Sparkle had the answer at 0.24 s; the
   driver parked it until 2.0 s so "a near-instant check still reads as deliberate". That is
   88% of the visible time, and it applied to "update available" too (when automatic download
   is off).
2. **Sparkle's session stayed open behind the 5 s "up to date" note.** The driver passed
   Sparkle's acknowledgement into the note, and the note called it only when it hid. Until then
   `sessionInProgress` is true, so a second Check for Updates in that window queued as a
   "replacement check" and waited up to 5 s more before it even started.
3. Not causes: the appcast is already a 1 KB file with one item (a separate `latest.json` would
   be the same size and the same round trip); an ETag 304 is no faster (the time is the origin
   round trip, not the bytes); there are no redirects; cmux-tui/acpmux version checks (a286) are
   not on this path; the EdDSA check runs only on the download, not on the check.

## Fix (landed on feat-cmux-next)

- The driver shows Sparkle's answer the moment Sparkle reports it (no minimum display time; the
  delayed-transition state machine is gone).
- On "up to date" the driver acknowledges Sparkle at once, so the session ends with the answer;
  the note still shows for its 5 s and only goes back to idle when it hides. A second check
  starts immediately.
- Signature verification is unchanged (Sparkle verifies the EdDSA signature on the download).

Tests: `Packages/macOS/CmuxUpdater/Tests/CmuxUpdaterTests/UpdateCheckLatencyTests.swift` (red
without the fix): up to date and update available show with no clock advance; Sparkle is
acknowledged once, when the answer shows; a check right after "up to date" starts without
waiting.

## Expected result

| step                          | before      | after                  |
|-------------------------------|-------------|------------------------|
| click to answer on screen     | 2.02 s      | ~0.24 s (feed + Sparkle) |
| second check within 7 s       | up to +5 s queued | starts at once   |

That is about 8x for the first answer, not 100x. The rest is the network round trip to the feed
(~100-200 ms) plus ~100 ms of Sparkle session setup. Under ~100 ms needs one of these, not done
here:

- **Edge-cache the appcast** (`cache-control: public, s-maxage=30` or a Cache Rule on
  `files-next.cmux.com/*/appcast*.xml`): Cloudflare would answer from the edge (~30-50 ms), but a
  new nightly would take up to 30 s to show. This is a release-path change (nightly workflow,
  staging first).
- **Warm connection**: keep the feed's HTTP/2 connection warm (saves ~30-40 ms of DNS+TLS).
- **Answer from the last background check** (Sparkle checks hourly): show "up to date as of
  HH:MM" at once and refresh in the background. Faster, but the answer can be up to an hour old.
