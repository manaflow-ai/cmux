# Lane: cefs-leases

One live lease per shared Chromium file (chrome-parity task p01-process-180). Hundreds of agents push
`cp/<task id>` branches into `perf/chrome-parity`. The process-model program (p01-process, PL-cefhost) changes
every shim call site in CEFS, and the layer-hosting and capture program (p03-rendering, PL-cef-layer), the API 29
renderer-sharing work (p07-memory, PL-memory, with p13-webui) and others change the same files
([p01-process.md](../chrome-parity/p01-process.md) rule 11 and risk 11). A lease makes sure that only one task
edits a file at a time.

Chromium does this with an `OWNERS` file in each directory and `per-file` lines
(Chromium `docs/code_reviews.md`, "OWNERS files"), which say who must review a change. A lease is narrower: it
says which one task may change the file now. [OWNERS.md](../OWNERS.md) still says who to tell.

Paths: CEFS = `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF`, APP = `Packages/macOS/CmuxNext/Sources`,
HOST = `Packages/macOS/CmuxNext/ChromiumHost`, CEFShim = `Packages/macOS/CmuxNext/CEFShim`.

## Rules

1. Each file below has a queue of the unmerged tasks of every program whose `files` list names the file
   (`plans/cmux-next/chrome-parity/design-result.json`), plus each unmerged `cp/` branch that edits the file.
2. The lease holder of a file is the queue entry with an `open` branch that was pushed first. If no entry is open,
   the holder is the first `ready` entry in the row. If no entry is ready, the holder is the first entry, and it
   starts when its `depends_on` tasks land. There is one holder for each file at all times.
   - `open`: `origin/cp/<task id>` (or an older numbered `cp/<n>` branch) is pushed and not merged into
     `origin/perf/chrome-parity`.
   - `ready`: every `depends_on` task is merged. An entry with no label waits for its dependencies.
   - `waiting` (Holder column only): the holder waits for its dependencies. No other entry is open or ready.
3. Edit a lease file only when your task is its holder. Your first push of `cp/<task id>` that changes the file
   takes the lease. Before that push, do step 3 of "Regenerate" for the file. If another open `cp/` branch
   changes it, you are not the holder: do not push changes to that file.
4. The lease ends when the holder's branch merges into `perf/chrome-parity`. Then the next entry takes it under
   rule 2. You do not need to edit this file when a lease moves.
5. If you are queued behind a holder, do the parts of your task that are in files you hold. When the holder lands,
   merge `origin/perf/chrome-parity` into your branch (a merge, not a rebase), then edit the file.
6. A task that is not in a row goes after every listed entry. It may edit the file only when no listed entry
   of that row is open or ready. If it cannot wait, ask the p01-process lead to add it to the row. Only that lead
   changes a row's order, in one commit that names who made the decision.
7. The Q3 queue in this snapshot is the unfiltered call-site list (step 1 of "Regenerate"). When task
   p01-process-011 lands, the lead regenerates the Q3 rows with
   `scripts/cmux-next/gen-chromium-host-wire.py --swift-sites --by-file`. A file that then has 0 async, mint,
   view, local or result-reading sites drops its p01-process-021..027 entry. Its row stays only if another task
   lists the file.

## Open collisions (snapshot)

These branches were already open on the same file when this table was written. They break rule 3, so they land
in push order. Each later branch merges `origin/perf/chrome-parity` after the one before it lands, and before it
lands itself:

| File | Land order (task, branch, first push UTC 2026-10-26) |
|---|---|
| `CEFS/CEFRuntime.swift` | p12-perf-process-153 (`cp/99`, 00:57), p01-process-225 (`cp/91-p01-process-225`, 02:05), p10-stability-088 (`cp/91-p10-stability-088`, 02:57), p13-webui-013 (`cp/p13-webui-013`, 04:42) |
| `CEFS/CEFRuntime+Events.swift` | p10-stability-088 (`cp/91-p10-stability-088`, 02:57), p13-webui-013 (`cp/p13-webui-013`, 04:42) |
| `CEFS/CEFTab+Events.swift` | p10-stability-088 (`cp/91-p10-stability-088`, 02:57), p13-webui-013 (`cp/p13-webui-013`, 04:42) |
| `CEFS/CEFEngine.swift` | p01-process-225 (`cp/91-p01-process-225`, 02:05), p14-energy-023 (`cp/p14-energy-023`, 04:24), p13-webui-013 (`cp/p13-webui-013`, 04:42) |
| `CEFS/CEFTab+Processes.swift` | p01-process-225 (`cp/91-p01-process-225`, 02:05), p14-energy-023 (`cp/p14-energy-023`, 04:24) |
| `HOST/src/browser_host_main.mm` | p14-energy-045 (`cp/75`, 01:28), p01-process-225 (`cp/91-p01-process-225`, 02:05), p01-process-088 (`cp/94-p01-process-088`, 02:14), p01-process-222 (`cp/96-p01-process-222`, 02:34) |

