# Settings: audit and information architecture

Audit of origin/feat-cmux-next at 201a5f169f9, from a code read plus a cua-driver tour (cmux-cua's engine) of a tagged DEV build. Fleet job 3acd17443d7c6abbf1e11fa8 was a local-backend build; its artifact was verified by sha256 on the capture Mac.

## Where it stands

The shell is already flat:
- one window, a sidebar of 10 pages and one scrolling page each;
- no NavigationStack, no pushed sheets, and no Back button anywhere;
- search at the top of the sidebar, editing results in place.

So the problems are not depth. They are what is missing, what is misplaced, and how hard things are to reach.

**What the tour showed** (captures below; Accounts omitted because it shows a real email)
- Searching "font" finds only shortcuts (Increase Font Size and so on); there is no font setting to find.
- Searching "theme" lists eight shortcut rows and one real setting (Window Background opacity). The theme picker is not indexed.
- Terminal is a dead end: "Fonts, colors, cursor and keybinds are Ghostty settings", plus a button to open that file.
- Appearance leads with a "Room | Workspace | Terminal" switch over several hundred Ghostty themes. "Room" is jargon on a first visit, and the app theme itself is not there.
- Notifications opens on five dismissal rules before Banners and Sound.
- General opens on History > Record Terminal Commands.
- At the default window size, most pages scroll below the fold.
- Cmd-, sent by cua-driver did not open Settings, while the app menu's Settings… did. To verify by hand: a real Cmd-, may well work, and the driver's synthetic key may not reach the menu.

**Missing UI for the things people change first**
- App theme (`appearance.theme`) has no Settings control. It is set only by onboarding. Settings > Appearance picks room, workspace and terminal themes.
- Terminal font family and size have no UI anywhere; you hand-edit cmux.json or the Ghostty config.
- Interface size and Base Keymap are palette-only. The keymap switch also confirms through an NSAlert.
- Default shell and default agent/harness have no surface at all.

**Order fights frequency**
- General opens on History, and the newest useful row (New Tab Opens) sits under Window.
- A 9-row Columns group of niri tunables (sticky edges, minimum pane sizes) ends the page.
- Notifications is 18 rows: three per-source dismissal overrides and 8 attention-ring details, all at the same level as the two settings most people want (banners, sound).

**Search covers only half the window**
- It matches schema rows and shortcuts.
- It skips the theme picker, Accounts, Rooms, Machines, browser profiles, Advanced, and every action button (Import from Browser, Onboarding…, Extensions).
- It filters the page into results, but cannot jump to a setting on its page.
- Deep links (`openSettings section:`, CLI `app settings`) reach a page, never a setting.

**Not reachable from the feature itself**
- No context menu has "Settings for this". The only right-click settings are theme and notification mute.
- The palette's settings source (`SettingsPaletteProvider`) exists but is not wired: `PaletteSourcesBridge` passes none.
- Action buttons that need an argument (Rename Room, Set Room Theme) hand off to the palette's argument collector, so clicking one throws you out of Settings.

**Interruptions and confirmations**
- Reset All asks "are you sure".
- Base Keymap raises an NSAlert.
- Both have undo-able alternatives.

**Several write paths, two sources**
- The window and the new tab page write through the validated `setSetting`.
- The palette handlers use typed setters, and some write raw paths with no schema check: focus ring, sticky column and notification dismissal.
- Density is written three ways and theme five ways.
- cmux.json is the store for preferences. Per-object state lives elsewhere:
  - room and workspace themes in the daemon;
  - browser profiles, terminal themes, debug tunables and onboarding each in their own file;
  - Sparkle settings in UserDefaults.

## Proposed IA

Rules:
1. At most one level. A sidebar of pages, one scrolling page, and **inline expanders** for detail. No sheets, no pushes, no "Back".
2. **Most-used first on every page**, detail behind a "More…" expander that remembers its state.
3. **Search finds anything and jumps to it.**
   - It indexes schema rows, custom cards (theme, accounts, profiles, machines) and action buttons.
   - Return or click opens the setting on its page, scrolls it into view, and highlights it for a moment (a steady highlight under Reduce Motion).
   - The same jump is a deep link: `openSettings setting:<key>` and `cmux app settings --setting tabs.newTabKind`.
4. **Every setting is reachable from its feature.**
   - Right-click on a terminal, browser tab, agent tab, sidebar row or notification gets "Settings for This…", which jumps to the right group.
   - The palette lists "Settings: <title>" for every row, and toggles booleans in place.
5. **No confirmations, undo instead.**
   - Reset All and Base Keymap apply at once and offer Undo, which restores the previous cmux.json snapshot.
   - Arguments for action buttons are collected inline, never in the palette.
6. **One write path:** every surface writes through `setSetting`, so cmux.json stays the single source and the file is the documentation.
7. **Defaults that make the window optional:** same-kind new tabs, the theme picked at onboarding, the system font size, banners on and sound off.

### Pages (8, down from 10)

| Page | Top (always shown) | More… (inline) |
|---|---|---|
| General | New Tab Opens, When Quitting, Titlebar, Action Rail | History, Columns (all 9) |
| Appearance | App theme (new), Density, Interface size (new), Motion | Panes, Focus ring, room/workspace/terminal themes; "Customize…" opens the appearance studio (cc-pane-chrome owns it) |
| Terminal | Font family and size (new), Default shell (new) | Open Ghostty config |
| Browser | Default engine, New tab page, Bookmarks bar, Import from Browser | Profiles (expanders), Memory, Remote localhost |
| Agents (new) | Default agent, Computer Use | Agent accounts summary |
| Notifications | Banners, Sound, Dock badge, Quiet hours | Dismissal per source, Attention ring (8) |
| Keyboard | Base keymap (with undo), search-first shortcut list | |
| Accounts & Devices | Accounts, Machines, Rooms & Profiles as three cards on one page | |
| Advanced | cmux.json path, Problems, Reset All (undo) | |

## Two DEV variants to compare

Both are behind a Debug Settings tunable (`settings.layout`), so one build shows both.
- **A, Pages + jump search.** Today's sidebar, reordered as above, with expanders and search that jumps and highlights.
- **B, One page.** Every section stacked on one scrolling page. The sidebar becomes a scroll-spy index, and search filters that page in place, so nothing ever switches.

## Small PRs, in order

1. **Search that jumps:** index every card and action button, jump and highlight, plus the `openSettings setting:` deep link (CLI and palette included). A, and the data for B.
2. **Variant B** behind the Debug tunable, captured against A for the pick.
3. **Reorder and expanders:** General, Notifications, Browser.
4. **"Settings for This…"** in the context menus, and the palette's settings source wired.
5. **The missing controls:** app theme, terminal font, interface size, default shell, Agents page. Appearance is coordinated with cc-pane-chrome's studio.
6. **Undo instead of confirm**, and every handler on `setSetting`.

## Status of step 5 (missing controls)

New schema rows, so each is in the window, its search, the MDM schema
(docs/mdm/managed-preferences.md) and cmux.json:

| Key | Page | Control | Default |
|---|---|---|---|
| `appearance.theme` | Appearance, first row | Ghostty config, the onboarding themes, More Themes (every Ghostty theme) | Ghostty config |
| `appearance.metrics.chromeFontSize` | Appearance > Density and Motion | slider, 10 to 16 pt (same key as Increase/Decrease/Reset Interface Size) | density's size |
| `terminal.fontFamily` | Terminal, first group | installed fixed-pitch families | Ghostty config |
| `terminal.fontSize` | Terminal, first group | slider, 4 to 96 pt | Ghostty config |

Theme and terminal font apply live as Ghostty overrides (`TerminalThemeSetting`).
Reset All keeps them (`SettingsSchema.keptOnResetAll`): they are the look picked
at onboarding; each row's Reset still clears it.

**Default shell is not built.** No cmux.json key exists. Terminals run
`$SHELL` from the login environment the app captures for `cmux-tui server
ensure` (`LoginEnvironment`, `DaemonLauncher`); cmux-tui's `resolved_shell`
(cmux-pty) takes `SHELL` from the spawn's environment first. A
`terminal.shell` key would need: the setting and parser here; every
terminal-spawning request (`TerminalSpawningRequest` in `DaemonConnection`:
new tab, split, respawn, layouts) passing `env["SHELL"]`, which the daemon
stores with the terminal's receipt; `GhosttyShellIntegration.apply(shell:)`
picking the integration for that shell; and a decision for remote and Cloud
machines, whose shells are not local paths. "Default agent" has no key
either.

## Related work

- #16528 (cmux-next: polish Settings layout) aligns rows into one control column and adds card outlines. The IA changes build on it, and the expanders use its row geometry.
- #16873 keeps Settings opaque over a see-through theme. It doesn't conflict.
- #15210 (main app) adds a Font card with live preview and a gallery to Settings > Terminal. It is the model for the missing terminal font control here.
- #16693 (main app) searches shortcuts by name or by pressing the shortcut. cmux-next search covers shortcuts already, and the jump in step 1 uses the same index.
- Appearance studio (cc-pane-chrome, `feat-cmux-next-appearance-studio`): the panel reuses the Settings theme cards. Under this plan, Appearance keeps the quick controls and opens the studio from "Customize…".

## Current captures

| | |
|---|---|
| ![General](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/general.webp) | ![Appearance](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/appearance.webp) |
| ![Terminal](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/terminal.webp) | ![Notifications](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/notifications.webp) |
| ![Browser](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/browser.webp) | ![Keyboard](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/keyboard.webp) |
| ![Search: font](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/search-font.webp) | ![Search: theme](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/search-theme.webp) |
| ![Rooms & Profiles](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/rooms-profiles.webp) | ![Advanced](https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/settings-audit/advanced.webp) |
