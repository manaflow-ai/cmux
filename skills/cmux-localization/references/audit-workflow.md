# Localization Audit Workflow

Expands the rules in [../SKILL.md](../SKILL.md).

## What counts as user-facing

SwiftUI views, AppKit menus and dialogs, alerts and confirmation sheets, tooltips and accessibility labels, Settings rows and descriptions, command palette entries, keyboard shortcut metadata, CLI help and command output, JSON schema descriptions shown in docs or editors, docs pages, web UI, and generated configuration examples shown to users.

Debug-menu and debug-window labels are contributor-facing but still deserve localization when they are visible in the app.

## Keys across locales

A key added only to `web/messages/en.json` is incomplete even though the UI falls back at runtime. Same for a Swift key with a `defaultValue` but no `Resources/Localizable.xcstrings` entry per locale: `defaultValue` is a development convenience, not the English localization.

## Bare English search

Search the changed files, not the whole tree:

```bash
git diff --name-only -- '*.swift' '*.ts' '*.tsx' '*.md'
rg -g '*.swift' 'Text\("[A-Z][^"]+"'
rg -g '*.swift' 'Button\("[A-Z][^"]+"'
rg -g '*.swift' -g '*.ts' -g '*.tsx' 'tooltip|alert|title|description|label'
```

These are prompts to inspect likely user-facing strings, not proof on their own.

## Final handoff

State which surfaces changed, which localization files were updated, which audit commands or manual checks ran, and anything that could not be verified. If no user-facing strings changed, say so.