p14-energy-045 (`cp/75`), p01-process-225 and p01-process-222 edit `CEFShim/src/browser_host_main.mm`. That is
the path from before p01-process-001 moved the file to `HOST/src/`. Merge `origin/perf/chrome-parity` into those
branches before they land, so that the edit follows the move.

These open branches hold files that their task's `files` list does not name:

- p01-process-088: `CEFS/ChromiumHost/ChromiumHostPageView.swift`, `HOST/src/browser_host_main.mm`.
- p01-process-225: `CEFS/CEFRuntime.swift`, `CEFS/CEFEngine.swift`, `HOST/src/browser_host_main.mm`.
- p10-stability-088: `CEFS/CEFRuntime.swift`, `CEFS/CEFRuntime+Events.swift`, `CEFS/CEFEngine+Passwords.swift`, `CEFS/CEFTab+Events.swift`, `CEFS/CEFFindRequests.swift`.
- p12-perf-process-153: `CEFS/CEFRuntime.swift`.
- p13-webui-013: `CEFS/CEFRuntime.swift`, `CEFS/CEFTab.swift`, `CEFS/CEFRuntime+Events.swift`, `CEFS/CEFTab+Events.swift`, `CEFS/CEFAgentRelay.swift`, `CEFS/CEFEngine.swift`.
- p14-energy-023: `CEFS/CEFEngine.swift`, `CEFS/CEFTab+Processes.swift`.

## Q3 leases: Swift shim call sites (175 sites in 49 files)

Snapshot at `origin/perf/chrome-parity` f503541756c. Sites are counts of
`rg -n '\bshim\??\.[a-zA-Z]+\(' APP --glob '!**/CEFShimLibrary.swift'`.

