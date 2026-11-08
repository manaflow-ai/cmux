# Conditional undo for cmux.json settings

A preset or agent that changes a setting may later need to take that change
back. An unconditional reset gets this wrong in two ways: it erases a choice the
user made after the preset, and it turns an explicit pin into inheritance. cmux
instead records what one mutation did to one path and undoes it only while that
path still holds the value it installed.

The writer boundary and publication this builds on landed separately:
[#13218](https://github.com/manaflow-ai/cmux/pull/13218) (lossless JSONC edits,
the `<target>.cmux-write.lock` sidecar lock shared by the native store and the
`cmux-settings` helper, and source-snapshot publication) and
[#13146](https://github.com/manaflow-ai/cmux/pull/13146) (the canonical
semantic validator).

## Native store

`JSONConfigStore` in `Packages/macOS/CmuxSettings`:

| API | Validation | Returns |
|---|---|---|
| `set(_:for:)`, `reset(_:)` | Syntax only (unchanged contract) | Nothing |
| `setWithReceipt(_:for:)`, `resetWithReceipt(_:)` | Full candidate against the global schema; refuses only issues the change adds | `JSONConfigMutationReceipt` |
| `undo(_:)` | Same as above | The inverse receipt |

A receipt holds the dotted path, the canonical JSON before the change (`nil` when
the path was absent), the JSON installed (`nil` for a reset), and the resolved
target file. Receipts stay in memory and are never logged.

`undo` takes the writer lock, re-reads the file, and compares the current value
at the path with the receipt's installed value. A mismatch, or a symlink that now
resolves to a different file, throws `JSONConfigMutationError.undoConflict` and
leaves the file byte-for-byte unchanged. The error message names the path only;
the expected, current, and restore values are associated values for a local
preview. A schema rejection throws `JSONConfigMutationError.invalidCandidate`
with the issues the change adds and publishes nothing. An issue the file
already had, identified by path and message, doesn't block the write: an
unknown key from a newer build or an invalid value on another path is the
user's to fix, not a reason to refuse a toggle.

The Computer Use Settings toggles (`computerUse.enabled`,
`computerUse.showInMenuBar`) are the first consumers: their `JSONValueModel`s use
`validateMutations: true`, so an invalid candidate surfaces in the Settings error
log instead of reaching disk. The schema also declares the existing DEBUG-only
`app.devWindowDisplay` key, which the app already writes.

## Helper

```sh
cmux-settings set computerUse.showInMenuBar false --preview
cmux-settings set computerUse.showInMenuBar false \
  --expect-revision REVISION --receipt /private/menu-bar-undo.json
cmux-settings undo /private/menu-bar-undo.json
```

- `--preview` prints the path's before and installed values plus a revision
  (a digest of the resolved target, its inode, and its bytes) and writes nothing.
- `--expect-revision` refuses the write with `source_changed` if the file
  differs from the preview.
- `--receipt` creates the file exclusively with mode 0600. An existing file is
  refused with `receipt_exists`, and a path that can't be created (missing
  parent, permissions) with `receipt_unwritable`, before the config is written. The receipt is
  written after publication. If publication fails, the receipt stays empty and
  `undo` refuses it. If publication succeeds but the receipt write fails, the
  helper exits 0 with `{"status": "persisted", "receipt": "failed"}` so the
  caller does not retry a change that already landed.
- `undo` refuses a receipt that is not a private regular file owned by the
  user, then applies the same ownership check as the native store.

Conflicts print `{"status": "conflict", "code": ..., "key": ..., "message": ...}`
on stderr, with messages localized from `config_mutation_messages.json`, and
never include config values. The helper validates the same way as the native
store: an `invalid_config` conflict lists only the `issues` (path and message)
the change adds, and a file's existing issues don't block an unrelated write.
The baseline is validated only when the candidate has issues. A validator run
that fails without per-path issues (an older CLI, a crash) refuses the write
outright, since there is nothing to compare.

## Limits

- New issues are matched by path and message. Changing an already-invalid value
  to another value that breaks the same constraint isn't refused, and a
  container-level issue such as "does not match any allowed form" can mask a
  second problem under the same path. Neither makes a valid file invalid.
- Ownership is by value. An edit that changes the path and later returns it to
  the installed value (ABA) is indistinguishable from no edit.
- Absent, JSON `null`, and an explicit default are distinct. Unrelated paths,
  comments, and formatting survive an undo.
- Success means the change reached disk. Runtime reload and application are not
  observed.
- Writers that do not take the sidecar lock (editors, older helpers) are caught
  by the source-snapshot check at publication, not prevented.

## Tests

```sh
swift test --package-path Packages/macOS/CmuxSettings --filter 'JSONConfig(Transaction|StoreSymlink)'
swift test --package-path Packages/macOS/CmuxSettingsUI --filter JSONValueModelTransaction
python3 tests/test_cmux_settings_transactions.py
```

The helper tests stub `candidate_issues` to control interleavings, and run the
real validation path against a fake `cmux config validate` for the new-issue
rule. Schema rejection is covered by the native transaction tests and
`tests/test_cli_config_doctor.py`.
