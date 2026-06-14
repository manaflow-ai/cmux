---
name: cmux-shared-behavior
description: "Shared behavior and mutation-path rules for cmux. Use when a behavior is exposed through multiple entrypoints such as keyboard shortcuts, command palette, context menu, CLI, settings, debug menu, optimistic UI, or tests that previously missed a bug."
---

# cmux Shared Behavior

Use one shared action/model path when behavior is exposed through multiple entrypoints.

## Shared entrypoints

When a behavior is exposed through multiple surfaces, implement one shared action/model path and verify every entrypoint that should invoke it.

Common entrypoints include:

- keyboard shortcut
- command palette
- context menu
- CLI/socket command
- settings UI
- debug menu

Do not patch one surface while leaving the others with duplicated logic.

## Optimistic updates

For optimistic UI or CLI updates:

- keep one mutation path
- record pending state with a request id or previous snapshot
- reconcile from the authoritative result
- handle failure with an explicit rollback or error state

Do not let each entrypoint maintain its own optimistic copy.

## Missed-bug coverage

When a user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete.
