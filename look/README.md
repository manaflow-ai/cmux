# The Claude Code desktop look

This branch makes cmux NEXT look and work like the Claude Code desktop app (dark). The whole
branch is the look: its web layer and its profile go in together.

## Install

```bash
cmux customize use manaflow-ai/cmux@lane/look-claude   # the web layer: chat, composer, New Tab
cmux customize use look/profile.json                  # theme, settings, chat colours, Sessions section
cmux customize apply
```

Back: `cmux customize library off NAME` for the web layer, `cmux customize discard` for the profile.

## What is in it

- `look/profile.json`: one cmux profile with its files inlined. Settings (folder-grouped sidebar,
  Claude Code desktop's New Tab page, the chat's width and font), the theme file
  (`files/theme.json`: the warm near-black page `#1f1e1c`, a darker sidebar, the clay accent
  `#d97757`, no borders), the chat stylesheet (`files/agent-pane.css`) and a views app
  (`customize/`): a **Sessions** sidebar section listing agent sessions, filterable by status,
  project or environment (the chat's machine), grouped by project or not.
  The inlined copies come from `files/` and `customize/`; edit those and inline them again.
- The web layer, in `webviews/`:
  - `src/agent-session/acpmux/claudeLook.css`: tool rows (bold verb, the file in a mono chip,
    green and red counts, no icons), the user prompt's dark pill, the clay asterisk on the live
    line, the branch bar and the composer's radius.
  - `conversation/ClaudeFileLabel.tsx`, `ToolGroupRow.tsx`, `WriteLabel.tsx`: one-file edits and
    writes read "Edit `src/api/client.ts` +112 -84" and "Write `src/api/retry.ts` +47".
  - `conversation/toolGroups.ts`: each edit and write is its own row, and a run's calls are never
    folded under one summary line (`runStretches`).
  - `turnChanges/settings.ts`: no edited-files card by default; the per-file rows show instead.
  - `ClaudeBranchBar.tsx` (in `Composer.tsx`): "main ← branch +N -N Create PR" over the composer.
  - `composerLook.ts`: Claude's composer look (the picker row under the box) by default.
  - `newtab/templates.ts`: Claude Code desktop's new-session page by default.
  - `Localizable.xcstrings` (English): "Edit {file}", "Write {file}".
- `PARTS.md`: each part of the reference and how close it is.
- `captures/`: the reference beside ours.

Captures: `node webviews/scripts/agent-pane/look-capture.mjs --out DIR` on a Linux machine
(never a Mac): the mock pane under the look's theme.

Tests that pin cmux's own wording, run folding, edited-files card ("Edited", "Wrote") and its default composer look and New Tab
template disagree with this branch on purpose; they stay as they are on feat-cmux-next.
