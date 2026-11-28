# Status of `ui` and `kit` exports

Every export of `webviews/src/ui` and `webviews/src/kit` has one of three statuses. Each status is a
promise to the pages, panes and customizations that import it. Status lives in the code so editors
can show it at a call site.

| Status         | How it is marked                                                                 | What we promise                                                                                                                                              |
| -------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ready`        | The default, except for components covered only by experimental gallery entries. | A breaking change comes with a migration note in the PR and a codemod or lint autofix that moves every caller in the repo, in the same PR.                   |
| `experimental` | `@status experimental` in the export's doc                                       | Nothing. It may change shape or go away in any PR. Experiment definitions (`*.experiment.ts`) and the props only an experiment's arm draws are experimental. |
| `deprecated`   | `@deprecated Use X` in the export's doc                                          | It names its replacement, which already exists, and it keeps working until its last caller has moved. Runtime warnings are development-only.                 |

## Ready

The default. Before you break a ready export (rename it, remove a prop, change what a prop means or
what it draws), write in the PR how a caller moves, and move every caller with a codemod or a lint
autofix rather than by hand. A change that keeps every caller's meaning and pixels is not breaking.

## Experimental

Use it, but expect it to move. Tag it with `@status experimental` and a few words on why, for
example:

```ts
/** @status experimental */
export const menuStyleV2 = defineExperiment({ ... });
```

An experimental export becomes ready when its experiment settles (the winning arm is the only one
left) or when it stops changing, by removing the tag.

## Deprecated

Tag an export or prop `@deprecated` only when its replacement exists today, and name the
replacement in the tag. On a component, also add `@status deprecated` for the component manifest. Editors strike the name through at every call site. Nothing is deleted while
callers remain.

```ts
/** @deprecated Use `Glass` from kit/index.ts.
 * @status deprecated
 */
export function Glass(...)
```

A deprecated component can also warn at run time in development. `warnDeprecated(name, replacement)`
in `ui/deprecation.ts` logs one `console.warn` per name, and only when `import.meta.env.DEV` is true.
A production build reads that flag as false, so the call does nothing there. Call it only from
code paths that are themselves deprecated.

```ts
import { warnDeprecated } from "./deprecation";

export function OldThing(props: OldThingProps) {
  warnDeprecated("OldThing", "NewThing");
  ...
}
```

## What is tagged today

- Deprecated: `ui/glass/Glass` (use `Glass` from `kit/index.ts`, or the `ui-glass` class).
- Experimental: each `defineExperiment` export in a `*.experiment.ts` file, `installLiveBackground`,
  `Notice`'s `look` and `hostGlass`, `MenuItem`'s `reason`, and `ContextMenuItem`'s `reason` and `async`.
  The component manifest also marks a component experimental when all its gallery entries are experimental.
