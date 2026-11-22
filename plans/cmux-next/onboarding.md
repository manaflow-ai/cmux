# Onboarding from first principles (cx-aha)

Status: plan, 2026-10-09, hq-ff (owner of cx-aha). Base: feat-cmux-next 741da93fa310. Mock:
`onboarding-mock.html` next to this file. Inputs: chief brief (onboarding-first-principles.md),
audit (N1-N16, O1-O15), Lawrence 2026-10-09 ("our onboarding sucks", "Make it yours", "no
importing accounts"). `plans/cmux-next/decisions.md` does not exist on this branch; the Ctrl-1..9
decision is R85 (`ShortcutDigitScheme.swift`), and the decisions below are recorded here. Paths are
under `Packages/macOS/CmuxNext/Sources/` (S/) or `webviews/src/agent-session/acpmux/` (W/).
"cmux.json" means the cmux-next config file, `~/.config/cmux/cmux-next.json` (`CmuxConfigFile`).

## 0. Scope change (Lawrence, 2026-10-09, after this plan)

"i do not want new window. no import flow. except for import from browser which is fine. we should
just drop user into main screen asap. when they make a browser they will see option to import
browser data." This replaces sections 4, 5 and 7's first-run page and the has-data gate:
- Landing A: a launch never opens the onboarding window; the first workspace opens on the normal
  New Tab page. The first browser tab of a launch shows one quiet card, "Import bookmarks, history
  and passwords from <browser>", with Not Now and Import (`BrowserImportOfferService`, it replaces
  the cx-367y cookie card). Not Now and a finished import end it for good, per channel. Import
  opens the single-step Import from Browser window with those kinds checked.
- Landing B: delete the wizard and its steps (Accounts, Projects, Classic Sessions, Chats, First
  Task, Theme, Default Browser, Number Keys), the gallery, Continue Setup, the welcome checklist and
  Import and Sync. One single-step window host stays for Import from Browser and Computer Use
  setup. No first-run page, no `FirstRunGate`. "Make it yours" (section 6) stays for later.

## 1. Problem

Lawrence's screenshot (23:51 PDT): a modal "Accounts 1 of 4" over an app he already uses (chats,
projects). It lists 6 providers. 4 say "Signed in" and still show "Re-authenticate"
(`AccountsStrings.swift:41-43` titles every non-missing row that way). 2 say "Not found" with
"Get Key". Skip and Continue have odd focus rings. The step teaches nothing and asks nothing he
needs. Code facts: the first run is a 640x520 Swift window, `firstRun = [.accounts, .tabKeys,
.classicSessions, .chats, .importData]` (`OnboardingModel.swift:18`). It opens from the state file
alone, so a user with data gets it.

## 2. Goal and metric

Goal: a new user sends a first agent prompt in a real project in under 30 s, and answers no question
that the app can answer itself.

Metric: time-to-first-prompt (TTFP) = first main window visible -> first prompt accepted by acpmux,
on the first-run page. Also kept: the furthest stage reached (`shown`, `projectPicked`,
`signInShown`, `signInDone`, `promptSent`), the first action kind (`prompt`, `shell`, `url`,
`dismiss`), and whether "Make it yours" was opened.
- Local: one `firstRun` object in the per-channel state file
  (`cmux/onboarding/<bundle id>.json`), plus a `DebugTimings` mark `onboarding.firstPrompt` read by
  `debug.timings`, and a debug control method `debug.onboarding` (record + gate inputs).
- Telemetry: none. cmux-next has no analytics and no consent setting. The same record goes out
  only after a consent setting exists (open decision 1).
- Pass bar: p50 TTFP < 30 s over 5 scripted fresh-profile runs on cmux-lawrence-2 (signed-in
  harness), < 60 s with one inline sign-in.

## 3. Principles

