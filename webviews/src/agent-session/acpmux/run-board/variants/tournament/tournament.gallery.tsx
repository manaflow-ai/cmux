// l10n-allow-file: gallery fixtures (top-two run board tournament), not shipped UI.
import { componentEntry } from "../../../../../gallery/format";
import type { Play } from "../../../../../gallery/play";
import { replayedBoardFixture, runBoardFixture } from "../../fixtures";
import type { AttachTicketIntent, RunAttachTicket } from "../../runApi";
import type { TournamentRunBoardProps } from "./TournamentRunBoard";

/**
 * Deterministic receipt for the remote gallery matrix (2026-10-16):
 * - capture anchor: [data-testid="tournament-capture-receipt"]
 * - pane identity: [data-tournament-pane="compare"] and [data-tournament-pane="timeline"]
 * - select/review: [data-selected-attempt="attempt-a"] and [data-review-state="reviewed"]
 * - reconnect/replay: [data-replay-state="replayed"] and "Replayed through event 151"
 * - attach: [data-attach-state="attached"] and "Attached terminal to Attempt B"
 * - approve: [data-approved="attempt-a"]
 * The remote gallery matrix is the capture path; no local browser or native build is used.
 */

const fixtureTicket = (intent: AttachTicketIntent): RunAttachTicket => ({
  runId: intent.runId,
  attemptId: intent.attemptId,
  sessionId: intent.sessionId,
  cursor: intent.cursor,
  ticket: `tournament-gallery-${intent.attemptId}`,
  expiresAtUnix: 4_000_000_000,
});

const comparePane = '[data-tournament-pane="compare"]';

const selectAndReview: Play = async (ctx) => {
  await ctx.click({ selector: `${comparePane} [data-select-attempt="attempt-a"]` });
  await ctx.click({ selector: `${comparePane} input[aria-label="I reviewed Attempt A"]` });
  await ctx.waitFor(() => ctx.document.querySelector(`${comparePane} [data-review-state="reviewed"]`));
};

const reconnectAndReplay: Play = async (ctx) => {
  await ctx.click({ selector: `${comparePane} [data-replay-banner] button` });
  await ctx.waitFor(() => ctx.document.querySelector(`${comparePane} [data-replay-state="replayed"]`));
  await ctx.waitFor(() =>
    ctx.document
      .querySelector(`${comparePane} [data-testid="compare-capture-receipt"]`)
      ?.textContent?.includes("Replayed through event 151"),
  );
};

const attachTerminal: Play = async (ctx) => {
  await ctx.click({ selector: `${comparePane} [aria-label="Attach terminal to Attempt B"]` });
  await ctx.waitFor(() => ctx.document.querySelector(`${comparePane} [data-attach-state="attached"]`));
  await ctx.waitFor(() =>
    ctx.document
      .querySelector(`${comparePane} [data-testid="compare-capture-receipt"]`)
      ?.textContent?.includes("Attached terminal to Attempt B"),
  );
};

const approveWinner: Play = async (ctx) => {
  await ctx.click({ selector: `${comparePane} [data-select-attempt="attempt-a"]` });
  await ctx.click({ selector: `${comparePane} input[aria-label="I reviewed Attempt A"]` });
  await ctx.click({ selector: `${comparePane} .compare-approve` });
  await ctx.waitFor(() => ctx.document.querySelector(`${comparePane} [data-approved="attempt-a"]`));
};

const callbacks: Pick<TournamentRunBoardProps, "onAttach" | "onAttachTicket" | "onApprove"> = {
  onAttach: async (intent) => fixtureTicket(intent),
  onAttachTicket: async () => undefined,
  onApprove: async () => undefined,
};

const props: TournamentRunBoardProps = { snapshot: runBoardFixture, recovered: replayedBoardFixture, ...callbacks };

export default componentEntry<TournamentRunBoardProps>({
  id: "agent-pane.run-board-tournament",
  title: "Run board · top-two tournament judge",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 1760,
  widths: { normal: 1440 },
  anchors: [{ testId: "tournament-capture-receipt" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason:
        "The top-level capture receipt remains fixed while each child board changes local selection, replay, attach and approval state.",
    },
    settleMaxMs: {
      value: 350,
      reason: "Tournament plays only drive local fixture callbacks and the real run-board reducers.",
    },
  },
  covers: ["agent-session/acpmux/run-board/variants/tournament/TournamentRunBoard.tsx#TournamentRunBoard"],
  styles: async () => {
    await import("../compare/styles.css");
    await import("../timeline/timeline.css");
    await import("./styles.css");
  },
  load: async () => (await import("./TournamentRunBoard")).TournamentRunBoard,
  variants: {
    "top-two": {
      note: "Top-two judge: Compare and Timeline mount the exact same runBoardFixture and replayedBoardFixture at one normal width; the rail records the 28/35 tie and pending admission contract.",
      props,
    },
    "select-review": {
      note: "Deterministic receipt: Compare selects Attempt A and records the real evidence review state while Timeline remains mounted beside it.",
      props,
      play: selectAndReview,
    },
    "reconnect-replay": {
      note: "Deterministic receipt: the disconnected Compare pane replays the exact recovered fixture through event 151.",
      props: { ...props, disconnected: true },
      play: reconnectAndReplay,
    },
    "attach-terminal": {
      note: "Deterministic receipt: Compare requests the fixture one-use ticket for Attempt B and records the attached state.",
      props,
      play: attachTerminal,
    },
    "approve-winner": {
      note: "Deterministic receipt: Compare selects Attempt A, reviews verified evidence and records the cursor-bound approval.",
      props,
      play: approveWinner,
    },
  },
});
