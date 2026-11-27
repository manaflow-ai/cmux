// l10n-allow-file: gallery fixtures (Run board comparison prototype), not shipped UI.
import { componentEntry } from "../../../../../gallery/format";
import type { Play } from "../../../../../gallery/play";
import { replayedBoardFixture, runBoardFixture } from "../../fixtures";
import type { AttachTicketIntent, RunAttachTicket } from "../../runApi";
import type { CompareRunBoardProps } from "./CompareRunBoard";

const fixtureTicket = (intent: AttachTicketIntent): RunAttachTicket => ({
  runId: intent.runId,
  attemptId: intent.attemptId,
  sessionId: intent.sessionId,
  cursor: intent.cursor,
  ticket: `gallery-ticket-${intent.attemptId}`,
  expiresAtUnix: 4_000_000_000,
});

const selectCandidate: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Select Attempt C as comparison winner" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-selected-attempt="attempt-c"]'));
};

const reconnectAndReplay: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Reconnect and replay" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-replay-state="replayed"]'));
  await ctx.waitFor(() =>
    ctx.document
      .querySelector('[data-testid="compare-capture-receipt"]')
      ?.textContent?.includes("Replayed through event 151"),
  );
};

const attachTerminal: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Attach terminal to Attempt B" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-attach-state="attached"]'));
  await ctx.waitFor(() =>
    ctx.document
      .querySelector('[data-testid="compare-capture-receipt"]')
      ?.textContent?.includes("Attached terminal to Attempt B"),
  );
};

const approveWinner: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Select Attempt A as comparison winner" });
  await ctx.click({ role: "checkbox", name: "I reviewed Attempt A" });
  await ctx.click({ role: "button", name: "Approve Attempt A for integration" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-approved="attempt-a"]'));
};

const callbacks: Pick<CompareRunBoardProps, "onAttach" | "onAttachTicket" | "onApprove"> = {
  onAttach: async (intent) => fixtureTicket(intent),
  onAttachTicket: async () => undefined,
  onApprove: async () => undefined,
};

const props: CompareRunBoardProps = { snapshot: runBoardFixture, recovered: replayedBoardFixture, ...callbacks };

export default componentEntry<CompareRunBoardProps>({
  id: "agent-pane.run-board.compare",
  title: "Run board · candidate comparison matrix",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 1100,
  widths: { narrow: 560, normal: 1180, wide: 1480 },
  anchors: [{ testId: "compare-capture-receipt" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Selection, replay, attach and approval update the stable capture receipt without moving it.",
    },
    settleMaxMs: {
      value: 250,
      reason:
        "Matrix selection and human review controls are local state changes and should settle within a quarter second.",
    },
  },
  covers: ["agent-session/acpmux/run-board/variants/compare/CompareRunBoard.tsx#CompareRunBoard"],
  styles: () => import("./styles.css"),
  load: async () => (await import("./CompareRunBoard")).CompareRunBoard,
  variants: {
    matrix: {
      note: "Capture receipt: four independent previews share event 143; selecting Attempt C makes the winner state explicit while every evidence row stays synchronized.",
      props,
      play: selectCandidate,
    },
    "offline-replay": {
      note: "Interaction receipt: the offline banner preserves the last durable snapshot, then reconnect and replay recovers Attempt C through event 151.",
      props: { ...props, disconnected: true },
      play: reconnectAndReplay,
    },
    "attach-terminal": {
      note: "Interaction receipt: the one-use attach bridge returns a fixture ticket, attaches Attempt B, and records the terminal handoff in the live capture receipt.",
      props,
      play: attachTerminal,
    },
    "approve-winner": {
      note: "Interaction receipt: a human selects Attempt A, checks its verified evidence and records a cursor-bound integration approval.",
      props,
      play: approveWinner,
    },
  },
});