1. Detect, do not ask: projects, harnesses, sign-in state, theme come from disk and acpmux.
2. Ask at the moment of need: sign-in when the chosen harness needs it; browser import when a
   page needs a cookie (cx-367y card); Computer Use when an agent first needs it.
3. Never block: no modal, no sequence, no step counter. The first run is the real New Tab page.
4. Never show to a user with data, and never again after the first action or dismiss.
5. One screen, one decision: where to work, then type.
6. Teach in context: hints on the real surface (Cmd-hold hints, one tip at a time).
7. No network wait on first paint: detection fills in behind the page.
8. Every change must move TTFP or the drop-off stage.

## 4. Who sees what

Has-data rule (pure `FirstRunGate.decide`, evaluated once per launch after the daemon snapshot in
`WindowManager.restore`). The first-run page shows only when ALL are true:
1. The state file is not finished (`takeLaunchShow() != .none`).
2. `FirstWorkspace.isNeeded` was true at this launch (no workspace of the user's own).
3. acpmux history has 0 sessions (`services.history.agents.sessions`).
4. cmux.json was not seeded from classic `cmux.json` and is `{}` or absent before seeding
   (`CmuxConfigFile.swift:38-60`; the gate reads the seed source, not file existence).
5. No classic session snapshot (`ClassicSessionImporter`, `session-<bundleID>.json`).

Claude Code, Codex, Pi and OpenCode history in `~/.claude`, `~/.codex` and similar does NOT count
as data: it is detection input (projects, signed-in harnesses). A new cmux user with Claude history
is the main target.

When any check fails: `markDone(completed: false, reason: "existing-data")` in the same queued
write, and nothing shows, now or later. The record keeps `version: 1`, so nobody who finished
before sees anything.

- Fresh user: the launch's fresh workspace (`freshWorkspaceID`) shows the New Tab page in its
  first-run variant (section 5). No other window.
- Existing user (any check fails): the app as it is. No window, no banner, no badge.
- Classic cmux user with no cmux-next workspaces: no first run. The normal New Tab page shows one
  row, "Open your N cmux workspaces", from Leo's idempotent importer (PR 18602, cx-aha.5). That
  row is data, not onboarding, and it leaves after use or dismiss.
- Later: Help > Continue Setup… (`onboarding.continueSetup`), the palette ("Make It Yours…",
  the retitled `palette.welcomeChecklist`, CLI `settings onboarding`) and Settings > General all
  open the "Make it yours" section (section 6). Nothing ever re-runs the first-run page.

## 5. The one screen: first-run New Tab

One implementation: `W/newtab/NewTabScreen.tsx` with the cx-e2aa layout (project picker and
model/effort picker on top, type-to-start, omnibar visible). The first run adds a `firstRun`
handshake field (`NewTabHost`). It changes only three things on the page:
- A heading: "Where do you want to work?" (one line, no logo animation).
- A status line under the prompt (sign-in, no harness, offline). It shows only when it has
  something to say.
- One quiet link at the bottom: "Make it yours".

Project picker (`ProjectChooser`, data from `project.list` = `RecentProjectScan` +
`OnboardingService.projectFolders` from `AgentProjectScan`):
- Default pick: the folder of the newest agent session (Claude/Codex/Pi/OpenCode). If there is
  none, nothing is picked and the chip reads "Private folder" (`AgentHome`). Never `~` (cx-nn3e).
- Git repos found under the conventional roots are listed below, not auto-picked.
- "Choose Folder…" is the last row. The panel opens anchored to the page, never a second dialog.
- The start folder comes only from the one resolved `{cwd, kind}` of cx-9aps. Onboarding computes
  no cwd. Trust is asked once, before start (`folderTrust.ts`), with no error card.

Harness and model chip: harnesses come from acpmux `_acpmux/harnesses`. The first run ranks
installed + signed in (`ProviderDetector`) > installed > the rest. Ties keep acpmux order. Model =
the harness default, drawn as the resolved model when known (`defaultChoice.ts`). After the first
run, `newTab.lastAgent` decides as today.

Inline sign-in (moment of need): when the chosen harness is `missing` or `expired`, the status
line reads "Claude Code is not signed in. [Sign in]" before the user sends. Sign in runs the
catalog's `auth.login` in a terminal split under the page (the existing `App.tsx:1217` path, also
used by "Sign in again"). If the user sends before sign-in finishes, the prompt is held
(`heldPrompt.ts`) and sent when the status flips. The status re-checks on terminal exit and on a
change to the credential file. API-key providers show "Add key" (opens the console page).

