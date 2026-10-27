# Lane: cefs-leases

One live lease per shared Chromium file (chrome-parity task p01-process-180). Hundreds of agents push
`cp/<task id>` branches into `perf/chrome-parity`. The process-model program (p01-process, PL-cefhost) changes
every shim call site in CEFS, and the layer-hosting and capture program (p03-rendering, PL-cef-layer), the API 29
renderer-sharing work (p07-memory, PL-memory, with p13-webui) and others change the same files
([p01-process.md](../chrome-parity/p01-process.md) rule 11 and risk 11). A lease makes sure that only one task
edits a file at a time.

Chromium does this with an `OWNERS` file in each directory and `per-file` lines
(Chromium `docs/code_reviews.md`, "OWNERS files"), which say who must review a change. A lease is narrower: it
says which one task may change the file now. [OWNERS.md](../OWNERS.md) says who to tell.

Paths: CEFS = `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF`, APP = `Packages/macOS/CmuxNext/Sources`,
HOST = `Packages/macOS/CmuxNext/ChromiumHost`, CEFShim = `Packages/macOS/CmuxNext/CEFShim`.

`scripts/cmux-next/cefs-leases.py` computes every holder from git and `design-result.json`, so every agent gets
the same answer. The tables at the end are its output; do not compute a holder by hand.

## Rules

1. **Lease files.** Every file under CEFS, HOST and CEFShim, and the Q3 files in APP (the files with shim call
   sites). The table at the end has a row for each Q3 file, each file of p01-process-030..034, 046, 048, 064
   and 069, and each other lease file with two or more entries. `cefs-leases.py --holder FILE` gives the same
   answer for a lease file with no row.
2. **Queue.** A row is a queue, in this order:
   - the unmerged tasks whose `files` in `plans/cmux-next/chrome-parity/design-result.json` name the file. The
     script expands `*`, `**`, `[..]` and `{a,b}`, drops the ` (N)` and ` (new)` notes, and reads the old
     `CEFShim/src/browser_host_main.mm`, `chromium_host_wire.h` and `CEFShim/tests/chromium_host_wire_test.cpp`
     names as their HOST files (moved by p01-process-001);
   - after them, the unmerged tasks that are not named but have an open `cp/` branch that changes the file;
   - last, the sweep tasks that match the file (rule 7).
