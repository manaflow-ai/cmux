# Composer menus: the project and machine pickers

The composer's location controls (folder or project, machine or environment, branch) and the
menus they open: `webviews/src/agent-session/acpmux/ComposerContext.tsx`, `FolderPopover.tsx`,
`EnvironmentPicker.tsx`, `locationPopover.ts`, `composerLocation.css`, and the New Tab page's copy
in `newtab/NewTabScreen.tsx`. One composer, layouts by intent: the chat pane and New Tab draw the
same controls.

## Placement (Leo 2026-10-29)

> "project and cloudness at the top. make them open away from teh chat, which is obviously up if
> it's up, down if it's down. and stop making them take up so much space."

- **Where they sit:** on the New Tab page, the folder and machine controls head the composer,
  over the box, in every New Tab look; the quiet row under the box keeps only the mode, the model
  and the context ring. Leo, 2026-10-29: "we'll be wanting to put the project/machine (cloud)
  picker thing above the composer again (the is obv relevant for the new tab page and not really
  the in-agent-chat page)". The composer inside an agent chat keeps its own row as it is (a new
  chat's strip over its card, gone after the first send); this rule does not move it.
- **Which way a menu opens** (wherever the pickers appear): away from the conversation, read from where the composer sits in
  the window when the menu opens (`sideAwayFromChat`), never from which page it is. A composer
  whose middle is in the lower half of the window has the chat above it: its menus open down. One
  in the upper half (New Tab, with the chats under it) opens them up.
- **When that side is short of room:** the menu keeps its side and slides along it to stay in the
  window, over its own composer (`flip: "shift"`, `ui/openSide.ts`), so it never opens onto the
  chat. It may cover its own control while open. The side is chosen once, on open, and holds
  while the list filters or refreshes.
- **Outside a composer** (a gallery stage, any host without one) the menus keep the shared rule:
  below when the full menu fits, else the side with more room.
- Menus open on the click, in one frame, with no fade-in (rulebook); closing may fade.

## Size

- Wherever the pickers appear: content-sized pills side by side, folder first, then machine: never spread across the row.
- One strip height for both composers: 24 px for the strip, 6 px to the box.
- 4 px between the controls (`--acpmux-location-gap`); the ghost buttons' own insets do the rest.
- The strip's first icon stands on the quiet row's icon column (New Tab) or the prompt's first
  column (chat): one line for icons, one centre line for the pills.
- A long project name cuts in the middle; the machine never shrinks, it drops its name in a narrow
  strip and keeps its icon.

## Cloud machines in the machine menu

- The account's Cloud machines acpmux does not list show with their stage: Paused · Resume,
  Open, Starting…, and Couldn't start for a machine that failed (never "Not connected").
- A pick on one of them resumes or opens it, and the control names it as starting
  ("build box · Starting…"). The chat moves there once acpmux lists it ready, so a paused machine
  is one pick. Any other pick ends the wait.
- A resume reads Starting… at once, before the app's list comes back.
- The plain Computer menu's New Cloud Machine says what one gives ("Keeps working while your Mac
  sleeps"). The environment picker has no second lines at all: it is This Mac and Cloud, then the
  other machines, one line each (Leo, 2026-10-31; leo-workspace design/environment-picker.md).

## Gallery

`agent-pane.composer-context-away`: both composer positions with each menu open (the plays fail on
a menu that opens toward the chat), and the strip's surface variants. Picked: plain text over the
box. The bump, the tray and the plus-edge alignment stay Debug choices
(`agentPane.debug.topStripStyle`).

## Never

- A location control in New Tab's quiet row under the box.
- A location menu that opens onto the conversation because the other side had more room.
- Pills stretched to fill the row, or a gap that grows with the pane.
