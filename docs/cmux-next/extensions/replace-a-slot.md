# Replace a slot: the thinking indicator

A **theme slot** is a named place in cmux whose look and motion a theme can swap: the little bits of
delight a theme pack changes so the whole app reads as its own. Each slot has a contract (the props it
gets, the box it must fit, the motion it may use, what it does under Reduce Motion, when it stops), and
every variant of it, ours included, keeps that contract. cmux's default is just the variant called
`default`, registered the same way yours is.

The first slot is the agent chat's thinking indicator, `chat.thinkingIndicator`: the live line's word
("Thinking", or the rotating verb) while a turn thinks before it names a step.

- The contract: [`schemas/theme/slots.json`](../../../schemas/theme/slots.json)
- The registry and `<Slot>`: [`webviews/src/slots/`](../../../webviews/src/slots/registry.ts)
- The built-in variants: [`webviews/src/slots/thinkingIndicator/`](../../../webviews/src/slots/thinkingIndicator/index.ts)
- The gallery entry: `agent-pane.thinking-indicator-slot`
- The check: `bun run check:theme-slots` (in `webviews/`, part of `bun run check`)

## Pick a variant

The theme look carries a `slots` map, slot id to variant id:

```json
{ "slots": { "chat.thinkingIndicator": "counting-dots" } }
```

cmux ships `default` (the shimmer), `counting-dots`, `pulse`, `caret` and `blocks`. A look without
`slots`, or one naming an id no variant has, draws the default, so a stale theme never blanks a slot.

To try one in the app today, set the debug key in the agent pane's web inspector and reload the pane:

```js
localStorage.setItem("cmux.slots", JSON.stringify({ "chat.thinkingIndicator": "blocks" }));
```

The order is: an override the host installs (`globalThis.cmuxSlots`, the gallery), then that debug
key, then the theme look's `slots`, then the default.

## Write a variant

A variant is a React component that takes the slot's props and draws inside the slot's box. Copy this,
rename it, and change the mark and its keyframes.

`webviews/src/slots/thinkingIndicator/OrbitMark.tsx`:

```tsx
// `chat.thinkingIndicator` / `orbit`: a dot circling a small ring after the word.
import { ReservedLabel, type ThinkingIndicatorProps } from "./slot";

export function OrbitMark({ label, verbs }: ThinkingIndicatorProps) {
  return (
    <span className="slot-thinking" data-variant="orbit">
      {/* The word at its reserved width: a verb change never moves what follows. */}
      <ReservedLabel label={label} verbs={verbs} />
      {/* One mark of a fixed size, hidden from readers, Find and the pointer. */}
      <span className="slot-thinking__mark slot-orbit" aria-hidden="true" inert>
        <span className="slot-orbit__dot" />
      </span>
    </span>
  );
}
```

Its styles, in the variant's stylesheet (`thinkingIndicator.css`, or a sheet of its own that the
component imports):

```css
/* The box: fixed, so swapping variants never moves the line or the transcript. */
.slot-orbit {
  inline-size: 0.75em;
  justify-content: center;
}
/* The still frame, outside the motion gate: what Reduce Motion and static status indicators see. */
.slot-orbit__dot {
  inline-size: 0.1875em;
  block-size: 0.1875em;
  border-radius: 999px;
  background: currentColor;
  transform: translateX(0.25em);
}
/* The motion: inside prefers-reduced-motion: no-preference and under the slot's motion gate. */
@media (prefers-reduced-motion: no-preference) {
  :root:not([data-status-indicators="static"], [data-agent-motion="off"], [data-cmux-motion="off"], [data-cmux-motion="reduced"]) .slot-orbit__dot {
    animation: slot-orbit var(--cmux-spinner-period) linear infinite;
  }
}
/* Transform and opacity only: the compositor runs it, the page paints nothing per frame. */
@keyframes slot-orbit {
  from {
    transform: rotate(0deg) translateX(0.25em);
  }
  to {
    transform: rotate(360deg) translateX(0.25em);
  }
}
```

Register it next to the others in `index.ts` (or from your own module with `registerSlotVariant`):

```ts
import { OrbitMark } from "./OrbitMark";
export const THINKING_INDICATOR_VARIANTS = { /* ... */ orbit: OrbitMark } as const;
```

and list it in `schemas/theme/slots.json` under the slot's `variants`, with its `source` and `styles`:

```json
{
  "id": "orbit",
  "label": "Orbit",
  "docs": "A dot circling a small ring after the word.",
  "source": "webviews/src/slots/thinkingIndicator/OrbitMark.tsx",
  "styles": ["webviews/src/slots/thinkingIndicator/thinkingIndicator.css"]
}
```

Then add a gallery variant for it in `ThinkingIndicator.gallery.tsx` (`props: { variant: "orbit" }`)
and look at it beside the others, with Reduce Motion on.

## The performance rules, and what checks them

`bun run check:theme-slots` reads `slots.json` and fails a variant that breaks one of these (the
no-breathing row is the webviews test lane's):

| rule | what it means | how it's checked |
| --- | --- | --- |
| compositor only | keyframes and transitions change only `transform` and `opacity` (`all` is not allowed) | every `@keyframes` declaration, `transition`, `transition-property` and `will-change` in the variant's `styles` |
| zero JS per frame | no `requestAnimationFrame`, `setInterval`, `setTimeout`, `requestIdleCallback`, `.animate(` or page clock in the variant's `source`: the motion is CSS, so its main-thread cost per frame is zero by construction | the variant's `source` |
| tokens only | durations are `var()`s of the motion tokens in `slots.json` (`--cmux-motion-*`, `--cmux-spinner-period`, the loop periods); easings are `--cmux-ease-*`, `linear` or `steps()`; no `ms`/`s` literal, not even in a custom property | every `animation*`/`transition*` declaration and custom property |
| reduced motion | every animation is inside `@media (prefers-reduced-motion: no-preference)` and under the motion gate; what is written outside is the still frame | the variant's `styles` |
| no breathing | no mark fades, blinks or pulses forever (an infinite loop whose keyframes move `opacity`, `visibility` or `scale`); a loop moves a mark from place to place instead, like `blocks` and `counting-dots` | `webviews/test/no-breathing-dots.test.ts`, over every shipped stylesheet |
| fixed box | the same block size as the line, and a mark whose inline size never changes while it runs | review, and the gallery's layout-shift gate |
| stops | the slot is drawn only while the turn thinks with no step named; a hidden page pauses every loop | the slot's placement (Thinking.tsx), `data-cmux-page-hidden` |

A variant may change its look over time only through props the line already updates: `elapsedMs` moves
with the line's existing one-second clock (that is how `counting-dots` grows a fourth dot past 20 s).

If a variant throws while rendering, its slot alone falls back to the default (an error boundary per
slot), logs a warning, and the chat keeps going. The `fallback-on-error` gallery state shows it.

## Next slots

Named in the same id scheme, not built yet:

- `chat.jumpToBottom`: the transcript's jump-to-latest button, how it appears, rests and leaves.
- `chat.sendTransition`: a sent prompt's arrival in the transcript.
- `chat.receiveTransition`: a reply's first words arriving under the live line.
- `chat.sideInteraction`: the /side interaction, how a side question opens beside the thread and folds back.
- `chat.rowHover`: a transcript row's hover, its fill and the actions it reveals.

Each gets a `slots.json` entry with the same fields, a `<Slot>` where the surface draws it today, its
current look moved in as `default` with the same markup, and a gallery entry.
