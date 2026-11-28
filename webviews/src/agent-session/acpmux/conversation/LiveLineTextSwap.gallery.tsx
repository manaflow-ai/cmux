// l10n-allow-file: gallery fixtures for the live line's tool calls, not shipped UI.
// The Working line changes its words as Claude desktop's
// do (Leo, 2026-11-05: "this is quite good too how it animates the changing text!!! we need to have
// that!!! for changing tool calls at the bottom"): the old call rises out, the new one rises in, and
// the clock slides to its end while it ticks, on the one text roll every live label shares
// (ui/motion/TextRoll.tsx): the old words roll out and the new roll in through the line's faded top
// and bottom edges (Leo, 2026-11-25: "the animation when it changes text at least in teh former is
// still quite jarring bc it doesn't fade at the top/bottom when switching"). The Codex-style live line
// (Thinking.tsx) rolls its own words (`useRoll`) under the same edge and clock. Three arms
// (ui/motion/textRoll.experiment.ts; view Compare arms) vary the fade's depth and the pace. The
// mid-change variants hold every finite animation at one moment so the still shows the motion; the
// live page (Replay) plays it.
import { useLayoutEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { textRollLook } from "../../../ui/motion/textRoll.experiment";
import type { AcpmuxRow } from "../model";
import { Tick } from "../subagents/trayMotion";
import { WorkingFor } from "./WorkingFor";

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
  const call = CALLS[step % CALLS.length];
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <button type="button" style={{ marginBottom: 16 }} onClick={() => setStep((value) => value + 1)}>
        Next call
      </button>
      <WorkingFor
        row={
          {
            id: "working",
            kind: "working",
            version: step + 1,
            at: since,
            doing: call,
          } as AcpmuxRow
        }
      />
      {/* A subagent activity row's latest line (AgentLine.tsx's Tick). */}
      <div style={{ marginTop: 12, fontSize: "var(--text-detail)", opacity: 0.8 }}>
        <Tick className="acpmux-agent-line__latest-inline" text={call} slide />
      </div>
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
  title: "Working line: the call's words change in place",
  area: "Agent pane",
  pane: true,
  height: 170,
  widths: { narrow: 360, normal: 560 },
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("../subagents/subagents.css")]),
  covers: [
    "agent-session/acpmux/conversation/WorkingFor.tsx#WorkingFor",
    "agent-session/acpmux/subagents/trayMotion.tsx#Tick",
    "ui/motion/TextRoll.tsx#TextRoll",
    "ui/motion/textRoll.experiment.ts",
  ],
  experiment: {
    definition: textRollLook,
    script: [
      { name: "a shorter call", run: next },
      { name: "a longer call", run: next },
      {
        name: "three calls faster than the roll",
        run: async (ctx) => {
          await next(ctx);
          await next(ctx);
          await next(ctx);
        },
      },
    ],
  },
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
      note: "Three calls faster than the motion: the roll lands, then rolls once to the latest call; one old copy at most.",
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
          () => swapAnimations(ctx.document).length === 0 && !ctx.document.querySelector(".ui-text-roll__out"),
        );
      },
    },
  },
  load: () => Promise.resolve(Fixture),
});