Finish: the first prompt accepted by acpmux finishes onboarding (`markDone(completed: true)`,
`firstRun.action = prompt`). A `!` shell, a URL or a search also finishes it with that action.
"×" on the heading dismisses (`completed: false`). Closing the tab or quitting records nothing, so
the next launch shows the page again (no launch counting; `launchesLeft` retires).

## 6. "Make it yours" (optional, skippable)

Where: a section of the React Settings page, `cmux-page://cmux.settings/#make-it-yours`. It is
one page of existing schema rows plus two new controls, with live preview
(`cmux.settings.preview`). Every control writes through `SettingsController.setSetting(by: .user)`.
`CmuxConfigFile` edits only the paths it gets, and comments survive. Picking the default value
removes the key. Revert: each row's "Reset to Default" in Settings. "Undo all" in the section
restores the key set from when the section opened (it removes keys that were absent then). The
section is a list of controls, not a wizard.

| Control | Choices | Keys written | Live apply |
| --- | --- | --- | --- |
| Keyboard style | cmux (default), VS Code-like (new preset), Terminal/iTerm-like, tmux-like (Ctrl-B prefix) | `shortcuts.bindings.<actionID>` diff vs defaults only (`ShortcutKeymapPreset`, `SettingsController+Keymap`); bindings set by hand are kept and listed | config watcher -> registry, next key press |
| Ctrl-1..9 select | Tabs (default) / Spaces | `space.selectByNumber`, `selectSurfaceByNumber` (R85 `ShortcutDigitScheme`; Tabs writes nothing) | same |
| Theme | 9 curated Ghostty themes first, then every Ghostty theme (`ThemeCatalog`), "Use my Ghostty config" | `appearance.theme` (name or `light:A,dark:B`); unset = Ghostty config | `terminalTheme.preview` while hovering/arrowing, write on pick |
| Window opacity / blur | slider 0.6-1.0; frosted, glass, glass-clear, none | `appearance.backgroundOpacity`, `appearance.backgroundBlur` | Ghostty override lines (`GhosttyRuntime+Background`) + reload |
| Font and size | installed fixed-pitch families; 9-24 pt; interface size 10-16 pt | `terminal.fontFamily`, `terminal.fontSize`, `appearance.metrics.chromeFontSize` | `GhosttyRuntime.fontOverrideLines` + reload |

Ghostty push-back: theme, opacity, blur and font are Ghostty settings. cmux writes override keys
in cmux.json and never rewrites the user's Ghostty file (it may be a dotfiles symlink). An unset
key means the Ghostty value applies. The section links "Edit Ghostty config" for everything else
(cursor, padding, keybinds inside the terminal). No color editor is built.

The tmux-like preset binds cmux actions behind Ctrl-B. A requirement for the preset: Ctrl-B twice
sends one literal Ctrl-B to the terminal (tmux `send-prefix`), so a real tmux inside still works.

## 7. Cut, kept, moved

Cut from the first run (all with reasons):
- The Accounts page as a step: detection gives the same facts. A status line at the moment of need
  replaces it. Settings > Accounts stays.
- "Re-authenticate" on signed-in rows: a signed-in row shows "Signed in" and no button. Sign out
  and switch live in a row menu in Settings > Accounts only.
- The 1-of-4 Swift wizard as first run: `firstRun = []`. The window stays for the standalone
  entry points below until they move to React.
