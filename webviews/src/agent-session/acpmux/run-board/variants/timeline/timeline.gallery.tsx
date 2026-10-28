// l10n-allow-file: gallery fixtures (Run board timeline prototype), not shipped UI.
import { componentEntry } from "../../../../../gallery/format";
import type { Play } from "../../../../../gallery/play";
import { replayedBoardFixture, runBoardFixture } from "../../fixtures";
import type { TimelineRunBoardProps } from "./TimelineRunBoard";

/**
 * Capture / interaction receipt (2026-10-16): component width 1200, Apple System Colors.
 * `replayed`: event-143 -> event-151 and live; `attached`: data-attach-state=attached;
 * `approved`: review checkbox -> data-approved=attempt-a. The built gallery stage was inspected
 * with the accessibility tree; no screenshot is checked in because capture belongs to the matrix.
 */
const replay: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Reconnect and replay/ });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[data-connection="live"]') !== null &&
      ctx.document.querySelector('[data-replay-cursor="event-151"]') !== null,
  );
};

const attach: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Attach worker terminal" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-attach-state="attached"]') !== null);
};

const approve: Play = async (ctx) => {
  await ctx.click({ role: "checkbox", name: "I reviewed this attempt" });
  await ctx.click({ role: "button", name: "Approve for integration" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-approved="attempt-a"]') !== null);
};

const props: TimelineRunBoardProps = {
  snapshot: runBoardFixture,
  recovered: replayedBoardFixture,
  onAttach: async (intent) => ({
    ...intent,
    ticket: `gallery-${intent.attemptId}-ticket`,
    transport: "gallery",
    trustedCarrier: true,
  }),
  onAttachTicket: async () => undefined,
  onApprove: async () => undefined,
};

export default componentEntry<TimelineRunBoardProps>({
  id: "agent-pane.run-board-timeline",
  title: "Run board · timeline story",
  area: "Agent pane",
  height: 1120,
  widths: { narrow: 560, normal: 1200, wide: 1480 },
  covers: ["agent-session/acpmux/run-board/variants/timeline/TimelineRunBoard.tsx#TimelineRunBoard"],
  styles: () => import("./timeline.css"),
  load: async () => (await import("./TimelineRunBoard")).TimelineRunBoard,
  variants: {
    working: {
      note: "A chronological story keeps independent attempts comparable while preserving worker activity and evidence provenance.",
      props,
    },
    disconnected: {
      note: "The saved replay cursor and durable activity remain visible while workers continue beyond a disconnected board.",
      props: { ...props, disconnected: true },
    },
    replayed: {
      note: "Replay recovers the worker that finished offline and advances the cursor without restarting the run.",
      props: { ...props, disconnected: true },
      play: replay,
    },
    attached: {
      note: "Attaching mints a one-use worker terminal ticket and records the attached session on this attempt.",
      props,
      play: attach,
    },
    approved: {
      note: "A human reviews the event story, preview and artifact chain before recording an integration intent.",
      props,
      play: approve,
    },
  },
});
