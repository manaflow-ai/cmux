# Classic → cmux-next: one-time migration and update handoff

Status: implemented on feat-cmux-next (launch migration, ledger, groups/windows/colors/pins,
dedupe, resume, merge after downgrade). The update-feed switch is planned here and is **not**
published. Requested 2026-10-19.

User goal: people on classic cmux (stable and nightly) update and land in cmux-next with
everything there: windows, workspaces, groups, splits, tabs, folders, browser tabs, agent chats,
settings and shortcuts. Session restore keeps working on the first launch. Upgrade, downgrade and
upgrade again never duplicate or lose anything.

## 1. Audit: what existed before this change

| Piece | Where | State before |
| --- | --- | --- |
| Session reader | `CmuxNextOnboarding/System/ClassicSessionImport.swift` | Read `session-<bundle>.json` (newest channel), 64 MB cap. Flattened all windows; dropped `workspaceGroups`, `groupId`, `customColor`, `isPinned`, window frames, selected workspace. |
| Import action | `workspace.importClassic` (palette, `cmux workspace import-classic`), `AppOnboardingServices+ClassicSessions.swift` | Manual only, never at launch (cx-rwlb). All workspaces into one window. No marker: a second run duplicated everything. |
| Live move | `session.transfer.pull` / `classic-to-next-live.py` | Moves running classic terminals; ends the classic process. Unchanged. |
| Script | `scripts/cmux-next/classic-to-next.py` | Agent-driven selection; unchanged. |
| Settings | `CmuxConfigFile.prepareDefaultURL`, `ClassicSettingsMigration`, `ClassicShortcutImport`, `ClassicPreferenceImport` | Already one-time at launch: `cmux.json` → `cmux-next.json`, renamed keys, shortcuts (`classicShortcutsImported`), link routing. Unchanged. |
| Tests | `ClassicImportTests` (13, live daemon) | Not run by any CI job: `swift-test` has no cmux-tui; `daemon-test` filter left it out; fleet suite lane never fetched cmux-tui. |

### Classic on-disk state (origin/main)

- Session: `~/Library/Application Support/cmux/session-<bundle>.json` (atomic writes, autosave
  every 8 s, on quit with scrollback), `session-<bundle>-previous.json` (copied at classic launch),
  `session-history/session-<bundle>-<ms>-w<N>-p<N>.json` (10 kept). Schema `version: 1`.
- Window: `windowId`, `frame`, `display`, `sidebar`, `tabManager{selectedWorkspaceIndex,
  workspaces[], workspaceGroups[]}`.
- Workspace: `stableId`, `workspaceId`, `customTitle`, `customColor`, `isPinned`, `groupId`,
  `currentDirectory`, `layout` (split tree), `panels[]`, `remote`, `cloudVM`, `layoutMode`.
- Group: `id`, `name`, `isCollapsed`, `isPinned`, `customColor`, `iconSymbol`, anchor fields.
  No member list: members point at the group with `groupId`, in workspace order.
- Bundle IDs: stable `com.cmuxterm.app`, nightly `com.cmuxterm.app.nightly`, rc `.rc`, staging
  `.staging`, debug `.debug[.<tag>]`.
- Also: agent journal sqlite, hook session stores in `~/.cmuxterm/`, browser history per bundle,
  WebKit data store per bundle, UserDefaults per bundle, keychain services
  `com.cmuxterm.app.surface-resume-approvals`, `com.cmuxterm.app.socket-control`.

### Update channels

| Channel | Classic | cmux-next today |
| --- | --- | --- |
| Stable | `com.cmuxterm.app`, feed `github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml` (+ `files.cmux.com/stable/`), key `avjcg…` | **Same** bundle ID, name `cmux.app`, feed and key (`release.yml` on feat-cmux-next). Stable is an in-place Sparkle update. |
| Nightly | `com.cmuxterm.app.nightly`, "cmux NIGHTLY", feed `files.cmux.com/nightly/appcast*.xml` | `com.cmuxterm.app.nightly.cmux-next`, "cmux NEXT", feed `files-next.cmux.com/nightly-next/next/appcast-arm64.xml`, own key `IOPI…`. A legacy-identity job already re-signs each NEXT build as `com.cmuxterm.app.nightly` for pre-NEXT installs on `files-next…/nightly-next/appcast-arm64.xml`. |
| RC | `com.cmuxterm.app.rc`, `files.cmux.com/rc` | Keeps classic's `.rc` identity in code; no next feed. |

