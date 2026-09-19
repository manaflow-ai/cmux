---
name: cmux-localization
description: "Localization rules and audit workflow for cmux UI strings, settings rows, menus, shortcuts, schema/config text, docs, command/help text, alerts, tooltips, and web messages. Use whenever changing user-facing text."
---

# cmux Localization

Use this skill for any user-facing string change.

## Normal contributor flow

After adding or changing user-facing copy, run `./scripts/localize-changes`.

The command compares the current worktree with the mainline base, discovers changed Swift localization keys and English web messages, prepares simple new or changed macOS catalog entries with minimal edits, and writes a machine-readable translation packet under git metadata. Fill `value` for simple translations or `localization` for plural or variant entries, then run the same command again. Completed macOS rows are imported through `scripts/localization_catalog.py merge`, and `scripts/localization_catalog.py check` remains the final authoritative validator.

Use `--base <ref>` for another comparison base and `--work-file <path>` when a translation helper needs a visible packet. The default packet stays outside the worktree. Ambiguous catalog ownership, count-like new strings, unsupported Swift literal forms, and invalid generated translations stop with a concrete human-attention item so the existing placeholder, plural, bidi, omission, identity-translation, copied-English, and catalog checks stay intact.

## Hard rules

- Every user-facing string is localized. Never a bare string literal in SwiftUI `Text()`, `Button()`, alert titles, tooltips, menus, or dialogs.
- Swift/AppKit/SwiftUI: `String(localized: "key.name", defaultValue: "English text")`, with keys in `Resources/Localizable.xcstrings`. Every feature PR includes translated entries for all supported macOS languages required by `scripts/localization_catalog.py` (currently `en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`), subject to the exact omission records below. English and Japanese entries are always required.
- `defaultValue`, English fallback text, schema descriptions, and copied English strings do not count as localization. Record deliberate invariant literals in `scripts/localization-allowed-omissions.json`, with the exact source and omission class. A correct translation that shares the English spelling needs a documented `identityLocales` exception for that key and locale; the translated entry remains required.
- Localized web/docs content updates every locale declared by `web/i18n/routing.ts`, with a matching `web/messages/<locale>.json` entry plus any localized data structures carrying inline translations.
- A localization audit is required for every user-facing change.

## Audit checklist

Before finishing a task that changes UI, Settings rows, menus, shortcut metadata, schema/config text, docs, command/help text, alerts, or tooltips:

Run `./scripts/localize-changes` first and resolve every reported translation row or human-attention item.

1. Enumerate the changed user-facing surfaces.
2. Verify each surface has a catalog key and translated values for every supported macOS locale (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`) in the feature PR, unless an exact omission record allows an absent value. Omission records still require `en` and `ja` entries.
3. Parse the touched localization files and compare changed message keys across locales.
4. Run `rg` over changed Swift/TS/TSX/docs files for newly introduced bare English.
5. State in the final handoff what audit was performed, or explicitly say what could not be verified.

`Resources/Localizable.xcstrings`, `Resources/InfoPlist.xcstrings`, and the linked macOS package catalogs must pass `python3 scripts/localization_catalog.py check`. New keys must carry all nine macOS locale entries unless covered by an exact omission record; `en` and `ja` entries remain required. Preserve printf placeholders and use plural variations for count strings where the source has a count.

Count strings are recorded in `scripts/localization-plurals.json` with the English source and the argument numbers that select plurals. Every required plural category must contain translated text. Use substitutions when more than one count varies or when the count is not the first argument. Arabic requires zero/one/two/few/many/other; French and Spanish include many. Keep every message inside the catalog's `strings` object so Xcode compiles it.

For a shared-spelling word inside a plural substitution, use an `identityLocales` object with `reason` and an explicit `values` list. This permits the listed leaf text (for example French `%d machines`) while continuing to reject an untranslated English sentence around it.

## Detailed reference

- [references/audit-workflow.md](references/audit-workflow.md): what counts as user-facing, search patterns, and handoff wording.

New keyboard shortcuts also need docs and Settings entries; see [../cmux-keyboard-shortcuts/SKILL.md](../cmux-keyboard-shortcuts/SKILL.md).
