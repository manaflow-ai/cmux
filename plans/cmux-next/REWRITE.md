# cmux next: Swift frontend rewrite on cmux-tui

Living document. Branch `feat-cmux-next`, worktree `worktrees/feat-cmux-next`.

## Goals (user, 2026-09-28)

1. Remove bonsplit entirely.
2. Terminals and layout state live in the cmux-tui daemon. Quit and reopen cmux keeps every terminal, tab, pane, column, screen, workspace.
3. Tabs: Chrome-style. Tabs shrink as count grows, hover a tiny tab for a live preview, Chrome-level open and close animations. Also a bonsplit-like mode.
4. niri-style scrolling columns: create columns, scroll horizontally between them.
5. Screens: supported, UI hidden until the user opts in.
6. Command palette (Cmd-Shift-P): Raycast quality, Liquid Glass, fast fuzzy search, every action registered.
7. Sidebar: Arc/Dia/Chrome quality, Liquid Glass, better drag reorder, groups.
8. Browser: WebKit and CEF (patched fork with real Chrome extensions). POC ~/fun/cmux2, fork ~/fun/cef-cmux, dist ~/fun/cef-cmux-dist.
9. Delete and rewrite. Do not port old Swift. Modern Swift 6 / AppKit / Observation. Move state into cmux-tui where it belongs.

## Visual rules

- No blue accent anywhere. Subtle grays for selection, focus, hover.
- Liquid Glass (`NSGlassEffectView`, `.glassEffect`) where it reads clean: palette, sidebar, tab strip, popovers. Not on terminal content.

## Architecture decisions

User decisions 2026-09-28:
- D1: new code in local SwiftPM packages (Packages/macOS/CmuxNext), sibling Xcode target `cmux-next`; on this branch the `cmux` scheme builds it, `cmux-legacy` keeps the old app. Delivery = one tagged app the user can dogfood with all changes in.
- D2: long-lived branch `feat-cmux-next`, sub-branches merge into it.
- D3: CEF fork + prebuilt artifact go to a new repo (manaflow-ai/cef, private until user says otherwise).
- D4: Cloud and iOS must keep working seamlessly. They may be rewritten so both ride cmux-tui (Cloud VMs already run the daemon; iOS should attach to the same daemon tree).
- Deployment target macOS 26 for cmux-next (flagged: appcast needs minimumSystemVersion before any release).

Design docs: cmux-tui-contract.md, inventory.md, browser.md, shell.md.

## Status

- 2026-09-28: worktree created off main fde44232c35. Research wave launched.
