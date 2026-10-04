# Proposal: `workspace.create` takes the first terminal's launch (atomic create)

Status: spec proposal (durable-sessions lead, 2026-10-04). Spec text only; no code until the
protocol lead (ad349) reviews it through the coordinator and a cmux-tui window is granted.

## Why

The Mac app creates a workspace with two requests (`create-workspace`, then `create-terminal`),
because the single `workspace.create` cannot carry the app's launch inputs. A failed second
request left a half-created workspace (interim app fix: `WorkspaceCreation` closes it again).
With these fields the app sends one idempotent request, and the daemon commits the workspace and
its first terminal together or not at all (the daemon side landed in 7de249cb3d5).

## Capability

`workspace-create-launch-v1`. A client sends the new fields only when the daemon serves it;
otherwise it keeps the two-request path with rollback.

## New optional fields of `workspace.create`

All fields below except `key` are accepted only with `initial_content: terminal`; with `empty`
they are `validation.invalid` (reason `field_requires_terminal`). Unknown fields stay refused
(`extra: false`).

| Field | Type | Validation | Semantics |
| --- | --- | --- | --- |
| `key` | string | canonical lowercase UUID, exactly 36 bytes, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` | The workspace key the caller reserved (window claim, room pin). An existing workspace with this key, live OR tombstoned, is `creation.conflict` (details `{"conflict":"workspace_key","key":…}`). Never a silent reuse. |
| `cwd` | string | absolute (`/` first), 1..4096 bytes UTF-8, no NUL; kept as given (not normalized) | The first terminal's directory. Checked at spawn: not an existing directory → `operation.failed` (reason `cwd_not_found`), the creation rolls back. |
| `argv` | array of strings | 1..256 items; each item 1..8192 bytes, no NUL; total ≤ 65536 bytes | The first terminal's command, resolved with the terminal's `PATH`. Absent: the user's login shell. |
| `env` | object (string → string) | ≤ 256 entries; keys `^[A-Za-z_][A-Za-z0-9_]{0,127}$`; each value ≤ 32768 bytes, no NUL; total keys + values ≤ 262144 bytes | Added to the first terminal's environment (over the daemon's). Values are NEVER logged, never echoed in errors, results, events or public projections; only key names may appear (for example in a validation error naming the bad key). Stored in the terminal's durable launch spec for restart, redacted from every public read. |
| `terminal_id` | string | exactly 32 bytes lowercase hex | The first terminal's host id, reserved by the caller (the app puts it in `CMUX_SURFACE_ID` before the request). An existing terminal with this id, live or tombstoned, is `creation.conflict` (details `{"conflict":"terminal_id"}`). |
| `keep` | boolean | — | The first terminal outlives its last tab (`terminal-reap-v1`). Default false. |

## Idempotency and conflicts

- `idempotency: required` stays. A replay with the same idempotency key and the same field
  fingerprint returns the stored result (or the stored failure). The fingerprint includes `env`
  through a keyed hash of its canonical JSON, never the raw values.
- The same idempotency key with different fields is `idempotency.conflict` (unchanged).
- A new idempotency key that names an existing `key` or `terminal_id` is `creation.conflict`;
  nothing is created and no reserved id is consumed.

## Result

Unchanged (`CreatedTerminalPath`), plus `key` when the request named one.

## Atomicity

The workspace row, its first screen, pane, tab and terminal become public in one commit. A spawn
failure, a projection failure or a conflict leaves no workspace and no live terminal
(settlement `not_applied`); an interrupted run is reconciled at the next start as today.

## Logging rule (all daemon and app code on this path)

`env` values and `argv` items are not logged at any level. Logs name only the operation, the
key, the terminal id and the env key count.
