// l10n-allow-file: gallery fixtures for the live line's tool calls, not shipped UI.
// The live line's words change as Claude desktop's do (Leo, 2026-11-05: "this is quite good too how
// it animates the changing text!!! we need to have that!!! for changing tool calls at the bottom"):
// the old call rises out, the new one rises in, and the turn's clock slides to its end while it
// ticks (ui/motion/useTextSwap.ts). The mid-change variants hold every finite animation at one
// moment so the still shows the motion; the live page (Replay) plays it.
import { useLayoutEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { Thinking } from "./Thinking";

const CALLS = [
  "Reading daemon log_load and startup",
  "Running a command",
  "Checking time and REST quota",
  "Finding _acpmux/watch and sessions callers",
];

type Variant = "at-rest" | "mid-change" | "longer-call" | "changed" | "fast-calls" | "motion-off";

function Fixture({ variant }: { variant: Variant }) {
  const [step, setStep] = useState(variant === "longer-call" ? 1 : 0);
  // Seven minutes into the turn, as in the recording.
  const [since] = useState(() => Date.now() - 7 * 60_000 - 4_000);
  useLayoutEffect(() => {
    if (variant !== "motion-off") return;
    const root = document.documentElement;
    const before = root.dataset.cmuxMotion;
    root.dataset.cmuxMotion = "off";
    return () => {
      if (before === undefined) delete root.dataset.cmuxMotion;
      else root.dataset.cmuxMotion = before;
    };
  }, [variant]);
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <button type="button" style={{ marginBottom: 16 }} onClick={() => setStep((value) => value + 1)}>
        Next call
      </button>
      <Thinking since={since} doing={CALLS[step % CALLS.length]} doingAt={step} />
    </div>
  );
}

/// The swap's own animations (the shimmer's endless loops keep running).
const swapAnimations = (doc: Document) =>
  doc.getAnimations().filter((animation) => animation.effect?.getTiming().iterations !== Infinity);

/// Hold the change `ms` in, so the still shows the old words leaving and the new arriving.
const holdAt = (ms: number) => (ctx: PlayContext) => {
  for (const animation of swapAnimations(ctx.document)) {
    animation.pause();
    animation.currentTime = ms;
  }
};

const next = (ctx: PlayContext) => ctx.click({ role: "button", name: "Next call" });
const settled = (ctx: PlayContext) => ctx.waitFor(() => swapAnimations(ctx.document).length === 0);

export default componentEntry<{ variant: Variant }>({
  id: "agent-pane.live-line-text-swap",
  title: "Live line: the call's words change in place",
  area: "Agent pane",
  pane: true,
  height: 140,
  widths: { narrow: 360, normal: 560 },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking", "ui/motion/useTextSwap.ts#useTextSwap"],
  variants: {
    "at-rest": {
      props: { variant: "at-rest" },
      note: "A call in flight, with the turn's clock after it.",
    },
    "mid-change": {
      props: { variant: "mid-change" },
      note: "60 ms into a shorter call: the old words rise and fade while the clock slides left.",
      play: async (ctx) => {
        await next(ctx);
        holdAt(60)(ctx);
      },
    },
    "longer-call": {
      props: { variant: "longer-call" },
      note: "60 ms into a longer call: the new words rise in as the clock slides right.",
      play: async (ctx) => {
        await next(ctx);
        holdAt(60)(ctx);
      },
    },
    changed: {
      props: { variant: "changed" },
      note: "The change ended: the new call alone, the clock at its end, no copy left on the line.",
      play: async (ctx) => {
        await next(ctx);
        await settled(ctx);
      },
    },
    "fast-calls": {
      props: { variant: "fast-calls" },
      note: "Three calls faster than the motion: each starts from where the line is; at most two old copies.",
      play: async (ctx) => {
        await next(ctx);
        await next(ctx);
        await next(ctx);
        holdAt(40)(ctx);
      },
    },
    "motion-off": {
      props: { variant: "motion-off" },
      note: "Animations off (data-cmux-motion=off): the new call shows in one frame, nothing moves.",
      play: async (ctx) => {
        await next(ctx);
        await ctx.waitFor(
          () => swapAnimations(ctx.document).length === 0 && !ctx.document.querySelector(".ui-text-swap__ghost"),
        );
      },
    },
  },
  load: () => Promise.resolve(Fixture),
});
