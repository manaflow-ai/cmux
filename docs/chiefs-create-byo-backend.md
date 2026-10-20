# Chiefs: create, bring-your-own backend, config editing (u2586, 2026-10-19)

The contract three workers build against. The daemon's Chief registry
(`cmux-tui/crates/cmux-tui-core/src/chief_registry.rs`) is the one source of
truth for every Chief's profile, grant and engine.

## Record (wire form of `chief.profile.*`)

New fields on the record, both default when missing:

- `locked: bool` (default `false`). The person's switch. While `true`, no Chief
  (the Chief itself included) may change the record: every Chief write answers
  `operation.failed` reason `chief_locked`. Only the owner (terminal, or the
  app page with the person's gesture) sets or clears it; `locked` is a gesture
  field.
- `self_edit` takes a new item `engine`: the Chief may change its own
  `harness`, `model` and `effort`. With `engine` the harness must be one of its
  own `harnesses` (an empty list means every harness).

Defaults change: the default Chief and every new Chief get the full
`self_edit` (`avatar, display_name, engine, instructions, personality, role`).
A one-time migration (`self_edit_v2`) gives the full set to every live record
whose `self_edit` is still the old default `["avatar"]`. The person can narrow
it again.

## A Chief editing another Chief (`chiefs` tool)

A Chief with the `chiefs` tool may change every profile field of another
Chief (name, role, picture, personality, instructions, engine), not only
name, role and picture. The ceiling stays: the target's grant and the new grant
must be within the caller's (`tools`, `self_edit` subsets; `harnesses` within).
The engine rule is now: the engine harness must be one the caller may use;
model and effort are free. The default Chief's `tools`, `harnesses` and
`self_edit` stay the person's. `locked` is never a Chief's to change, and a
locked target refuses (`chief_locked`). No Chief deletes a Chief.

## History and undo

Every committed record state is kept (`chief_history` table, newest 100 per
Chief), with the actor and operation that made it.

- `chief.profile.history {chief, limit?}`: `{chief, revisions: [{rev, at,
  actor, operation, record}]}`, newest first. Any registry reader may call it.
- `chief.profile.undo {chief, to_rev?, expected_rev?}` + idempotency key: makes
  the record equal to revision `to_rev` (default: the revision before the
  current one) as a NEW revision. It goes through the same checks as
  `chief.profile.update` with the fields that differ (a Chief may undo only
  what it may change; `locked` is never undone by a Chief). Answer: the update
  answer.

## Engine = backend

`harness`, `model`, `effort` in the record are the Chief's backend. On every
committed write the daemon writes them into that Chief's
`<brain home>/optchat/engine.json` (`harness`, `model`, `effort`; the
compactor and speed fields stay), which the brain reads at each turn start, so
`chief engine show` shows the record's engine. Brain home: the Chief home root
for the default Chief, `<home>/c/<last 8 of id>` for the others.

A harness is any acpmux harness id: the built-ins (`claude` = the person's
own Claude CLI, `codex`, `claude-sr2`, `opencode`, `unii`, ...) and the
person's own (`cmux harness add`). Bring your own:

- an ACP agent command: `_acpmux/harness/add {id, displayName, command, args,
  env}` (exists);
- an Anthropic-compatible endpoint: `_acpmux/harness/add {example:
  "anthropic-endpoint", id, displayName, baseUrl, model, keychainItem}`;
- an OpenAI-compatible endpoint: `_acpmux/harness/add {example:
  "openai-endpoint", id, displayName, baseUrl, model, keychainItem}`.

The key is stored in the macOS Keychain (`cmux harness secret set` /
`_acpmux/harness/secret/set`); the profile holds only `keychain:NAME`. Before
the Chief record takes a new harness, the UI runs `_acpmux/harness/doctor {id,
prompt: true}`, a real hello turn, and saves only when it passes; otherwise it
shows the failing step and its fix.
