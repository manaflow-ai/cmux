# Custom sidebar interpreter: `@State` engine design

The leaf-tier surface (views, modifiers, shapes, gradients, value methods,
arbitrary-child modifiers) is implemented. The remaining frontier is
**interactivity**: `@State`, two-way `$bindings`, and the input controls that
need them (`TextField`, `Toggle`, `Slider`, `Picker`, `Stepper`), plus
author-driven state mutation from button actions. This converts the renderer
from one-shot to interactive. It is a single coherent capability and should land
as its own PR (it needs real dogfooding — typing/toggling/sliding — which a
non-interactive build pass cannot verify).

## What exists today

`SwiftViewInterpreter.evaluate(source, state:)` is **one-shot and read-only**:
it builds a fresh `Environment` from the read-only `state` dictionary, walks the
AST once, returns a `RenderNode` tree. The host (`ContentView`) re-invokes it on
a 1s `TimelineView` tick and on workspace changes. `ButtonAction` is a frozen
`[ActionCommand]` (`cmux`/`log`/`openURL`); actions never mutate interpreter
state. There is no `$binding` value, no mutable bag, no re-walk-on-change.

## The four pieces

1. **A mutable state bag, keyed by `@State` declaration site.**
   - Parse `@State private var name = <initial>` declarations at the top of the
     sidebar (and inside custom views, later). On first walk, seed the bag with
     the evaluated initial value, keyed by a **stable id** = the declaration's
     source location (`name` is sufficient at top level; for per-instance state
     inside `ForEach`/custom views use `name` + the enclosing identity path).
   - The bag is owned by the **host** (`CustomSidebarModel` / a new
     `SidebarStateStore` `@Observable`), NOT rebuilt each walk — it must survive
     re-interpretation. `evaluate` takes it as an `inout`/reference parameter.
   - `Environment.lookup(name)` reads the bag for `@State` names (falling back to
     the read-only data context).

2. **`$binding` values.** Add `SwiftValue.binding(get:set:)` (or a `RenderNode`
   binding field) carrying a stable key into the bag. `$name` in source resolves
   to a binding over `bag[key]`. A control bound to `$name` reads `bag[key]` for
   its value and writes back through the binding's setter.

3. **An action executor.** Generalize `ButtonAction` beyond `[ActionCommand]` to
   also carry **assignments**: `name = expr`, `name.toggle()`, `name += n`,
   `name.append(x)`. `parseAction` captures these as structured ops; on tap the
   executor evaluates the RHS against the current env+bag, writes the bag, and
   **requests a re-walk**. `cmux(...)` keeps flowing to the host dispatcher.

4. **Re-walk on change + input control kinds.**
   - When the bag changes (control edit or action assignment), the host
     re-invokes `evaluate` with the same bag → new `RenderNode` tree → SwiftUI
     diffs it. This is the existing TimelineView path, now also triggered by
     state changes (an `@Observable` bag the host view observes).
   - New kinds: `textField` (binding + placeholder), `toggle` (binding + label),
     `slider` (binding + range), `picker` (binding + options), `stepper`. Each
     stores its binding key; `RenderNodeView` renders the real control with a
     SwiftUI `Binding` whose get/set go through the host bag + re-walk.

## Suggested staging

- **S1 — state bag + read/`$` + assignment actions (no controls yet):** prove a
  `Button("inc") { count += 1 }` + `Text("\(count)")` round-trips and re-renders.
  Smallest end-to-end slice of the engine.
- **S2 — `Toggle`/`TextField`** bound to `$state` (the two highest-value
  controls). Dogfood typing/toggling.
- **S3 — `Slider`/`Picker`/`Stepper`** + `.onChange`/`on(event:)` author hooks.

## Constraints / gotchas

- Re-entrancy: a state write during a walk must not recurse the walk; mutate the
  bag, then schedule one coalesced re-walk (mirror the existing TimelineView
  cadence; do not sleep).
- Snapshot-boundary rule (CLAUDE.md): the bag is an `@Observable` the host view
  observes; rows still receive value snapshots, not the store.
- Identity for per-row `@State` (inside `ForEach`) is the hard part — defer to
  S3; S1/S2 can restrict `@State` to top level.
- Keep the one-shot path working when no `@State` is present (zero overhead).

## Touch-points

`RenderNode` (binding field / control kinds + `value`), `SwiftValue` (`.binding`),
`Environment` (bag reference + `$` resolution), `SwiftViewInterpreter`
(`@State` decl parse, control constructors, assignment capture in `parseAction`),
`RenderNodeView` (control rendering with host-backed `Binding`),
`CustomSidebarView`/`CustomSidebarModel` (own the `@Observable` bag, re-walk on
change), `SidebarActionDispatch` (carry assignment ops alongside commands).