## 2. Concept map, classic → cmux-next

| Classic | cmux-next | Notes |
| --- | --- | --- |
| Window (`windows[]`) | Window (registry id) | Window 1 lands in the launch window; others open new windows at their saved frame when on a screen. |
| Workspace (sidebar order) | Workspace, `slot = .bottom` in order | Name = custom title, else process/tab title, agent, folder; unique across windows. |
| `stableId` / `workspaceId` | Ledger key | Fallback: FNV digest of folder + name + panel ids. |
| `workspaceGroups[]` + `groupId` | Personal group (`workspace_group.create`), member placed with `workspace.place` | Name, color, icon (`workspace-group-icon-v1`), collapsed, pinned (`workspace-group-pin-v1`). A pinned empty group comes over once. Needs state resources. |
| `customColor` | Workspace color (`workspace.update`) | `#RRGGBB`. |
| `isPinned` | Workspace pin (`workspace-pin-v1`) | |
| Split tree (`horizontal`/`vertical`, `dividerPosition`) | Split `right`/`down`, ratio | Unchanged from the import (blueprint builder). |
| Pane `panelIds` | Pane tabs in order | Selected tab is not kept (known gap). |
| Terminal panel | Terminal tab in its folder; local scrollback replayed once | Running commands do not restart. |
| Browser panel | Browser tab on its URL | Back/forward history, zoom, profile do not come over. |
| Claude/Codex session | Agent chat resuming it (acpmux adopt) | Local only; SSH ones stay terminals. |
| SSH workspace | Workspace on the SSH host's daemon | 20 s connect limit per host. |
| Cloud VM workspace | Not migrated | Recorded as skipped; toast says so. |
| Markdown / file preview / canvas | Dropped / tabs in one pane | Toast names dropped tabs. |
| `cmux.json`, shortcuts, link prefs | `cmux-next.json`, bindings, prefs | Existing one-time imports. |
| Selected workspace per window | Revealed in window 1 | |

## 3. The migration (implemented)

Flow, at launch after `WindowManager.restore()` (so the restored registry never overwrites
placement):

1. Load the ledger: `Application Support/cmux-next/<bundle id>/classic-migration/ledger.json`
   (schema 1, atomic writes). Classic's files are never written; this folder is cmux-next's own.
2. Find the source: this build's own classic channel (`…nightly.cmux-next` → nightly), else the
   channel saved last; debug never. Try `session-<b>.json`, then `-previous`, then the newest
   archive, until one decodes.
3. Decide (`ClassicMigrationPlanner.decision`): first run, resume (ledger `inProgress`), merge
   (classic saved since the last run), or skip (same save, classic running, no session, ledger
   from a newer schema or unreadable, disabled).
4. First contact with a tree already in use (launch made no first workspace): record classic's
   workspaces as seen (baseline), make nothing. The action still brings them over.
5. Plan (`ClassicMigrationPlanner.plan`): per window, workspaces not done; duplicates and Cloud
   VMs skipped; half-made workspaces of a cut-off run listed for cleanup; groups reused while their
   cmux-next group exists.
6. Back up the files read (`backups/<UTC stamp>/`, 5 kept), mark `inProgress`.
7. Make groups, then each workspace: ledger `pending` → `created` (with its id) → `done`, saved
   after each step. Then color, pin, group placement.
8. Mark `completed`. Reveal classic's selected workspace; close the launch's empty New Tab page
   workspace if window 1 received workspaces. Toast what came over and what stayed.

`workspace.importClassic` runs the same code in manual mode: it brings back only workspaces whose
cmux-next copy is not open, and says "Every workspace from classic cmux is already open here."
when nothing is missing. Runs never overlap.

The cmux Classic card in Settings › Import runs that same import (`OnboardingHandlers.importClassic`)
as a tracked job: progress is the share of the plan's workspaces handled, and it ends with
"Imported N sessions" (N workspaces this run opened, 0 on a second run). The card stays in Settings
while classic has a saved session, as Import Again once everything is here; Home and New Tab show
it only while workspaces are left to bring. Cancel in the preview removes the job; a quit leaves it
paused for Resume, which runs the import again.

