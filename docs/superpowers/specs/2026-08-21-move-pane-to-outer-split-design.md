# Move Pane to an Outer Split

> **Status: Approved for implementation on 2026-08-21.** The selected policies are a 50/50 root share, no Dock support in v1, and coordinated Bonsplit then cmux changes.

Issue: [cmux #10525](https://github.com/manaflow-ai/cmux/issues/10525)

## Problem

The surface-movement actions added for #8752 can move a surface into an adjacent pane or create a new split inside the focused pane's current region. They cannot promote an existing nested pane to a workspace-root edge.

Given a nested layout:

```text
┌───────────────┬───────────┐
│               │           │
│               ├───────────┤
│               │           │
├───────────────┼───────────┤
│               │  focused  │
│               │   pane    │
└───────────────┴───────────┘
```

The user needs a persistent structural transformation that produces:

```text
┌───────────────┬───────────┬───────────┐
│               │           │           │
│               ├───────────┤           │
│               │           │   moved   │
├───────────────┼───────────┤   pane    │
│               │           │           │
│               │           │           │
└───────────────┴───────────┴───────────┘
```

This is not pane zoom. The result remains after focus changes and is captured by session persistence.

## Goals

- Move the focused pane, including all of its surface tabs, to a new outer edge.
- Preserve live terminal, browser, and panel identity; nothing is recreated.
- Support left, right, above, and below symmetrically.
- Make left/right panes span the full workspace height and above/below panes span the full workspace width.
- Keep existing #8752 surface-movement behavior unchanged.
- Route shortcuts, the Command Palette, and the View menu through one shared mutation.
- Persist and restore the resulting ordinary Bonsplit topology without a special state format.

## Non-goals

- Changing the meaning of **Move Surface to Pane on Right/Left/Above/Below**.
- Moving only one surface out of a multi-surface pane.
- Adding root-level creation actions from #7227 in the same cmux change.
- Supporting Canvas or remote-tmux mirror layouts in the first version.
- Adding a default key binding.

## Module and Seam

Bonsplit is the existing in-process module that owns cmux's split-tree topology. Its public controller is the seam through which cmux creates, closes, focuses, and queries panes. cmux owns product policy and entrypoint routing; it should not learn how to detach a leaf, collapse a branch, or rebuild a root.

The new interface is deliberately small: callers provide a pane identity and a semantic root edge. Bonsplit hides the complete structural mutation, including validation, no-op detection, branch normalization, focus preservation, and geometry publication. This keeps the module deep: one operation provides leverage to shortcuts, menus, the Command Palette, and a future workspace-edge drag target while keeping tree invariants local to the topology owner.

The deletion test rejects an app-layer helper. If the Bonsplit operation were deleted, every cmux entrypoint would need to reconstruct the same tree surgery and recovery rules. Keeping that complexity behind the existing controller seam provides both caller leverage and maintainer locality.

## Approaches

### A. Add a Bonsplit pane-to-root-edge mutation (recommended)

Deepen the existing `BonsplitController` module with one public operation that extracts a leaf pane without destroying its `PaneState`, collapses its old branch, and wraps the remaining root with the extracted pane on the requested edge.

This preserves the entire pane and its live tabs by identity, makes the topology change atomic, and gives future drag-to-workspace-edge behavior a reusable primitive.

### B. Rebuild the layout in cmux

Capture the tree, create replacement splits, and move surfaces into them from the app layer. This uses existing public APIs but makes an atomic pane move into a sequence of visible mutations, complicates rollback and focus, and risks transient empty panes or surface reparenting bugs.

**Rejected:** correctness and visual stability are worse than a small Bonsplit primitive.

### C. Overload #8752's directional surface movement

At a workspace edge, reinterpret **Move Surface Right** as a root-level promotion.

**Rejected:** one action would mean join an adjacent pane, split the local region, or restructure the workspace root depending on topology. It also moves the wrong unit when the source pane contains multiple surfaces.

## Proposed Bonsplit API

Introduce a public four-case value such as `RootSplitEdge` and one atomic method:

```swift
@discardableResult
public func movePane(
    _ paneId: PaneID,
    toRootEdge edge: RootSplitEdge
) -> Bool
```

`RootSplitEdge` has `left`, `right`, `above`, and `below` cases. It is semantic rather than geometric plumbing: orientation, child ordering, and divider policy remain implementation details. A configurable divider argument is intentionally excluded so callers cannot create policy variants at each entrypoint.

The internal mutation:

1. Validates that splits and pane movement are allowed, the pane exists, and the tree has more than one pane.
2. Clears pane zoom before a successful structural mutation.
3. Extracts the pane node while retaining the same `PaneState` object and tab ownership indexes.
4. Collapses the old parent and any now-degenerate branch.
5. Creates a new root `SplitState` around the remaining tree:
   - left/right use horizontal orientation;
   - above/below use vertical orientation;
   - left/above insert the moved pane first;
   - right/below insert it second.
6. Focuses the moved pane and publishes the normal focus and geometry notifications once.

No close-pane or split-pane delegate callbacks are synthesized: neither accurately describes the mutation. A dedicated pane-move callback is deferred until a second host requirement exists; the existing focus and geometry observations are sufficient for cmux v1.

## Edge Semantics

- A nested pane is promoted even if it is already visually touching the requested workspace edge.
- If the pane is already a direct root child on the requested edge and spans the full orthogonal extent, the operation returns `false` without changing layout or focus.
- If it is a direct root child on the opposite edge, the operation moves it across the root, effectively reordering the two root children.
- Moving the only pane is a no-op.
- The remainder of the tree keeps its relative nesting, pane order, divider ratios, and pane identities.
- The moved pane keeps all tabs, selected tab, titles, running processes, scrollback, browser state, and notification ownership.
- Existing zoom is cleared only when the structural mutation will succeed; failure leaves zoom and layout untouched.

## Root Share

The new root divider starts at 50/50, clamped through Bonsplit's existing configured divider range. This is deterministic, symmetric, and consistent with normal split creation. Preserving the pane's previous pixel extent is rejected for v1 because nested layouts do not provide one stable extent across window resizing and minimum-size clamping. Users can immediately refine the share with keyboard resize or divider drag; no new setting is added.

## cmux Actions and Shared Routing

Add four initially unbound actions:

- `movePaneToOuterLeft`
- `movePaneToOuterRight`
- `movePaneToOuterTop`
- `movePaneToOuterBottom`

Use one `PaneOuterMovement` value to provide action mapping, localized titles, command IDs, orientation, and insertion side. Route all entrypoints through one `AppDelegate.performPaneOuterMovement` path:

- configured keyboard shortcut;
- Command Palette;
- View menu.

The shared action resolves the same main-window context as #8752, rejects Canvas and remote-tmux mirrors, calls the workspace mutation, and emits normal no-op feedback when the mutation is unavailable.

Dock-owned focus rejects the action consistently in v1. Dock has separate ownership and reconciliation behavior, so parity is a separate product decision rather than another adapter at this seam.

## Shortcut and Documentation Surfaces

Each action must be:

- represented in `CmuxSettings.ShortcutAction` with no default binding;
- editable in **Settings → Keyboard Shortcuts**;
- accepted by `shortcuts.bindings.<actionId>` in `cmux.json`;
- localized in English and Japanese;
- listed in the shortcut reference data, schema, configuration docs, and keyboard-shortcut documentation.

## Error Handling

The Bonsplit operation is transactional at the model level: validate before detaching, then perform one synchronous root replacement. It returns `false` for invalid/no-op cases and must never leave an empty pane, placeholder surface, or partially updated ownership index.

cmux uses the existing audible no-op feedback for an invoked action that cannot run. It does not display a modal alert.

## Persistence

The final tree is an ordinary Bonsplit split tree. Existing session snapshot and restore code should serialize it without a new schema. Add a focused round-trip test for the promoted topology instead of adding feature-specific persistence state.

## Testing

### Bonsplit

- Promote a nested pane in all four directions.
- Preserve the same pane state, all tab IDs/order, and selected tab.
- Preserve the remainder tree and its divider positions.
- Reorder a direct root child to the opposite edge.
- No-op when already at the requested outer edge.
- No-op for a single pane or disabled splits.
- Clear zoom on success and preserve it on failure.

### cmux

- Reproduce #10525's nested layout and assert a full-height right root child.
- Assert all four action mappings, command IDs, and no default shortcuts.
- Verify keyboard, Command Palette, and View menu use the shared mutation path.
- Reject Canvas and remote-tmux mirror layouts without mutation.
- Round-trip the resulting topology through session persistence.
- Verify localization and shortcut schema/docs coverage.

## Repository and PR Sequencing

This design requires a Bonsplit change and a cmux change.

1. Create a Bonsplit feature branch from the submodule commit pinned by current cmux `main`.
2. Add and test the atomic public pane-to-root-edge mutation.
3. Push the Bonsplit branch and open its PR first.
4. After the Bonsplit commit is available from `manaflow-ai/bonsplit`, update cmux's submodule pointer.
5. Implement the cmux actions, routing, localization, docs, and tests.
6. Push `feat/10525-move-pane-outer-split` to `kyl33r/cmux` and open the cmux PR referencing #10525 and the Bonsplit dependency.

A cmux PR must not point at a fork-only Bonsplit commit because a clean `git submodule update` fetches from `manaflow-ai/bonsplit`.

## Approved Decisions

- [x] Use a 50/50 initial root share, clamped to Bonsplit configuration.
- [x] Reject Dock-owned focus in v1.
- [x] Use the Bonsplit → cmux coordinated change sequence.
- [x] Implement through the existing Bonsplit controller seam.
