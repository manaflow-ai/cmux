// l10n-allow-file: synthetic run steps and gallery controls, not shipped UI.
// Home's run card folds on the settle (Leo, 2026-11-07: "they dont overshoot but they decelerate at the
// end. i think that might be the key"): the card's steps, and a grouped tool run's details inside them.
// Closed, open, and frozen partway through the fold, so the curve's long soft tail can be read in a still.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { RunCard } from "./RunCard";
import type { HomeRunStep } from "./types";

const step = (id: string, seq: number, command: string): HomeRunStep => ({
  id,
  kind: "tool",
  seq,
  at: seq,
  rev: 1,
  text: id,
  links: [],
  attachments: [],
  status: "done",
  tool: { name: "Bash", title: command, input: { command }, files: [] },
});
const steps = [
  step("s1", 1, "rg --files webviews/src/pages/home-channels"),
  step("s2", 2, "bun test test/fold-settle-home.test.tsx"),
  step("s3", 3, "git diff --stat"),
];
const run = {
  id: "gallery-run",
  conversation: "gallery-conversation",
  author: "chief",
  status: "done",
  startedAt: 0,
  endedAt: 84_000,
  updatedAt: 84_000,
  rev: 1,
  stepCount: steps.length,
  turn: "gallery-turn",
  answers: [],
};

function Folds() {
  const [strings] = useState(() => createStrings(table));
  return (
    <div style={{ padding: 16, maxWidth: 560 }}>
      <RunCard
        entry={{ run: run as never, steps, complete: true }}
        strings={strings}
        onOpen={() => undefined}
        onLoad={() => undefined}
      />
      <p style={{ margin: "12px 0 0" }}>The next message, under the card.</p>
    </div>
  );
}

const TOGGLE = "button.lg-run-toggle";
const settled = (ctx: PlayContext) => ctx.document.getAnimations().length === 0;

/// The steps open, then a tool run inside them opens: each ends exactly on its layout, nothing held.
const openSteps: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(TOGGLE));
  await ctx.click({ selector: TOGGLE });
  await ctx.waitFor(() => ctx.document.querySelector(".lg-run-steps") && settled(ctx), { capMs: 3000 });
  const summary = ctx.document.querySelector(".lg-home-tool-summary");
  if (summary) {
    await ctx.click({ selector: ".lg-home-tool-summary" });
    await ctx.waitFor(() => settled(ctx), { capMs: 3000 });
  }
  if (ctx.document.querySelector("[data-folding]")) throw new Error("A fold ended still clipped");
};

/// The steps opening, held 60 ms in.
const midFold: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(TOGGLE));
  await ctx.click({ selector: TOGGLE });
  await ctx.waitFor(() => ctx.document.getAnimations().length > 0);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 60;
  }
};

export default componentEntry({
  id: "home.run-card-folds",
  title: "Home run card folds",
  area: "Home and Chief",
  height: 520,
  widths: { narrow: 390, normal: 620 },
  covers: [
    "pages/home-channels/RunCard.tsx",
    "pages/home-channels/HomeToolGroup.tsx",
    "agent-session/shared/FoldDetails.tsx#FoldDetails",
  ],
  load: async () => Folds,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/ui.css");
    await import("../../agent-session/acpmux/conversation/conversation.css");
    await import("./styles.css");
    await import("./ledger.css");
  },
  variants: {
    closed: {
      note: "A finished run, folded: its label, step count and chevron, and the next message under it.",
      props: {},
    },
    "steps-open-settle": {
      note: 'Chosen. The card opens its steps, then a grouped tool run opens its details: each box grows and its rows fade in on the settle (--cmux-ease-settle over --cmux-motion-settle, 265 ms), the message under the card moving on the same frames and the chevron turning with it, decelerating into the end, never past it (Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key").',
      props: {},
      play: openSteps,
    },
    "steps-mid-fold": {
      note: "The steps opening, held 60 ms in, on the settle's long soft tail.",
      props: {},
      play: midFold,
    },
  },
});