Switches: on by default only for shipping bundle IDs (stable, nightly, nightly.cmux-next, rc,
staging). `CMUX_NEXT_CLASSIC_MIGRATION=0` turns it off, `=1` turns it on for dev builds.

## 4. Edge cases

| Case | Behavior | Test |
| --- | --- | --- |
| First launch after the update | All windows, workspaces, groups, colors, pins come over; empty New Tab page closes. | `theFirstLaunchBringsWindowsGroupsColorsAndPins`, `theFirstRunBringsEveryWindowInOrderWithItsGroups` |
| Relaunch | Same save → skip; nothing made. | `aRelaunchAndTheActionMakeNoDuplicates`, `theSameClassicSaveRunsOnce` |
| Already migrated, person closed some here | Automatic: none come back. Action: closed ones come back. | `aFinishedRunMakesNothingAgain`, `aManualRunReopensOnlyWhatWasClosedHere` |
| Downgrade to classic, then upgrade | Only workspaces with new keys come over, into the same groups. Changes classic made to migrated ones are not merged (cmux-next's copy wins). | `aReUpgradeMergesOnlyWhatClassicMadeMeanwhile`, `aReUpgradeMergesOnlyNewWorkspacesIntoTheSameGroup` |
| Downgrade: classic's own restore | Classic reads its untouched session file and restores as before. | `theFirstLaunch…` (file bytes unchanged), `backupsCopyAndNeverTouchClassicFiles` |
| Group deleted here before a merge | New members get a new group. | `aGroupDeletedHereIsMadeAgainForNewMembers` |
| Interrupted midway (quit, crash, power) | Ledger `inProgress`: next launch resumes, closes the half-made workspace, makes it once. | `aRunCutOffMidwayResumesWithoutDuplicates` (both suites) |
| Both apps installed, classic running | No first run or merge while classic runs (it may still save); a resume still finishes. "Running" (`ClassicRunningProbe`) is classic's launch sentinel `~/.local/state/cmux/lifecycle/<bundle>/running.sentinel` (written at launch, removed at the end of a clean quit) plus a save under 90 s old; no sentinel is a classic that quit, an old save with a sentinel one that crashed. A classic older than the sentinel counts as not running (a later save still merges). | `whetherALaunchRuns`, `whileClassicRunsNothingComesThenItsQuitSaveMigrates` |
| Sparkle update relaunch | Classic's quit save is seconds old; the first launch still migrates. (Before 2026-10-20 a save under 90 s old counted as "classic running", so the first launch after every update migrated nothing.) | `theFirstLaunchBringsEverythingOnce` (all profiles), `onlyAnotherProcessWithClassicsIDIsClassic` |
| Classic crashed or was force quit | Its last save is an autosave without scrollback; each terminal's scrollback comes from classic's checkpoint (`session-<bundle>-scrollback/<panel>.json`). A quit save's own scrollback always wins. | `aCrashedClassicsScrollbackComesFromItsCheckpoints`, `aQuitSavesOwnScrollbackWins` |
| Both running, same bundle ID (stable) | Cannot happen after Sparkle replaces the app; a second copy elsewhere counts as "classic running". | design only |
| cmux-next in use before this build | Baseline: recorded, nothing made; later merges bring only new classic work. | `aBaselineRecordsWithoutMaking` |
| Damaged session file | Next copy (`-previous`, archive) is tried; if none reads, nothing is made, launch is fine, a later good save migrates. | `aDamagedSessionFileIsLeftAndRetriedOnceClassicSavesAgain`, `aFileThatIsNotASessionIsAnError` |
| Damaged ledger | Moved aside; automatic runs stop (cannot dedupe); the action still works. | `aDamagedLedgerIsMovedAside` |
| Ledger from a newer cmux-next (next downgraded) | Left alone; automatic and manual runs stop. | `aNewerLedgerIsLeftAlone` |
| Multiple windows | One cmux-next window each; frame kept when on a screen. | first-launch tests |
| Same `stableId` twice | First wins. | `theFirstRunBringsEveryWindow…` |
| Snapshot without ids | Key from `workspaceId`, else a stable digest. | `keysFallBackToWorkspaceIDThenADigest` |
| Missing folder | Opens the home folder (existing). | `aWorkspaceWhoseFolderIsGoneStillComesOver` |
| SSH host down | Every host starts connecting at the run's start; a workspace whose host is not up at its turn is made after the local ones, so local workspaces never wait. One that never connects is left for the next manual run; toast says so. | `anOffSSHHostDoesNotHoldBackLocalWorkspaces` |
| Cloud VM | Skipped once, recorded; toast says so. | first-launch tests |
| Huge session | 512 MB cap (classic reads its own with none; a heavy quit save passes 64 MB at about 150 full terminals); one workspace at a time, ledger saved per step, so a slow run resumes. | `aHeavyQuitSaveOverSixtyFourMegabytesStillReads`, `aHugeSessionComesOverOnceWithTheFirstWindowFirst` (520 workspaces) |
| Title over 1024 bytes | The daemon refuses longer names: cut at a character (896 bytes before a branch or number is added), still unique. | `aNameOverTheDaemonsLimitIsCutAndStaysUnique`, `messy` profile |
| Resumed run | **Open:** the workspaces it remakes come back at the end of their sidebar container, not at their classic place. Two attempts (personal-index moves; `SidebarBridge.place` against the computed sidebar) did not reach the sidebar order, which the daemon's sidebar document keeps. A merge after a downgrade appends, as classic did, so its order holds. | known issue in `aRunCutOffMidwayFinishesWithoutDuplicates` |
| Several windows | One window after another: making windows side by side was five times slower on the fleet (0.6 against 3 workspaces a second). On a busy fleet Mac mini 512 workspaces took about 7.5 minutes (about 1.1 a second); the first window shows within 4 s and the sidebar fills in as they come. | `aHugeSessionComesOverOnceWithTheFirstWindowFirst` (512, in phases) |
| More terminals than macOS PTYs | macOS hands out at most `kern.tty.ptmx_max` (511) PTYs, shared with every process; at 512 workspaces about 460 opened and the rest failed "PTY capacity exhausted" and stay pending for Import from Classic. **Open:** needs terminals that start on first show for background migrated workspaces (a product decision); classic had the same limit. | known issue in `aHugeSessionComesOverOnceWithTheFirstWindowFirst` |
| Only `-previous` left | The channel still counts by its copy. | `aChannelWithOnlyItsPreviousCopyIsStillFound`, `onlyThePreviousCopyLeftStillMigrates` |
| Nightly reads stable's file | Own channel first, else newest; debug never. | `theOwnChannelIsPreferredThenTheNewest`, `candidatesAreTheFileItsCopyThenTheNewestArchive` |

## 5. Update handoff plan (not published)

### Stable

Nothing to change in Sparkle: cmux-next stable is `com.cmuxterm.app`, `cmux.app`, same feed and
EdDSA key, so the next stable release that ships cmux-next is an ordinary update for classic users.
Gate before that release:

1. The last classic stable (`main`) and the first cmux-next stable must both have
   `minimumSystemVersion` ≤ the user's macOS; cmux-next's floor is 14.0. If the floor rises, commit
   `scripts/cmux-next/legacy-appcast-item.xml` for the final classic build
   (`skills/cmux-release/references/cmux-next-update-floor.md`).
2. Per-arch feeds: classic stable rewrites the feed to `appcast-<arch>.xml`
   (`UpdateFeedResolver.swift`). cmux-next stable publishes only `appcast.xml` today. **Before the
   switch release, `release.yml` on feat-cmux-next must also publish `appcast-arm64.xml` and
   `appcast-x86_64.xml` (or classic's last release must stop rewriting)**, otherwise classic
   clients keep reading the last classic per-arch feed and never see cmux-next.
3. Staging check: publish the candidate appcast to a staging key (`files.cmux.com/staging-handoff/`),
   point a classic stable build at it with the `SUFeedURL` default override
   (`defaults write com.cmuxterm.app SUFeedURL …`), update, and confirm: app relaunches as cmux-next,
   migration toast, windows/groups present, a second launch makes nothing.
4. Then the production release as usual (`/release`), approved by the user's standing deploy rule.

### Nightly

Classic nightly users (`com.cmuxterm.app.nightly`, `files.cmux.com/nightly/appcast*.xml`) need the
cmux-next nightly under their bundle ID. The legacy-identity jobs (`nightly.yml`
`sign-/verify-/publish-nightly-identity-legacy`) already build exactly that artifact. Plan:

1. Add a publish target for the legacy-identity artifact to `files.cmux.com/nightly/appcast*.xml`
   (all three arch names point at the arm64 item; Intel classic nightly users get no update, as
   NEXT is Apple silicon only), behind a repo variable `CLASSIC_NIGHTLY_HANDOFF` (default off).
2. Signing key: the classic nightly feed is checked with classic's key (`avjcg…` unless
   `NIGHTLY_SPARKLE_KEY=nightly`); the legacy-identity item must be signed with that key, not the
   NEXT key.
3. Staging check as for stable, against a staging prefix, then flip the variable.
4. Classic's own nightly publisher (`main` nightly.yml) must stop publishing to that feed once the
   variable is on, or the two race.

### What does not move with the bundle ID

- Keychain items are keyed by service name and the app's code-signing designated requirement
  (Team ID `7WLXT3NR37`), so the same bundle ID and team keep access; a new bundle ID would prompt.
- TCC grants (Accessibility, Screen Recording, Full Disk Access, Automation) are keyed by bundle ID
  and signature: same bundle ID keeps them only if the designated requirement matches.
  `cmux.next-dev.entitlements` (nightly-next, no provisioning profile) differs from classic's;
  verify on the staging check that Accessibility survives, else the toast should point to
  System Settings.
- Login items: classic registers none. cmux-next's own helpers are unchanged.
- UserDefaults: same domain per bundle ID; cmux-next reads classic's keys (shortcuts, prefs) and
  writes its own. Classic after a downgrade reads the same domain: keys cmux-next writes must not
  break classic's readers (see risks).
- WebKit website data (cookies) is per bundle ID: same ID keeps WebKit cookies; the Chromium
  engine's profile is separate (browser import flow).

## 6. Open risks

- Shared UserDefaults domain on downgrade: a key cmux-next writes with a type classic reads
  differently could misbehave in classic. Not audited key by key.
- Selected tab per pane, browser back/forward history and profile, canvas positions, workspace
  descriptions, status/log entries, notifications and unread state do not come over.
- The per-arch stable feed gap (5, Stable step 2) blocks the stable handoff until fixed.
- Groups need a daemon with state resources; an older daemon brings workspaces over loose.
- A workspace made between `createWorkspace` returning and the `created` ledger write (one daemon
  round trip) is not closed by a resume; it would remain as one extra workspace.
- Closing the launch's empty New Tab page assumes the person did not start using it during the
  first seconds of the migration.

## 7. Upgrade simulations (2026-10-20)

`ClassicUpgradeSimulationTests` and `ClassicUpgradeHugeSimulationTests` (CmuxNextAppTests, live
daemon, fleet only) write a simulated classic user's session in classic's schema
(`ClassicUpgradeProfile`) into a scratch Application Support folder and run cmux-next's launch on
it (`ClassicUpgradeSimulator`). Each run checks: every workspace that can come over did (ledger
`done`, workspace present), none twice, one cmux-next window per classic window in classic's order,
names, split panes and tabs per pane, groups and their collapsed state, pins, colors, no modal or
sheet, the first window before the migration's work (10 s budget), a migration time budget, and
classic's folder byte for byte unchanged (SHA-256 of every file). Then a relaunch and the import
action make nothing more.

Profiles: fresh, small, many groups (12, one pinned and empty), nested splits (depth 6, three tabs a
pane), browsers and viewers (viewer-only workspace stays), three windows (one off screen),
pre-2026-06 schema (no ids, groups or panel types), messy (unknown and mistyped fields, dangling
group, group without id, duplicate `stableId`, missing folder, odd names, Cloud VM, websocket
remote, null layout, empty split side), huge (520 workspaces, 4 windows, 30 groups). Paths: classic
running then quitting, damaged session with good `-previous`, both damaged with an archive, only
`-previous` left, a run cut off midway, downgrade and re-upgrade with a new group, the import action
during the launch run, SSH hosts that are off. Lines starting `CLASSIC-SIM` in the fleet log give
the timings.