- Account import of any kind, and Import from Browsers in the first run: Lawrence's rule. It stays
  at File > Import from Browser… and in the cookie card on a page that needs it (cx-367y).
- Classic Sessions and Chats steps: users with that data never see a first run (section 4). Leo's
  importer (cx-aha.5, PR 18602) stays and moves to the New Tab row and Import and Sync. Leo is the
  owner; this plan changes only the entry point. He gets the plan before slice S6.
- First Task (sample task in a made-up folder): the first run is a real task in a real project.
- Theme and Default Browser steps: the theme moves into "Make it yours". Default Browser stays in
  the palette and Settings.

Kept: the per-channel state file, `OnboardingStateQueue` and the presenter (phase 0, cx-aha.7);
D3 landing on New Tab (cx-aha.2); the Ctrl-1..9 writer (cx-aha.1), now in "Make it yours" and as
a tip. The tip shows once, when the user first has 2+ Spaces: "Ctrl-1…9 select tabs. Change…".

Computer Use (cx-aha.6): exactly one implementation (`ComputerUseSetup` + its step view), opened
by one action, `palette.computerUse.setup`. Its entry points: the Settings > Computer Use card, the
palette, and an inline card in the agent pane when an agent first calls a computer-use tool without
grants ("Computer Use needs Screen Recording and Accessibility. [Set up]"). It is not in the first
run and not in "Make it yours".

## 8. Edge cases

| Case | Behavior |
| --- | --- |
| Offline | The page paints from local data. Sign-in detection is local files. The status line says "Offline: the agent cannot reach its service" only after a send fails. The prompt is kept. |
| No git repos, no agent history | Chip = "Private folder". The prompt works there. Choose Folder… is one row away. |
| No harness installed | Status line: "No coding agent found. [Add an agent]" (`palette.addHarness`). The `!` terminal and the browser work. |
| acpmux slow or down | The harness chip shows a spinner. Typing is kept. Send waits for the host (existing `HostError` copy), no blank page. |
| Small screen / 200% scale | The page is the responsive New Tab page. The fixed 640x520 window (N13) is gone from the first run. |
| Reduce Motion / Reduce Transparency | No first-run animation. The opacity/blur controls show disabled with "Reduce Transparency is on". The page is opaque (N16). |
| VoiceOver / keyboard only | Focus starts in the prompt. Tab order: project chip, harness chip, prompt, status button, Make it yours. Every control is a Base UI widget (cx-aha.3). The VoiceOver pass is cx-aha.4. |
| MDM | A managed key shows locked in "Make it yours" (`SettingWriter` guard). A managed-disabled feature hides its control (`DisabledFeatures`). |
| Second launch before any action | The page shows again (it is the New Tab page). |
| Dev builds | Per-channel state: a DEV dismiss does not hide NIGHTLY (N4). |

## 9. Decisions and the strongest objection to each

- D1 The first run is the real New Tab page, not an onboarding window. Objection: no
  orientation, a user does not know what cmux is. Answer: the page shows agent, terminal and
  browser as live choices, and the first prompt teaches more than slides. TTFP and the drop-off
  stage decide if one more line is needed.
- D2 Has-data users finish silently. Objection: classic users miss what is new. Answer: they get
  the bring-over row and "Make it yours"; a wizard over data is the bug Lawrence reported.
- D3 Auto-pick only the newest agent-session folder, else the private folder. Objection: a wrong
  pick lets an agent edit the wrong code. Answer: the pick is a folder the user already ran an
  agent in, the chip is in view above the prompt, and trust is asked before start.
- D4 Sign-in is inline at the moment of need. Objection: failing at send is worse than a checklist.
  Answer: the status is known when the harness is chosen, before the send. The prompt is held,
  not lost.
- D5 "Make it yours" lives in Settings. Objection: Settings feels like work. Answer: one section
  of 5 controls with live preview, and the same rows revert it. Two implementations would drift.
