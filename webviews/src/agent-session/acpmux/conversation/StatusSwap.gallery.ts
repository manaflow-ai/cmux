// l10n-allow-file: gallery fixtures, not shipped UI.
// The status lines that hand over from one step to the next: the composer hat's header with one
// subagent, and the running turn's live line under the reply (Leo, 2026-11-11: "the composer hat the
// way it switches between text is ugly bc it's too slow on the transitions and there's breif moments
// where it just looks like a blank tear that then switches"). Each change rolls: the old words go up
// and out of the line's box as the new come up into it, both opaque and on one clock, so every frame
// shows a full line of words and no frame shows two over each other. The mid-change variants hold
// the swap's own animations at one moment so a still shows it; test/status-swap-frames.test.ts reads
// every painted frame of the real swap, under a busy main thread too.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";

const next = (ctx: PlayContext) => ctx.click({ selector: '[data-stage="next"]' });

/// The swap's own animations still playing (the shimmer's and the spinner's endless loops keep
/// running; a finished roll that holds its end, Thinking's `.cv-roll-out` with `fill: both`, stays in
/// `getAnimations()` while its words stay mounted, so it counts as done, not as playing).
const swapAnimations = (doc: Document) =>
  doc
    .getAnimations()
    .filter((animation) => animation.effect?.getTiming().iterations !== Infinity && animation.playState !== "finished");

/// Hold the change `ms` in, so the still shows the old words leaving and the new arriving.
const holdAt = (ms: number) => async (ctx: PlayContext) => {
  await next(ctx);
  for (const animation of swapAnimations(ctx.document)) {
    animation.pause();
    animation.currentTime = ms;
  }
};

export default componentEntry<{ sequence?: "leo" }>({
  id: "agent-pane.status-swap",
  title: "Status lines: the hat's step and the live line roll to the next",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/subagents/trayMotion.tsx#Tick",
    "agent-session/acpmux/conversation/Thinking.tsx#Thinking",
  ],
  load: () => import("../../../gallery/fixtures/StatusSwapStage").then((module) => module.StatusSwapStage),
  pane: true,
  height: 260,
  variants: {
    "at-rest": {
      note: "Thinking on the live line; the hat names its subagent's step.",
      props: {},
    },
    "mid-roll-early": {
      note: "30 ms into a change: the new words come up under the old, both whole inside the line's box.",
      props: {},
      play: holdAt(30),
    },
    "mid-roll-half": {
      note: "Halfway: half a line of each, the old above the new, never a blank line.",
      props: {},
      play: holdAt(60),
    },
    "mid-roll-late": {
      note: "Near the end: the new words almost in place, the old almost out of the box.",
      props: {},
      play: holdAt(100),
    },
    "leo-sequence": {
      note: 'Leo\'s recording, 2026-11-11: "Thinking 1m · 1.7K tokens", "Sending a message 1m · 1.7K tokens", "Thinking 1m 5s · 2.5K tokens". The whole line rolls, its time and tokens with its words: no count pops off or on.',
      props: { sequence: "leo" },
    },
    "leo-sequence-mid-roll": {
      note: "Halfway into Thinking to Sending a message: the old line, tokens and all, half out above; the new half in below.",
      props: { sequence: "leo" },
      play: holdAt(60),
    },
    play: {
      note: "Four steps: each change rolls on the hat and on the live line.",
      props: {},
      play: async (ctx: PlayContext) => {
        for (let step = 0; step < 4; step++) {
          await next(ctx);
          await ctx.waitFor(() => swapAnimations(ctx.document).length === 0);
        }
      },
    },
  },
});
