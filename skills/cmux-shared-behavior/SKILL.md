---
name: cmux-shared-behavior
description: "Shared behavior and mutation-path rules for cmux. Use when a behavior is exposed through multiple entrypoints such as keyboard shortcuts, command palette, context menu, CLI, settings, debug menu, optimistic UI, or tests that previously missed a bug."
---

# cmux Shared Behavior

## Shared entrypoints

When a behavior is exposed through multiple surfaces (keyboard shortcut, command palette, context menu, CLI/socket command, settings UI, debug menu), implement one shared action/model path and verify every entrypoint that should invoke it. Do not patch one surface and leave the others with duplicated logic.

## Optimistic updates

Keep one mutation path. Record pending state with a request id or a previous snapshot, reconcile from the authoritative result, and handle failure with an explicit rollback or error state. Never let each entrypoint maintain its own optimistic copy.

## Missed-bug coverage

When a user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete.
