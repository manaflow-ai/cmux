---
name: cmux-markdown
description: Open markdown files in a formatted viewer panel with live reload. Use when you need to display plans, documentation, or notes alongside the terminal with rich rendering (headings, code blocks, tables, lists).
---

# Markdown Viewer with cmux

Write a `.md` file, open it in a panel, and the panel re-renders whenever the file changes on disk. Use it for agent plans and task lists alongside the terminal, documentation and changelogs while working, and notes another process updates progressively.

```bash
cmux markdown open plan.md                              # split next to the current terminal
cmux markdown open /path/to/PLAN.md
cmux markdown open design.md --workspace workspace:2    # also --surface, --window
```

Relative paths resolve against the caller's cwd and `~` expands; the resolved absolute path comes back in the output.

## Agent usage

Write the full plan file first, then open it, so the panel never shows a partially written file. After that, overwrite or append freely: each write triggers a re-render, and atomic replacement (editor saves, `sed -i`, VS Code) is handled.

To instruct coding agents in a project, add to its `AGENTS.md`:

```markdown
## Plan Display

When creating a plan or task list, write it to a `.md` file and open it in cmux:

    cmux markdown open plan.md

The panel renders markdown with rich formatting and auto-updates when the file changes.
```

## Rendering

Headings h1-h6 (dividers on h1/h2), fenced code blocks in monospace, inline code with a highlighted background, tables with alternating row colors, nested ordered and unordered lists, blockquotes with a left border, bold/italic/strikethrough, clickable links, horizontal rules, and inline images. Light and dark mode both supported.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full command syntax, options, output shape, panel behavior |
| [references/live-reload.md](references/live-reload.md) | File watching, atomic writes, unavailable-file state, performance |
