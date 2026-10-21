---
name: cmux-markdown
description: Open markdown files in cmux's rendered Markdown page. Use when you need to display plans, documentation, or notes alongside the terminal with rich rendering (headings, code blocks, tables, lists).
---

# Markdown Viewer with cmux

Open the file with `cmux open`. The app shows a Markdown file in its Markdown
page, in a tab in the caller's pane:

```bash
cmux open plan.md
```

A relative path resolves against the CLI's working directory. Several paths
open in order. `cmux open` sends the app's `file.open` action, the same path the
palette and the File menu take.

Whether the page re-renders when the file changes on disk has not been verified
on cmux-next; if the user needs to see a large edit, reopen the file.

## Removed

- `cmux markdown open <path>` and its `--workspace`, `--surface`, `--window` flags. Do not run `cmux markdown`.
- The classic live-reloading panel described in [references/live-reload.md](references/live-reload.md), kept as a record of the old behavior.