- D6 Theme, opacity and font are cmux override keys, not Ghostty file edits. Objection: two
  sources of truth. Answer: unset = Ghostty wins, and cmux never edits a file the user owns.
- D7 Browser import leaves the first run. Objection: switchers from Arc or Chrome want bookmarks
  on day one. Answer: Lawrence ruled out account import; the cookie card asks when a page needs it.

## 10. Slices (red test commit first, then fix; all builds and tests on cmux-lawrence-2 via nx-remote)

| Slice | Content | Frozen paths / tokens |
| --- | --- | --- |
| S1 | `FirstRunGate` (pure) + `reason` and `firstRun` fields in `OnboardingStateFile.Record`; the gate in `WindowManager.restore`; Swift first-run window no longer opens | none |
| S2 | First-run variant of `NewTabScreen` (heading, status line, link) + `firstRun` handshake (`NewTabPage.swift`); project default per D3. Needs cx-e2aa pickers and cx-9aps resolver first | none (agent-pane strings catalog only) |
| S3 | Harness ranking by sign-in; inline Sign in + held prompt; status re-check | none |
| S4 | Finish on first action; `DebugTimings` mark; `debug.onboarding` control method | CORE only if the control method list is CORE-owned |
| S5 | "Make it yours" section; VS Code-like `ShortcutKeymapPreset`; tmux double-prefix pass-through; Undo all | SETTINGS (schema, page layout, `webviews/src/pages/settings`, `ShortcutKeymapPreset`); CORE for the dispatcher pass-through |
| S6 | Retitle `palette.welcomeChecklist` -> "Make It Yours…"; Continue Setup opens the section; `firstRun = []`; delete First Task and the Accounts step wiring; signed-in rows lose Re-authenticate; New Tab bring-over row (Leo) | catalog (`CmuxNextActions/Catalog`, ActionCatalog.xcstrings); SETTINGS (React Accounts rows) |
| S7 | Number Keys tip; Computer Use inline card in the agent pane | none |

No slice adds or removes a module or an Xcode target, so no slice needs the pbxproj or
`Package.swift` token. Every new string goes in English and Japanese.

## 11. Tests

Red first, behavior only (no source-shape tests).
- Swift Testing: `FirstRunGate` table (each of the 5 checks alone flips the result; Claude history
  alone does not); state record round trip with `reason`; finish on each action kind.
- Vitest: first-run render (heading, status line variants, link); default project per D3 (never
  `~`); held prompt is sent once when the status flips; harness ranking.
- Settings: each "Make it yours" control changes only its own keys (byte diff of a JSONC fixture
  with comments); picking the default removes the key; Undo all restores the file byte for byte;
  a preset keeps a hand-set binding.
- Real app on cmux-lawrence-2 (fresh `CMUX_NEXT_ONBOARDING_STATE`, `CMUX_NEXT_CONFIG_FILE`, an
  empty daemon state and a HOME with only a Claude login and two repos):
  1. Fresh profile: screenshot of the first-run page, type a prompt through the debug socket,
     `debug.onboarding` shows `promptSent` and TTFP. Run 5 times for the p50.
  2. Signed-out harness: the status line shows before send, sign-in completes, the held prompt is
     sent.
  3. Existing data (a profile with workspaces and chats): no onboarding window
     (`debug.windows`), a plain New Tab page, record `reason: existing-data`.
  4. Classic snapshot only: the bring-over row, no first run.
  5. "Make it yours": each control applies live (screenshot before and after), config diff shows
     only its keys, Undo all restores.

## 12. Open decisions (Lawrence only)

1. Telemetry for TTFP and drop-off (privacy/legal). Default: local only. Nothing is sent until a
   consent setting exists, which is a separate decision.
2. The heading copy, a brand choice. Default: "Where do you want to work?", no logo.
3. The name of the VS Code preset (third-party trademark). Default: "VS Code-like", no logo.
