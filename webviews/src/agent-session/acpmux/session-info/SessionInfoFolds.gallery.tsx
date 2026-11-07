// l10n-allow-file: synthetic sessions and gallery controls, not shipped UI.
// Session Info's folds that move on the settle with this sweep: Usage's View all / Show fewer, a Context
// list, a workflow's phase, its N finished and a finished agent's output (Leo, 2026-11-07: "they dont
// overshoot but they decelerate at the end. i think that might be the key"). Closed, open, and frozen
// partway through the fold, so the curve's long soft tail can be read in a still.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { CONTEXT_BREAKDOWN } from "../../../gallery/fixtures/acpmux";
import { createWorkflowAdapter } from "../summary/foldWorkflows";
import { workflowFixture } from "../summary/workflowFixture";
import { ContextBreakdownView, contextBreakdown } from "./ContextSection";
import { USAGE_SHOWN, UsageSection } from "./UsageSection";
import type { UsageEntry } from "./usageEntries";
import { WorkflowAgentRow, WorkflowTasks } from "./WorkflowTasks";
import "./sessionInfo.css";

const NOW = 1_800_000_000_000;

const sessions: UsageEntry[] = Array.from({ length: USAGE_SHOWN + 4 }, (_, index) => ({
  sessionId: `gallery-${index}`,
  title: [
    "Fold sweep",
    "Release notes",
    "Sidebar rows",
    "Composer hat",
    "Theme pass",
    "Nightly",
    "Docs",
    "Probe",
    "Spike",
  ][index],
  ...(index % 3 === 0 ? { host: "big-red" } : {}),
  usageStats: {
    autocompact: "capped",
    contextTokens: 12_000 * (USAGE_SHOWN + 4 - index),
    costUsd24h: 0.4 * (USAGE_SHOWN + 4 - index),
    updatedAt: NOW,
  },
}));

function Folds() {
  const [run] = useState(() => ({
    running: createWorkflowAdapter()(workflowFixture("running", NOW), "gallery-chat")[0]!,
    finished: createWorkflowAdapter()(workflowFixture("finished", NOW), "gallery-chat")[0]!,
  }));
  const breakdown = contextBreakdown(CONTEXT_BREAKDOWN)!;
  const done = run.finished.agents.find((agent) => agent.state === "completed")!;
  return (
    <div className="acpmux-shell" style={{ padding: 12 }}>
      <div className="acpmux-session-info" style={{ width: 320 }}>
        <div className="acpmux-session-info__body">
          <section data-fold="usage">
            <UsageSection sessions={sessions} />
          </section>
          <section data-fold="context">
            <ContextBreakdownView breakdown={breakdown} bar={false} />
          </section>
          <section data-fold="workflow">
            <WorkflowTasks workflows={[run.running]} onStop={async () => undefined} />
          </section>
          <section data-fold="output">
            <ul className="acpmux-session-info-list">
              <WorkflowAgentRow workflow={run.finished} agent={done} now={NOW} />
            </ul>
          </section>
        </div>
      </div>
    </div>
  );
}

/// Every fold's toggle, closed at first except N finished (which starts open).
const TOGGLES = [
  "[data-fold=usage] button.acpmux-session-info-usage-fold",
  "[data-fold=context] button.acpmux-context-breakdown__fold",
  "[data-fold=workflow] button.acpmux-workflow-phase__head:not(:disabled)",
  "[data-fold=workflow] button.acpmux-workflow-finished__fold",
  "[data-fold=output] button.acpmux-workflow-agent__disclosure",
];

const settled = (ctx: PlayContext) => ctx.document.getAnimations().length === 0;

async function toggleAll(ctx: PlayContext) {
  for (const selector of TOGGLES) {
    await ctx.waitFor(() => ctx.document.querySelector(selector));
    await ctx.click({ selector });
  }
}

/// Each fold flips and ends exactly on its final layout: nothing left running, clipped or held.
const foldAll: Play = async (ctx) => {
  await toggleAll(ctx);
  await ctx.waitFor(() => settled(ctx), { capMs: 3000 });
  if (ctx.document.querySelector("[data-folding]")) throw new Error("A fold ended still clipped");
  for (const selector of TOGGLES) {
    const expanded = ctx.find({ selector }).getAttribute("aria-expanded");
    const startsOpen = selector.includes("finished__fold");
    if (expanded !== String(!startsOpen)) throw new Error(`${selector} did not flip`);
  }
};

/// Each fold flips, then every motion is held 60 ms in: the boxes partway, decelerating into their end.
const midFold: Play = async (ctx) => {
  await toggleAll(ctx);
  await ctx.waitFor(() => ctx.document.getAnimations().length > 0);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 60;
  }
};

export default componentEntry({
  id: "agent-pane.session-info-folds",
  title: "Session Info folds",
  area: "Agent pane",
  pane: true,
  height: 900,
  widths: { narrow: 340 },
  covers: [
    "agent-session/acpmux/session-info/UsageSection.tsx",
    "agent-session/acpmux/session-info/ContextSection.tsx",
    "agent-session/acpmux/session-info/WorkflowTasks.tsx",
  ],
  load: async () => Folds,
  variants: {
    closed: {
      note: "At rest: Usage shows its first five chats, Context's lists and the running phase are closed, N finished is open and the finished agent's output is closed. Each chevron is one glyph, turned a quarter when open.",
      props: {},
    },
    "fold-settle": {
      note: 'Chosen. Every fold flips: each box\'s height moves from where it is drawn to where it ends on the settle (--cmux-ease-settle, cubic-bezier(0.16, 1, 0.3, 1) over --cmux-motion-settle, 265 ms), a box that opens from nothing fading in with it, the rows under it and the chevrons moving on the same frames, and nothing popping in or out when it ends (Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key").',
      props: {},
      play: foldAll,
    },
    "mid-fold": {
      note: "The same folds held 60 ms in: most of the way there already, decelerating into the end on the settle's long tail.",
      props: {},
      play: midFold,
    },
  },
});
