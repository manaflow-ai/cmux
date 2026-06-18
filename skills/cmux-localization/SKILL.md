---
name: cmux-localization
description: "Localization rules and audit workflow for cmux UI strings, settings rows, menus, shortcuts, schema/config text, docs, command/help text, alerts, tooltips, and web messages. Use whenever changing user-facing text."
---

# cmux Localization

Use this skill for any user-facing string change.

## Hard rules

- All user-facing strings must be localized.
- Use `String(localized: "key.name", defaultValue: "English text")` for Swift/AppKit/SwiftUI strings.
- Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages, currently English and Japanese.
- Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, tooltips, menus, or dialogs.
- Localization audit is required for every user-facing change.
- `defaultValue`, English fallback text, schema descriptions, or copied English strings do not count as localization.
- For localized web/docs content, update every supported message catalog, currently `web/messages/en.json` and `web/messages/ja.json`, plus any localized data structures carrying inline translations.

## Audit checklist

Before finishing a task that changes UI, Settings rows, menus, shortcut metadata, schema/config text, docs, command/help text, alerts, or tooltips:

1. Enumerate the changed user-facing surfaces.
2. Verify each surface has entries for every supported locale.
3. Parse touched localization files.
4. Compare changed message keys across locales.
5. Use `rg` over changed Swift/TS/TSX/docs files for newly introduced bare English.
6. State the localization audit in the final handoff, or explicitly say what could not be verified.

## Related shortcut rule

Every new cmux-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/cmux/cmux.json`, and documented in the keyboard shortcut and configuration docs.

## Detailed reference

- Read [references/audit-workflow.md](references/audit-workflow.md) for a deeper audit process, common false positives, and examples of surfaces that count as user-facing.
