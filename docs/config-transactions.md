# Cooperative config writes and conditional undo

Prerequisites: lossless editor manaflow-ai/cmux#13218 and semantic validator
manaflow-ai/cmux#13146. This first slice uses the existing
`SettingCatalog().computerUse.showInMenuBar` JSON key and `JSONValueModel`.
No new setting registry, preset format, runtime-application acknowledgement,
or whole-file restore is introduced.

## Contract

`JSONConfigStore` mutations and `cmux-settings set|unset|undo` resolve the target,
open `<resolved-target>.cmux-write.lock`, and take a nonblocking exclusive `flock`.
A busy writer returns a conflict; the caller may explicitly retry from fresh
state. The lock file is stable and must not be removed while writers run.
The boundary covers fresh read, undo comparison, lossless editing, validation,
source/target recheck, and atomic publication. No suspension occurs inside the
native critical section. Cross-process locking is necessary because actors
cannot coordinate a Python helper process.

Cooperating writers to the same resolved target preserve disjoint changes or
return a conflict. Ordinary sequential writes remain last-writer-wins. Hard-link
aliases, network filesystems without equivalent flock semantics, older helpers,
other native file writers, and arbitrary editors are outside this contract.
A final identity/bytes/target check catches edits during preparation, including
same-byte inode replacement. It cannot close an arbitrary editor's race between
that check and rename. This is not general filesystem compare-and-swap.

Legacy `set/reset` retain their existing syntax-only validation contract.
`setWithReceipt/resetWithReceipt/undo`, the two Computer Use Settings models,
and the helper validate the full candidate with Q's canonical validator.
The native receipt API is for global config. Helper scope inference and explicit
`--scope` are unchanged. The canonical schema includes the real legacy
`app.devWindowDisplay` catalog key, so validated Computer Use writes preserve
that setting instead of rejecting an otherwise valid config. There is no
special-case validator exemption here.

## Single-path apply and undo

```sh
cmux-settings --file /owned/profile/cmux.json --scope global \
  set computerUse.showInMenuBar false --preview
# Use the returned revision to reject changes since this preview:
cmux-settings --file /owned/profile/cmux.json --scope global \
  set computerUse.showInMenuBar false --expect-revision REVISION \
  --receipt /owned/private/menu-bar-undo.json
cmux-settings --file /owned/profile/cmux.json --scope global \
  undo /owned/private/menu-bar-undo.json
```

Preview reports only the owned path's before/installed values plus its target
and revision. Treat this output and receipts as private config data. Receipts
are exclusively created with mode 0600 and never overwritten. Publication and
receipt persistence are separate effects: an interrupted/failed receipt write
may leave an unusable empty/incomplete receipt. If config publication succeeded
but receipt output failed, the helper returns success with a structured
`persisted` result and `receipt: failed`. The committed config change must not
be treated as unapplied or automatically retried; the receipt is unavailable
for undo.

Undo re-reads under the same lock and restores the prior value only if the target
and current raw value equal the receipt's installed result. Conflict diagnostics
name the path and preserve the newer choice; inspect `get` and the private
receipt for the value preview. Native errors carry the three local JSON values.
Absent, JSON null, and an explicit default are distinct. Unrelated paths and
comments survive; existing parent-pruning, encoding and duplicate-key policies
are preserved. Native Foundation uses the first duplicate and Python uses the
last; this slice does not unify those existing policies. Use ordinary unique-key
settings for the cross-language preset flow. Value-based ownership does not
recognize intervening edits that return to the same value (ABA).

Success describes disk persistence only. Runtime application, deferred reload,
and restart requirements are unobserved, including for Computer Use's separate
helper lifecycle. No user app, TCC permission, or live config is mutated by the
fixtures.

## Reproduction

The tests-only commit `da2ff76a1b712f2d6fa6e8944d48e782923f320a` gates the
production Python helper after reading and before publishing. A real native
store completes a same-key or disjoint-key edit, then the helper resumes.
Both native edits are erased before the fix (two failed assertions). Cached
independent stores and an external edit before watcher invalidation already
pass on the composed prerequisites. No prior receipt-based undo API existed;
unconditional reset remains reset, not preset uninstall.

```sh
swift test --package-path Packages/macOS/CmuxSettings --filter 'JSONConfig(Store|Transaction)'
swift test --package-path Packages/macOS/CmuxSettingsUI --filter JSONValueModel
python3 -m unittest discover -s tests -p 'test_cmux_settings_*.py'
CMUX_CLI_BIN=/owned/build/cmux python3 tests/test_cli_config_doctor.py
```

The helper interleaving and lossless fixtures inject validation outcomes to
control scheduling or exercise schema-independent text shapes. They do not
claim schema coverage. Native transaction tests and the CLI doctor suite execute
the real canonical validator. All config files and receipts are temporary.