| File | Sites | Holder | Queue after the holder |
|---|---|---|---|
| `CEFS/CEFRuntime.swift` | 23 | p12-perf-process-153 (open) | p01-process-225 (open), p10-stability-088 (open), p13-webui-013 (open), p08-startup-045 (ready), p01-process-231 (ready), p13-webui-055 (ready), p13-webui-062 (ready), p02-threads-122 (ready), p14-energy-016 (ready), p08-startup-044, p08-startup-099, p01-process-015, p01-process-021, p01-process-034, p13-webui-012, p10-stability-082, p14-energy-017, p14-energy-030 |
| `CEFS/CEFTab.swift` | 15 | p13-webui-013 (open) | p07-memory-106 (ready), p12-perf-process-083 (ready), p01-process-022 |
| `CEFS/CEFDevToolsController.swift` | 10 | p03-rendering-056 (waiting) | p01-process-024, p01-process-033, p10-stability-082 |
| `CEFS/CEFDownloads.swift` | 9 | p01-process-027 (waiting) | p01-process-069, p11-codebase-029 |
| `CEFS/CEFPaneHost.swift` | 9 | p09-observability-033 (ready) | p06-scheduler-219 (ready), p13-webui-062 (ready), p14-energy-048 (ready), p01-process-019, p01-process-023, p04-input-082, p10-stability-082 |
| `CEFS/CEFRuntime+Events.swift` | 9 | p10-stability-088 (open) | p13-webui-013 (open), p01-process-231 (ready), p06-scheduler-219 (ready), p04-input-062 (ready), p03-rendering-046, p01-process-021, p01-process-030, p01-process-033 |
| `CEFS/CEFRuntime+Site.swift` | 8 | p01-process-021 (waiting) | - |
| `CEFS/CEFEngine+Passwords.swift` | 7 | p10-stability-088 (open) | p06-scheduler-219 (ready), p01-process-025 |
| `CEFS/CEFTab+Events.swift` | 6 | p10-stability-088 (open) | p13-webui-013 (open), p01-process-022, p01-process-229, p01-process-082, p01-process-072, p09-observability-108 |
| `CEFS/CEFExtensionBackend.swift` | 5 | p01-process-026 (waiting) | - |
| `CEFS/CEFOmniboxKeywords.swift` | 5 | p07-memory-055 (ready) | p01-process-026 |
| `CEFS/CEFPaneHost+PopupWindows.swift` | 5 | p03-rendering-056 (waiting) | p01-process-023, p01-process-066, p10-stability-082 |
| `CEFS/CEFOrphanTabs.swift` | 4 | p01-process-023 (waiting) | - |
| `APP/CmuxNextBrowser/Engine/BrowserHibernationSupport.swift` | 3 | p01-process-027 (waiting) | p07-memory-084, p07-memory-085 |
| `CEFS/CEFEngine+Passkeys.swift` | 3 | p01-process-025 (waiting) | p01-process-067 |
| `CEFS/CEFEngine+PasswordImport.swift` | 3 | p01-process-025 (waiting) | - |
| `CEFS/CEFPaneHost+Popups.swift` | 3 | p01-process-023 (waiting) | - |
| `CEFS/CEFPasswordPrompts.swift` | 3 | p01-process-025 (waiting) | - |
| `CEFS/CEFTab+LoadingBackground.swift` | 3 | p01-process-022 (waiting) | - |
| `CEFS/CEFAgentRelay.swift` | 2 | p13-webui-013 (open) | p13-webui-068 (ready), p01-process-027, p01-process-233 |
| `CEFS/CEFDefaultSearch.swift` | 2 | p01-process-026 (waiting) | - |
| `CEFS/CEFExtensionPrompts.swift` | 2 | p01-process-026 (waiting) | - |
| `CEFS/CEFLayerHosting.swift` | 2 | p03-rendering-097 (ready) | p03-rendering-099 (ready), p09-observability-028 (ready), p06-scheduler-219 (ready), p12-perf-process-100 (ready), p03-rendering-043, p03-rendering-045, p03-rendering-054, p03-rendering-055, p15-oracle-180, p01-process-023 |
| `CEFS/CEFPaneHost+Duplicate.swift` | 2 | p01-process-023 (waiting) | - |
| `CEFS/CEFRuntime+ContextMenu.swift` | 2 | p01-process-021 (waiting) | p01-process-069 |
| `CEFS/CEFRuntime+PasswordImport.swift` | 2 | p01-process-021 (waiting) | - |
| `CEFS/CEFRuntime+ProfileProxy.swift` | 2 | p01-process-021 (waiting) | - |
| `CEFS/CEFSidePanelController.swift` | 2 | p01-process-023 (waiting) | p01-process-066 |
| `CEFS/CEFTab+BackForwardList.swift` | 2 | p01-process-022 (waiting) | - |
| `CEFS/CEFTab+Freeze.swift` | 2 | p14-energy-048 (ready) | p01-process-022, p07-memory-097, p07-memory-101, p06-scheduler-212, p13-webui-019, p13-webui-031, p13-webui-059 |
| `CEFS/CEFTab+UserClose.swift` | 2 | p01-process-022 (waiting) | p01-process-064, p01-process-072 |
| `APP/CmuxNextBrowser/Engine/BrowserPagePrint.swift` | 1 | p02-threads-132 (ready) | p01-process-027, p01-process-065 |
| `CEFS/CEFAgentURLGuard.swift` | 1 | p01-process-027 (waiting) | - |
| `CEFS/CEFBookmarkBridge.swift` | 1 | p01-process-027 (waiting) | p11-codebase-029 |
| `CEFS/CEFEngine+BrowsingData.swift` | 1 | p08-startup-100 (waiting) | p01-process-027 |
| `CEFS/CEFEngine.swift` | 1 | p01-process-225 (open) | p14-energy-023 (open), p13-webui-013 (open), p13-webui-016 (ready), p08-startup-040, p01-process-027, p07-memory-051 |
| `CEFS/CEFForkFeatures.swift` | 1 | p03-rendering-041 (ready) | p01-process-027, p13-webui-012, p14-energy-030, p14-energy-136 |
| `CEFS/CEFPaneHost+Show.swift` | 1 | p03-rendering-054 (waiting) | p01-process-023 |
| `CEFS/CEFPasswordPolicy.swift` | 1 | p01-process-025 (waiting) | - |
| `CEFS/CEFRuntime+CookieImport.swift` | 1 | p01-process-021 (waiting) | - |
| `CEFS/CEFRuntime+Favicon.swift` | 1 | p01-process-021 (waiting) | - |
| `CEFS/CEFRuntime+PageResources.swift` | 1 | p01-process-021 (waiting) | - |
| `CEFS/CEFRuntime+Windows.swift` | 1 | p01-process-019 (waiting) | p01-process-021 |
| `CEFS/CEFSignInCallbacks.swift` | 1 | p01-process-027 (waiting) | - |
| `CEFS/CEFTab+Focus.swift` | 1 | p01-process-022 (waiting) | p01-process-032, p01-process-046 |
| `CEFS/CEFTab+PasswordFill.swift` | 1 | p01-process-022 (waiting) | - |
| `CEFS/CEFTab+Processes.swift` | 1 | p01-process-225 (open) | p14-energy-023 (open), p01-process-022 |
| `CEFS/CEFWindowRequests.swift` | 1 | p01-process-027 (waiting) | p01-process-031 |
| `CEFS/ChromiumNetError.swift` | 1 | p01-process-027 (waiting) | - |

## Leases for the files of p01-process-030..034, 046, 048, 064 and 069 that are not in Q3

