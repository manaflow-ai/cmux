# AppKit sidebar interpreter surface

The custom-sidebar interpreter parses the cmux `.swift` sidebar DSL into a
`RenderNode` tree. `CmuxSwiftRenderUI` renders that tree with AppKit controls,
stack views, table views, scroll views, split views, Core Animation layers, and
native accessibility elements. The renderer never compiles or executes the
sidebar source.

## Ownership

- `CmuxSwiftRender` owns parsing, evaluation, state cells, and the render IR.
- `CmuxSwiftRenderUI` owns the in-process AppKit renderer and action targets.
- `CmuxSidebarInterpreterService` owns the isolated worker, bitmap transport,
  pointer forwarding, budgets, and last-good-render recovery.
- The cmux executable supplies immutable workspace snapshots and dispatches
  allowlisted actions through the normal command surface.

## Supported surface

The DSL supports text, symbols, buttons, menus, stacks, grids, lists, sections,
scrolling, split views, progress indicators, gauges, basic shapes, gradients,
reordering, conditional content, loops, local state, and common layout,
typography, decoration, interaction, and accessibility modifiers. The exact
authoring contract lives in `docs/custom-sidebars.md` and is exercised by the
examples in `Examples/CustomSidebars`.

## Boundaries

The language is interpreted and type-erased. It does not offer compiler type
checking, arbitrary framework imports, application or window ownership,
unrestricted file or network access, user-defined drawing contexts, or custom
runtime protocol conformances. New primitives must lower to structured IR and
render through AppKit. They must work in both in-process and isolated rendering,
respect evaluation budgets, expose native accessibility, and include behavior
tests at the parser, IR, and renderer boundaries.

## Concurrency

UI mutation is main-actor isolated. Parsing and serializable scene preparation
may run concurrently through explicit `async` APIs. Cross-process state is an
immutable snapshot, renderer events return through typed messages, and a stale
generation can never overwrite a newer render.