3. **Holder.** The holder is the first entry in queue order that is `ready`. If no entry is ready, the holder
   is the first entry, and it starts when its `depends_on` tasks merge. There is one holder for each file.
   - `ready`: every `depends_on` task is merged. An entry with no label waits for its dependencies.
   - `merged`: a first-parent commit of `origin/perf/chrome-parity` brings in a commit whose subject names the
     task id, in any form (`<id>: ...`, `... (<id>)`, `Merge cp/<n> (<id>) into ...`).
   - `open`: a `cp/` branch is pushed and not merged into `origin/perf/chrome-parity`. A `cp/<task id>` or
     `cp/<n>-<task id>` branch belongs to the task in its name; a numbered `cp/<n>` branch belongs to the task
     id its own commit subjects name most often.
   - **A taken lease stays.** An open entry took the lease if its branch first changed the file (the committer
     time of the first commit in `origin/perf/chrome-parity..BRANCH` that changes it) when the entry was ready
     and no earlier entry in the queue was ready. That entry keeps the lease until it merges, even if an earlier
     entry becomes ready. If two entries took it, the one that changed the file first holds it.
   - **A push takes nothing.** An open branch of an entry that is not the holder is a collision (the "Open
     collisions" table). It does not become the holder, and the script never moves it up the queue.
4. **Before every push** that changes a lease file, run
   `python3 scripts/cmux-next/cefs-leases.py --check HEAD --task <your task id>` in your worktree. It prints
   `WAIT` for each lease file that another task holds and exits 1. Do not push a change to a `WAIT` file: take
   those hunks out of your branch (keep them in a local branch) and push the rest.
5. **The lease ends** when the holder's branch merges into `perf/chrome-parity`, and the next entry takes it
   under rule 3. Nobody edits this file when a lease moves. If you are queued, do the parts of your task in
   files you hold. When the holder lands, merge `origin/perf/chrome-parity` into your branch (a merge, not a
   rebase), then edit the file.
6. **Order.** A regeneration keeps the order of the entries already in a row. It adds new named tasks after
   them (each after the tasks it depends on, ready ones first) and new unnamed open branches after those. Only
   the p01-process lead changes the order of a row or rebuilds it with `--fresh`, in one commit that names who
   decided. If your task cannot wait, ask the p01-process lead.
7. **Sweep tasks** are tasks whose `files` cover a whole lease folder (CEFS, HOST, CEFShim, the folder of a Q3
   file in APP, or a folder above it), for example `CmuxNextBrowser/**` or `Sources/**`. The "Sweep tasks"
   table names them in order. Each one is at the end of every row it matches, so a sweep task edits a file only
   when no named entry is ready or holds it, and one sweep task at a time. A task that names browser files in
   prose that no pattern resolves (listed under the sweep table) is at the end of the row of each lease file it
   changes.
8. **Q3 after p01-process-011.** The Q3 rows are the unfiltered call-site list. When p01-process-011 lands, the
   lead filters them with `scripts/cmux-next/gen-chromium-host-wire.py --swift-sites --by-file`. A file that then
   has 0 async, mint, view, local or result-reading sites drops its p01-process-021..027 entry.

## Collisions that came before the leases

The branches in "Open collisions" were pushed before this lane existed, or by a task that did not hold the
lease. The lead decision for each file (p01-process-180, 2026-10-26): the holder keeps the file. Each other open
branch pushes no new change to the file, lands after the holder and after the entries before it in the row, and
merges `origin/perf/chrome-parity` before it lands. The p01-process lead can tell a waiting branch to remove its
hunks from the file instead. A file meets "no two open tasks on one file" only when its row has no collision.
That is true for every file once the branches in the table have landed in that order.

p14-energy-045 (`cp/75`), p01-process-225 and p01-process-222 edit `CEFShim/src/browser_host_main.mm`, the path
from before p01-process-001 moved the file to `HOST/src/`. Merge `origin/perf/chrome-parity` into those branches
before they land, so that the edit follows the move.

## Programs told

These programs have entries in the rows. Each one takes its leases under the rules in this file:

- Layer hosting and capture, PL-cef-layer (p03-rendering 041-058, 097, 099, 116; the cmux.34 capture in task
  p01-process-178): `CEFLayerHosting.swift`, `CEFHostView.swift`, `CEFPaneHost+Show.swift`,
  `CEFPaneHost+PopupWindows.swift`, `CEFDevToolsController.swift`, `CEFRuntime+Events.swift`,
  `CEFForkFeatures.swift`, `CEFMessagePump.swift`, `CEFPumpSchedule.swift`, `CEFShim/src/shim_browser.mm`,
  `CEFShim/src/shim_windows.mm`, `CEFS/Shim/cmux_cef_shim.h`.
- API 29 renderer sharing, PL-memory (p07-memory) and PL-webui (p13-webui): `CEFTab.swift`, `CEFTab+Freeze.swift`,
  `CEFEngine.swift`, `CEFOmniboxKeywords.swift`, `BrowserHibernationSupport.swift`, `CEFShim/src/shim_client.mm`,
  `CEFRuntime.swift`, `CEFRuntime+Events.swift`, `CEFTab+Events.swift`, `CEFPaneHost.swift`, `CEFAgentRelay.swift`,
  `CEFForkFeatures.swift`, `CEFSwitches.swift`, `CEFPageSchemes.swift`, `CEFSpareWindow.swift`, and every
  `CEFS/ChromiumHost/` row (p07-memory-050).
- Oracle, p15-oracle-180: `CEFLayerHosting.swift`.
- The rows also have entries of p02-threads, p04-input, p05-ipc, p06-scheduler, p08-startup, p09-observability,
  p10-stability, p11-codebase, p12-perf-process and p14-energy. The same rules apply to them.

## Regenerate

`python3 scripts/cmux-next/cefs-leases.py --write` after `git fetch origin` (the lead, after landings, or anyone
who adds a task). It rewrites only the generated part below and keeps every row's order (rule 6). Then
`python3 scripts/cmux-next/generate-coordination-index.py --check`. The script does this:

1. Q3 files and sites: `git grep -c -P '\bshim\??\.[a-zA-Z]+\(' origin/perf/chrome-parity -- APP
   ':!**/CEFShimLibrary.swift'`. After p01-process-011 lands, the lead applies rule 8.
2. Named tasks: the `files` patterns of every unmerged task, expanded as in rule 2, matched against the files of
   `origin/perf/chrome-parity` and the ` (new)` files. A pattern whose fixed start (before the first `*` or `[`)
   is no longer than the lease folder of a file is a sweep of that file (rule 7).
3. Merged tasks: the task ids in the subjects of the commits that each first-parent commit of
   `origin/perf/chrome-parity` brings in (rule 3).
4. Open branches: `git branch -r --no-merged origin/perf/chrome-parity --list 'origin/cp/*'`, the lease files
   in `git diff --name-only origin/perf/chrome-parity...BRANCH`, the task of each branch (rule 3) and the time
   its first commit changed each file.
5. Holders under rule 3, and the "Open collisions" table: every open entry that is not its row's holder.


<!-- cefs-leases:begin -->

Generated by `scripts/cmux-next/cefs-leases.py --write` at `origin/perf/chrome-parity` be9dcf14ea5. Do not edit by hand, except that the p01-process lead may reorder a row (rule 6).

## Sweep tasks

Unmerged tasks whose `files` cover a lease folder with a broad pattern. Each is at the end of every row it matches, in this order (rule 7).

| Task | Patterns | State |
|---|---|---|
| `p03-rendering-065` | `APP/CmuxNextBrowser/**` | ready |
| `p09-observability-046` | `APP/CmuxNextBrowser/` | ready |
| `p09-observability-129` | `APP/` | ready |
| `p02-threads-036` | `APP/` | ready |
| `p02-threads-041..045` | `APP/` | ready |
| `p02-threads-053` | `APP/` | ready |
| `p02-threads-054..055` | `APP/` | ready |
| `p02-threads-056` | `APP/` | ready |
| `p02-threads-057` | `APP/` | ready |
| `p02-threads-059` | `APP/` | ready |
| `p10-stability-058` | `APP/CmuxNextBrowser/**` | ready |
| `p14-energy-055c` | `APP/CmuxNextBrowser/**` | ready |
| `p09-observability-124` | `APP/` | waiting |
| `p06-scheduler-322` | `CEFS/` | waiting |
| `p06-scheduler-323` | `APP/CmuxNextBrowser/Engine/` | waiting |
| `p06-scheduler-347` | `APP/` | waiting |
| `p02-threads-145` | `APP/` | waiting |
| `p02-threads-147` | `APP/` | waiting |
| `p11-codebase-093` | `APP/CmuxNextBrowser/Engine/**` | waiting |
| `p10-stability-067` | `CEFS/**` | waiting |
| `p10-stability-068` | `APP/CmuxNextBrowser/**` | waiting |
| `p10-stability-088` | `APP/CmuxNextBrowser/**` | waiting |
| `p10-stability-097` | `APP/**` | waiting |
| `p10-stability-167` | `APP/CmuxNextBrowser/**` | waiting |
| `p10-stability-170` | `APP/CmuxNextBrowser/**` | waiting |
| `p14-energy-019d` | `APP/**` | waiting |
| `p14-energy-132` | `APP/**` | waiting |
| `p14-energy-133` | `APP/**` | waiting |

These tasks name browser files in prose that no pattern resolves; they follow the sweep rule for every file they change: p03-rendering-121, p01-process-238, p11-codebase-065, p11-codebase-214, p10-stability-091.

## Open collisions

Open branches that change a lease file they do not hold. Each pushes no new change to the file, lands after the holder and the entries before it in the row, and merges `origin/perf/chrome-parity` first (rule 5).

| File | Holder | Open branches that wait, in land order |
|---|---|---|
| `CEFS/CEFRuntime.swift` | p13-webui-013 (open, `cp/p13-webui-013`) | p12-perf-process-153 (open, `cp/99`), p01-process-225 (open, `cp/91-p01-process-225`), p10-stability-088 (open, `cp/91-p10-stability-088`), p13-webui-012 (open, `cp/p13-webui-012`) |
| `CEFS/CEFRuntime+Events.swift` | p13-webui-013 (open, `cp/p13-webui-013`) | p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `CEFS/CEFEngine+Passwords.swift` | p06-scheduler-219 | p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `CEFS/CEFTab+Events.swift` | p13-webui-013 (open, `cp/p13-webui-013`) | p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `CEFS/CEFEngine.swift` | p14-energy-023 (open, `cp/p14-energy-023`) | p01-process-225 (open, `cp/91-p01-process-225`), p13-webui-013 (open, `cp/p13-webui-013`, ready) |
| `CEFS/CEFForkFeatures.swift` | p03-rendering-041 | p13-webui-012 (open, `cp/p13-webui-012`) |
| `CEFS/CEFTab+Processes.swift` | p14-energy-023 (open, `cp/p14-energy-023`) | p01-process-225 (open, `cp/91-p01-process-225`) |
| `CEFS/CEFChildProcessMonitor.swift` | p02-threads-032 (open, `cp/40`) | p01-process-225 (open, `cp/91-p01-process-225`) |
| `CEFS/CEFFindRequests.swift` | p03-rendering-065 (sweep) | p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `CEFS/CEFPageSchemes.swift` | p13-webui-013 (open, `cp/p13-webui-013`) | p13-webui-012 (open, `cp/p13-webui-012`) |
| `CEFS/CEFReplyWaiters.swift` | p03-rendering-065 (sweep) | p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `CEFS/CEFRuntime+Crashes.swift` | p09-observability-083 | p01-process-225 (open, `cp/91-p01-process-225`) |
| `CEFS/CEFShimLibrary.swift` | p03-rendering-065 (sweep) | p13-webui-012 (open, `cp/p13-webui-012`) |
| `CEFS/CEFSpareWindow.swift` | p09-observability-033 | p01-process-086 (open, `cp/92-p01-process-086`) |
| `CEFS/CEFSwitches.swift` | p14-energy-040 (open, `cp/69`) | p13-webui-085 (open, `cp/p13-webui-085`), p12-perf-process-153 (open, `cp/99`), p13-webui-084 (open, `cp/p13-webui-084`, ready) |
| `CEFS/ChromiumHelperProcess.swift` | p14-energy-023 (open, `cp/p14-energy-023`) | p01-process-225 (open, `cp/91-p01-process-225`) |
| `CEFS/ChromiumHost/ChromiumHostConfiguration.swift` | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p12-perf-process-153 (open, `cp/99`) |
| `CEFS/ChromiumHost/ChromiumHostFrame.swift` | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`) |
| `CEFS/ChromiumHost/ChromiumHostLauncher.swift` | p01-process-088 (open, `cp/94-p01-process-088`) | p01-process-222 (open, `cp/96-p01-process-222`), p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `CEFS/ChromiumHost/ChromiumHostPrototype.swift` | p01-process-088 (open, `cp/94-p01-process-088`) | p01-process-225 (open, `cp/91-p01-process-225`), p01-process-100 (open, `cp/104-p01-process-100`) |
| `CEFS/ChromiumHost/ChromiumHostSession.swift` | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`), p10-stability-088 (open, `cp/91-p10-stability-088`) |
| `HOST/src/browser_host_main.mm` | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`) |
| `HOST/src/chromium_host_wire.h` | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`) |
| `HOST/tests/chromium_host_wire_test.cpp` | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`) |

## Leases

Sites: `\bshim\??\.[a-zA-Z]+\(` hits at the base (Q3). Each row: holder, then the queue in order. `+N sweep`: the sweep tasks that match the file, in the sweep order.

| File | Sites | Holder | Queue after the holder |
|---|---|---|---|
| `CEFS/CEFRuntime.swift` | 23 | p13-webui-013 (open, `cp/p13-webui-013`) | p12-perf-process-153 (open, `cp/99`), p01-process-225 (open, `cp/91-p01-process-225`), p10-stability-088 (open, `cp/91-p10-stability-088`), p13-webui-012 (open, `cp/p13-webui-012`), p08-startup-045 (ready), p01-process-231 (ready), p13-webui-055 (ready), p13-webui-062 (ready), p02-threads-122 (ready), p14-energy-016 (ready), p08-startup-044, p08-startup-099, p01-process-015, p01-process-021, p01-process-034, p11-codebase-029, p10-stability-082, p14-energy-017, p14-energy-030, +25 sweep |
| `CEFS/CEFTab.swift` | 15 | p13-webui-013 (open, `cp/p13-webui-013`) | p07-memory-106 (ready), p12-perf-process-083 (ready), p01-process-022, +26 sweep |
| `CEFS/CEFDevToolsController.swift` | 10 | p03-rendering-065 (sweep) | p03-rendering-056, p01-process-024, p01-process-033, p10-stability-082, +25 sweep |
| `CEFS/CEFDownloads.swift` | 9 | p03-rendering-065 (sweep) | p01-process-027, p01-process-069, p11-codebase-029, +25 sweep |
| `CEFS/CEFPaneHost.swift` | 9 | p09-observability-033 | p06-scheduler-219 (ready), p13-webui-062 (ready), p14-energy-048 (ready), p01-process-019, p01-process-023, p04-input-082, p10-stability-082, +26 sweep |
| `CEFS/CEFRuntime+Events.swift` | 9 | p13-webui-013 (open, `cp/p13-webui-013`) | p10-stability-088 (open, `cp/91-p10-stability-088`), p01-process-231 (ready), p06-scheduler-219 (ready), p04-input-062 (ready), p03-rendering-046, p01-process-021, p01-process-030, p01-process-033, p11-codebase-029, +25 sweep |
| `CEFS/CEFRuntime+Site.swift` | 8 | p03-rendering-065 (sweep) | p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFEngine+Passwords.swift` | 7 | p06-scheduler-219 | p10-stability-088 (open, `cp/91-p10-stability-088`), p01-process-025, +25 sweep |
| `CEFS/CEFTab+Events.swift` | 6 | p13-webui-013 (open, `cp/p13-webui-013`) | p10-stability-088 (open, `cp/91-p10-stability-088`), p01-process-022, p01-process-229, p01-process-082, p01-process-072, p09-observability-108, +25 sweep |
| `CEFS/CEFExtensionBackend.swift` | 5 | p03-rendering-065 (sweep) | p01-process-026, +25 sweep |
| `CEFS/CEFOmniboxKeywords.swift` | 5 | p07-memory-055 | p01-process-026, +26 sweep |
| `CEFS/CEFPaneHost+PopupWindows.swift` | 5 | p03-rendering-065 (sweep) | p03-rendering-056, p01-process-023, p01-process-066, p10-stability-082, +25 sweep |
| `CEFS/CEFOrphanTabs.swift` | 4 | p03-rendering-065 (sweep) | p01-process-023, +25 sweep |
| `APP/CmuxNextBrowser/Engine/BrowserHibernationSupport.swift` | 3 | p03-rendering-065 (sweep) | p01-process-027, p07-memory-084, p07-memory-085, +25 sweep |
| `CEFS/CEFEngine+Passkeys.swift` | 3 | p03-rendering-065 (sweep) | p01-process-025, p01-process-067, +25 sweep |
| `CEFS/CEFEngine+PasswordImport.swift` | 3 | p03-rendering-065 (sweep) | p01-process-025, +25 sweep |
| `CEFS/CEFPaneHost+Popups.swift` | 3 | p03-rendering-065 (sweep) | p01-process-023, +25 sweep |
| `CEFS/CEFPasswordPrompts.swift` | 3 | p03-rendering-065 (sweep) | p01-process-025, +25 sweep |
| `CEFS/CEFTab+LoadingBackground.swift` | 3 | p03-rendering-065 (sweep) | p01-process-022, +25 sweep |
| `CEFS/CEFAgentRelay.swift` | 2 | p13-webui-013 (open, `cp/p13-webui-013`) | p13-webui-068 (ready), p01-process-027, p01-process-233, +26 sweep |
| `CEFS/CEFDefaultSearch.swift` | 2 | p03-rendering-065 (sweep) | p01-process-026, +25 sweep |
| `CEFS/CEFExtensionPrompts.swift` | 2 | p03-rendering-065 (sweep) | p01-process-026, +25 sweep |
| `CEFS/CEFLayerHosting.swift` | 2 | p03-rendering-097 | p03-rendering-099 (ready), p09-observability-028 (ready), p06-scheduler-219 (ready), p12-perf-process-100 (ready), p03-rendering-043, p03-rendering-045, p03-rendering-054, p03-rendering-055, p15-oracle-180, p01-process-023, +26 sweep |
| `CEFS/CEFPaneHost+Duplicate.swift` | 2 | p03-rendering-065 (sweep) | p01-process-023, +25 sweep |
| `CEFS/CEFRuntime+ContextMenu.swift` | 2 | p03-rendering-065 (sweep) | p01-process-021, p01-process-069, p11-codebase-029, +25 sweep |
| `CEFS/CEFRuntime+PasswordImport.swift` | 2 | p03-rendering-065 (sweep) | p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFRuntime+ProfileProxy.swift` | 2 | p03-rendering-065 (sweep) | p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFSidePanelController.swift` | 2 | p03-rendering-065 (sweep) | p01-process-023, p01-process-066, +25 sweep |
| `CEFS/CEFTab+BackForwardList.swift` | 2 | p03-rendering-065 (sweep) | p01-process-022, +25 sweep |
| `CEFS/CEFTab+Freeze.swift` | 2 | p14-energy-048 | p01-process-022, p07-memory-097, p07-memory-101, p06-scheduler-212, p13-webui-019, p13-webui-031, p13-webui-059, +26 sweep |
| `CEFS/CEFTab+UserClose.swift` | 2 | p03-rendering-065 (sweep) | p01-process-022, p01-process-064, p01-process-072, +25 sweep |
| `APP/CmuxNextBrowser/Engine/BrowserPagePrint.swift` | 1 | p02-threads-132 | p01-process-027, p01-process-065, +26 sweep |
| `CEFS/CEFAgentURLGuard.swift` | 1 | p03-rendering-065 (sweep) | p01-process-027, +25 sweep |
| `CEFS/CEFBookmarkBridge.swift` | 1 | p03-rendering-065 (sweep) | p01-process-027, p11-codebase-029, +25 sweep |
| `CEFS/CEFEngine+BrowsingData.swift` | 1 | p03-rendering-065 (sweep) | p08-startup-100, p01-process-027, +25 sweep |
| `CEFS/CEFEngine.swift` | 1 | p14-energy-023 (open, `cp/p14-energy-023`) | p01-process-225 (open, `cp/91-p01-process-225`), p13-webui-013 (open, `cp/p13-webui-013`, ready), p13-webui-016 (ready), p08-startup-040, p01-process-027, p07-memory-051, +26 sweep |
| `CEFS/CEFForkFeatures.swift` | 1 | p03-rendering-041 | p13-webui-012 (open, `cp/p13-webui-012`), p01-process-027, p14-energy-136, p14-energy-030, +26 sweep |
| `CEFS/CEFPaneHost+Show.swift` | 1 | p03-rendering-065 (sweep) | p03-rendering-054, p01-process-023, +25 sweep |
| `CEFS/CEFPasswordPolicy.swift` | 1 | p03-rendering-065 (sweep) | p01-process-025, +25 sweep |
| `CEFS/CEFRuntime+CookieImport.swift` | 1 | p03-rendering-065 (sweep) | p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFRuntime+Favicon.swift` | 1 | p03-rendering-065 (sweep) | p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFRuntime+PageResources.swift` | 1 | p03-rendering-065 (sweep) | p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFRuntime+Windows.swift` | 1 | p03-rendering-065 (sweep) | p01-process-019, p01-process-021, p11-codebase-029, +25 sweep |
| `CEFS/CEFSignInCallbacks.swift` | 1 | p03-rendering-065 (sweep) | p01-process-027, +25 sweep |
| `CEFS/CEFTab+Focus.swift` | 1 | p03-rendering-065 (sweep) | p01-process-022, p01-process-046, p01-process-032, +25 sweep |
| `CEFS/CEFTab+PasswordFill.swift` | 1 | p03-rendering-065 (sweep) | p01-process-022, +25 sweep |
| `CEFS/CEFTab+Processes.swift` | 1 | p14-energy-023 (open, `cp/p14-energy-023`) | p01-process-225 (open, `cp/91-p01-process-225`), p01-process-022, +26 sweep |
| `CEFS/CEFWindowRequests.swift` | 1 | p03-rendering-065 (sweep) | p01-process-027, p01-process-031, +25 sweep |
| `CEFS/ChromiumNetError.swift` | 1 | p03-rendering-065 (sweep) | p01-process-027, +25 sweep |
| `CEFS/CEFBuiltInExtensions.swift` | - | p02-threads-122 | p14-energy-108, +26 sweep |
| `CEFS/CEFChildProcessMonitor.swift` | - | p02-threads-032 (open, `cp/40`) | p01-process-225 (open, `cp/91-p01-process-225`), p09-observability-119, +26 sweep |
| `CEFS/CEFDocumentScripts.swift` | - | p13-webui-013 (open, `cp/p13-webui-013`) | p13-webui-068 (ready), p01-process-232, +26 sweep |
| `CEFS/CEFFileDragRelay.swift` | - | p13-webui-013 (open, `cp/p13-webui-013`) | p01-process-050, +26 sweep |
| `CEFS/CEFFindRequests.swift` | - | p03-rendering-065 (sweep) | p10-stability-088 (open, `cp/91-p10-stability-088`), p01-process-048, +24 sweep |
| `CEFS/CEFFrameworkPrefetch.swift` | - | p08-startup-045 | p01-process-101, +26 sweep |
| `CEFS/CEFHostView.swift` | - | p09-observability-038 | p06-scheduler-046 (ready), p03-rendering-036, p03-rendering-045, p03-rendering-046, p03-rendering-053, p07-memory-116, p11-codebase-050, p11-codebase-051, +26 sweep |
| `CEFS/CEFHostedPageView.swift` | - | p01-process-040 | p03-rendering-045, p03-rendering-055, +26 sweep |
| `CEFS/CEFMessagePump.swift` | - | p09-observability-032 | p06-scheduler-048 (ready), p12-perf-process-083 (ready), p14-energy-016 (ready), p03-rendering-116, p01-process-034, p01-process-102, p09-observability-077, p04-input-024, p10-stability-031, p14-energy-018, p14-energy-046, +26 sweep |
| `CEFS/CEFPageMessage.swift` | - | p13-webui-013 (open, `cp/p13-webui-013`) | p01-process-232, +26 sweep |
| `CEFS/CEFPageSchemes.swift` | - | p13-webui-013 (open, `cp/p13-webui-013`) | p13-webui-012 (open, `cp/p13-webui-012`), p01-process-070, +26 sweep |
| `CEFS/CEFPumpSchedule.swift` | - | p06-scheduler-048 | p14-energy-037 (ready), p03-rendering-116, p01-process-034, p01-process-102, p14-energy-017, p14-energy-046, +26 sweep |
| `CEFS/CEFPumpStats.swift` | - | p09-observability-032 | p01-process-102, p09-observability-060, p14-energy-018, p14-energy-046, +26 sweep |
| `CEFS/CEFPumpTimer.swift` | - | p14-energy-016 | p01-process-102, +26 sweep |
| `CEFS/CEFReplyWaiters.swift` | - | p03-rendering-065 (sweep) | p10-stability-088 (open, `cp/91-p10-stability-088`), p01-process-018, p01-process-091, +24 sweep |
| `CEFS/CEFRuntime+Crashes.swift` | - | p09-observability-083 | p01-process-225 (open, `cp/91-p01-process-225`), p09-observability-060, p09-observability-106, p11-codebase-029, +26 sweep |
| `CEFS/CEFRuntimeSource.swift` | - | p03-rendering-065 (sweep) | p01-process-015, p11-codebase-029, +25 sweep |
| `CEFS/CEFShimABI.swift` | - | p03-rendering-065 (sweep) | p14-energy-030, p14-energy-124, +25 sweep |
| `CEFS/CEFShimLibrary.swift` | - | p03-rendering-065 (sweep) | p13-webui-012 (open, `cp/p13-webui-012`), p03-rendering-043, p01-process-015, p09-observability-051, p06-scheduler-212, p13-webui-019, p13-webui-031, p13-webui-078, +25 sweep |
| `CEFS/CEFSpareWindow.swift` | - | p09-observability-033 | p01-process-086 (open, `cp/92-p01-process-086`), p07-memory-047 (ready), p07-memory-055 (ready), p13-webui-016 (ready), p07-memory-113, p06-scheduler-050, p13-webui-019, p11-codebase-029, +26 sweep |
| `CEFS/CEFSwipeNavigation.swift` | - | p04-input-018 | p01-process-234, +26 sweep |
| `CEFS/CEFSwitches.swift` | - | p14-energy-040 (open, `cp/69`) | p13-webui-085 (open, `cp/p13-webui-085`), p12-perf-process-153 (open, `cp/99`), p13-webui-084 (open, `cp/p13-webui-084`, ready), p03-rendering-041 (ready), p07-memory-045 (ready), p13-webui-055 (ready), p12-perf-process-221 (ready), p03-rendering-116, p09-observability-106, p07-memory-046, p07-memory-049, p07-memory-111, p07-memory-113, p13-webui-020, p13-webui-083, p10-stability-164, p14-energy-109, p14-energy-042, p14-energy-043, p14-energy-044, +26 sweep |
| `CEFS/CEFTab+CertificateWarnings.swift` | - | p03-rendering-065 (sweep) | p01-process-064, +25 sweep |
| `CEFS/CEFTab+RestoredHistory.swift` | - | p03-rendering-065 (sweep) | p01-process-083, p01-process-093, +25 sweep |
| `CEFS/CEFTab+Visibility.swift` | - | p03-rendering-065 (sweep) | p01-process-220, p06-scheduler-212, +25 sweep |
| `CEFS/CEFWindowPolicy.swift` | - | p03-rendering-065 (sweep) | p01-process-031, +25 sweep |
| `CEFS/ChildWindowPageFallback.swift` | - | p03-rendering-065 (sweep) | p03-rendering-023, p03-rendering-036, p03-rendering-053, +25 sweep |
| `CEFS/ChromiumHelperProcess.swift` | - | p14-energy-023 (open, `cp/p14-energy-023`) | p01-process-225 (open, `cp/91-p01-process-225`), +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostChoosers.swift` | - | p03-rendering-065 (sweep) | p01-process-228, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostConfiguration.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p12-perf-process-153 (open, `cp/99`), p07-memory-045 (ready), p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostConnection.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p09-observability-038 (ready), p04-input-038 (ready), p09-observability-104, p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostControlChannel.swift` | - | p01-process-012 | p01-process-016b, p01-process-020, p01-process-091, p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostFiles.swift` | - | p03-rendering-065 (sweep) | p01-process-064, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostFrame.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`), p07-memory-050, p04-input-063, p05-ipc-181, p11-codebase-268, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostHangMonitor.swift` | - | p03-rendering-065 (sweep) | p01-process-084, p01-process-072, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostInputRing.swift` | - | p01-process-041 | p01-process-092, p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostLauncher.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p01-process-222 (open, `cp/96-p01-process-222`), p10-stability-088 (open, `cp/91-p10-stability-088`), p08-startup-046, p01-process-080, p09-observability-104, p07-memory-050, p02-threads-037, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostPageView+Accessibility.swift` | - | p03-rendering-065 (sweep) | p01-process-049, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostPageView+Drag.swift` | - | p03-rendering-065 (sweep) | p01-process-050, p01-process-051, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostPageView+TextInput.swift` | - | p03-rendering-065 (sweep) | p01-process-043, p01-process-230, p07-memory-050, p04-input-064, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostPageView.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p01-process-040 (ready), p04-input-038 (ready), p01-process-030, p01-process-042, p01-process-045, p01-process-046, p01-process-047, p01-process-048, p01-process-054, p01-process-220, p01-process-221, p01-process-229, p01-process-082, p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostPopupMenu.swift` | - | p03-rendering-065 (sweep) | p01-process-060, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostPrototype.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p01-process-225 (open, `cp/91-p01-process-225`), p01-process-100 (open, `cp/104-p01-process-100`), p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostResizeFence.swift` | - | p03-rendering-065 (sweep) | p01-process-052, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostRestartPolicy.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p01-process-081 (ready), p09-observability-104, p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/ChromiumHost/ChromiumHostSession.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`), p10-stability-088 (open, `cp/91-p10-stability-088`), p01-process-080, p09-observability-104, p07-memory-050, p04-input-066, p11-codebase-093, p14-energy-128, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostSuggestions.swift` | - | p03-rendering-065 (sweep) | p01-process-061, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostSupervisor.swift` | - | p03-rendering-065 (sweep) | p01-process-080, p01-process-091, p01-process-083, p01-process-085, p01-process-087, p01-process-222, p01-process-233, p01-process-150, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostTextInputState.swift` | - | p03-rendering-065 (sweep) | p01-process-043, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostWidgetHost.swift` | - | p03-rendering-065 (sweep) | p01-process-066, p01-process-228, p07-memory-050, p11-codebase-093, +25 sweep |
| `CEFS/ChromiumHost/ChromiumHostWireState.swift` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p07-memory-050, p11-codebase-093, +26 sweep |
| `CEFS/Shim/cmux_cef_shim.h` | - | p01-process-170 | p01-process-227 (ready), p09-observability-050 (ready), p03-rendering-042, p03-rendering-058, p03-rendering-044, p01-process-220, p09-observability-061, p09-observability-106, p09-observability-107, p14-energy-046, p14-energy-030, +26 sweep |
| `CEFShim/src/agent_url_policy.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/auth_callback_policy.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/cmux_page_path.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/command_line_switches.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/context_proxy_policy.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/devtools_message_id.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/download_state.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/external_url.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/file_dialog_state.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/helper_main.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/local_file_handoff.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/local_file_scope.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/page_scheme_registration.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/password_reveal_relay.h` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_background.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_bookmarks.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_browser.mm` | - | p03-rendering-058 (waiting) | p03-rendering-044, p01-process-032, p01-process-044, p01-process-051, p01-process-220, p01-process-060, p09-observability-061, p10-stability-162, p10-stability-163, p14-energy-124 |
| `CEFShim/src/shim_browsing_data.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_client.mm` | - | p01-process-030 (waiting) | p01-process-045, p01-process-063, p07-memory-049, p07-memory-101, p10-stability-162, p10-stability-163, p14-energy-046 |
| `CEFShim/src/shim_cookie_import.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_devtools.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_devtools_protocol.mm` | - | p04-input-091 | p10-stability-162, p10-stability-163 |
| `CEFShim/src/shim_downloads.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_extensions_ui.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_file_dialog.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_helper_host.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_internal.h` | - | p10-stability-162 (waiting) | p10-stability-163, p14-energy-046 |
| `CEFShim/src/shim_page_scheme.mm` | - | p13-webui-050 (waiting) | p10-stability-162, p10-stability-163 |
| `CEFShim/src/shim_passkeys.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_password_core.mm` | - | p01-process-061 (waiting) | p10-stability-162, p10-stability-163 |
| `CEFShim/src/shim_password_import.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_permissions.mm` | - | p01-process-062 (waiting) | p10-stability-162, p10-stability-163 |
| `CEFShim/src/shim_prefs.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_process.mm` | - | p07-memory-051 (waiting) | p10-stability-162, p10-stability-163, p14-energy-030, p14-energy-107 |
| `CEFShim/src/shim_proxy.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_site.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_webstore.mm` | - | p10-stability-162 (waiting) | p10-stability-163 |
| `CEFShim/src/shim_windows.mm` | - | p03-rendering-042 (waiting) | p03-rendering-116, p01-process-031, p10-stability-162, p10-stability-163 |
| `HOST/client/remote_shim_mirror.h` | - | p01-process-014 (waiting) | p01-process-016b |
| `HOST/src/browser_host_main.mm` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`), p01-process-041 (ready), p01-process-013, p01-process-092, p01-process-042, p01-process-046, p01-process-053, p01-process-068, p01-process-226, p01-process-150, p09-observability-104, p04-input-063, p04-input-064, p04-input-065, p14-energy-128 |
| `HOST/src/chromium_host_control.cc` | - | p01-process-012 | p01-process-020, p01-process-092 |
| `HOST/src/chromium_host_wire.h` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`), p01-process-092, p09-observability-104, p04-input-063, p14-energy-128 |
| `HOST/src/host_dispatch.mm` | - | p01-process-013 (waiting) | p01-process-019, p01-process-047, p01-process-049, p01-process-220, p01-process-221, p01-process-234, p01-process-065 |
| `HOST/src/host_mirror.mm` | - | p01-process-016 (waiting) | p01-process-017, p01-process-093 |
| `HOST/tests/chromium_host_wire_test.cpp` | - | p01-process-088 (open, `cp/94-p01-process-088`) | p14-energy-045 (open, `cp/75`), p01-process-225 (open, `cp/91-p01-process-225`), p01-process-222 (open, `cp/96-p01-process-222`) |

<!-- cefs-leases:end -->