| File | Sites | Holder | Queue after the holder |
|---|---|---|---|
| `CEFS/CEFFindRequests.swift` | - | p10-stability-088 (open) | p01-process-048 |
| `CEFS/CEFMessagePump.swift` | - | p09-observability-032 (ready) | p06-scheduler-048 (ready), p12-perf-process-083 (ready), p14-energy-016 (ready), p03-rendering-116, p01-process-034, p01-process-102, p09-observability-077, p04-input-024, p10-stability-031, p14-energy-018, p14-energy-046 |
| `CEFS/CEFPumpSchedule.swift` | - | p06-scheduler-048 (ready) | p14-energy-037 (ready), p03-rendering-116, p01-process-034, p01-process-102, p14-energy-017, p14-energy-046 |
| `CEFS/CEFTab+CertificateWarnings.swift` | - | p01-process-064 (waiting) | - |
| `CEFS/CEFWindowPolicy.swift` | - | p01-process-031 (waiting) | - |
| `CEFS/ChromiumHost/ChromiumHostFiles.swift` | - | p01-process-064 (waiting) | - |
| `CEFS/ChromiumHost/ChromiumHostPageView.swift` | - | p01-process-088 (open) | p01-process-040 (ready), p04-input-038 (ready), p01-process-030, p01-process-042, p01-process-045, p01-process-046, p01-process-047, p01-process-048, p01-process-054, p01-process-220, p01-process-221, p01-process-229, p01-process-082 |
| `CEFShim/src/shim_browser.mm` | - | p03-rendering-044 (waiting) | p03-rendering-058, p01-process-032, p01-process-044, p01-process-051, p01-process-220, p01-process-060, p09-observability-061, p14-energy-124 |
| `CEFShim/src/shim_client.mm` | - | p01-process-030 (waiting) | p01-process-045, p01-process-063, p07-memory-049, p07-memory-101, p14-energy-046 |
| `CEFShim/src/shim_windows.mm` | - | p03-rendering-042 (waiting) | p03-rendering-116, p01-process-031 |
| `HOST/src/browser_host_main.mm` | - | p14-energy-045 (open) | p01-process-225 (open), p01-process-088 (open), p01-process-222 (open), p01-process-041 (ready), p01-process-013, p01-process-092, p01-process-042, p01-process-046, p01-process-053, p01-process-068, p01-process-226, p01-process-150, p09-observability-104, p04-input-063, p04-input-064, p04-input-065, p14-energy-128 |

## Programs told

These programs have entries in the rows above. Each one takes its leases under the rules in this file:

- Layer hosting and capture, PL-cef-layer (p03-rendering 041-058, 097, 099, 116; the cmux.34 capture in task
  p01-process-178): `CEFLayerHosting.swift`, `CEFPaneHost+Show.swift`, `CEFPaneHost+PopupWindows.swift`,
  `CEFDevToolsController.swift`, `CEFRuntime+Events.swift`, `CEFForkFeatures.swift`, `CEFMessagePump.swift`,
  `CEFPumpSchedule.swift`, `CEFShim/src/shim_browser.mm`, `CEFShim/src/shim_windows.mm`.
- API 29 renderer sharing, PL-memory (p07-memory) and PL-webui (p13-webui): `CEFTab.swift`, `CEFTab+Freeze.swift`,
  `CEFEngine.swift`, `CEFOmniboxKeywords.swift`, `BrowserHibernationSupport.swift`, `CEFShim/src/shim_client.mm`,
  `CEFRuntime.swift`, `CEFRuntime+Events.swift`, `CEFTab+Events.swift`, `CEFPaneHost.swift`, `CEFAgentRelay.swift`,
  `CEFForkFeatures.swift`.
- Oracle, p15-oracle-180: `CEFLayerHosting.swift`.
- The rows also have entries of p02-threads, p04-input, p06-scheduler, p08-startup, p09-observability,
  p10-stability, p11-codebase, p12-perf-process and p14-energy. The same rules apply to them.

## Regenerate

1. Q3 files and sites: `rg -c '\bshim\??\.[a-zA-Z]+\(' Packages/macOS/CmuxNext/Sources --glob '!**/CEFShimLibrary.swift'`.
   After p01-process-011 lands, use `gen-chromium-host-wire.py --swift-sites --by-file` (rule 7).
2. Queues: for each file, the tasks in `design-result.json` whose `files` name it, without the merged tasks
   (a merged task has a `Merge cp/<task id>` or `<task id>:` subject on `origin/perf/chrome-parity`).
3. Open branches: `git branch -r --no-merged origin/perf/chrome-parity --list 'origin/cp/*'`, then
   `git diff --name-only origin/perf/chrome-parity...<branch> -- <file>` for each branch.
4. Check: each row has one holder, and no two `open` entries are on the same row, except for the rows in
   "Open collisions".
