---
name: cmux-markdown
description: Open markdown files in a formatted viewer panel with live reload. Use when you need to display plans, documentation, or notes alongside the terminal with rich rendering (headings, code blocks, tables, lists).
---

# Markdown Viewer with cmux

The Markdown viewer panel and `cmux markdown open` are not available in cmux-next. The Swift CLI that provided the command was removed, and the app has no Markdown viewer yet (its Markdown zoom actions report it unavailable). Do not run `cmux markdown`.

## Closest supported path

Show the file in a terminal tab next to the caller, with a pager or renderer the user has installed:

```bash
cmux pane pane_… run --name plan -- less plan.md
```

Find the caller's pane first (see [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md)). A terminal tab does not re-render when the file changes; rerun the command after large edits.

## Removed

- `cmux markdown open <path>` and its `--workspace`, `--surface`, `--window` flags.
- The live-reloading panel described in [references/live-reload.md](references/live-reload.md), kept as a record of the old behavior.
