// l10n-allow-file: gallery fixtures (Run board prototype), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { replayedBoardFixture, runBoardFixture } from "./fixtures";
import type { RunBoardProps } from "./RunBoard";

const approve: Play = async (ctx) => {
  await ctx.click({ role: "checkbox", name: "I reviewed this attempt" });
  await ctx.click({ role: "button", name: "Approve for integration" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-approved="attempt-a"]'));
};

const replay: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Reconnect and replay" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-connection="live"]'));
};

const props: RunBoardProps = { snapshot: runBoardFixture, recovered: replayedBoardFixture };

export default componentEntry<RunBoardProps>({
  id: "agent-pane.run-board",
  title: "Run board · independent UI exploration",
  area: "Agent pane",
  height: 1010,
  widths: { narrow: 560, normal: 1200, wide: 1480 },
  covers: ["agent-session/acpmux/run-board/RunBoard.tsx#RunBoard"],
  styles: () => import("./styles.css"),
  load: async () => (await import("./RunBoard")).RunBoard,
  variants: {
    working: {
      note: "Four independent workspaces share one immutable intent. Evidence and human approval stay per attempt.",
      props,
    },
    disconnected: {
      note: "The saved board remains readable. Reconnect replays owner events without restarting the workers.",
      props: { ...props, disconnected: true },
    },
    replayed: {
      note: "One worker finished while disconnected; replay recovers its evidence and keeps the selected workspace.",
      props: { ...props, disconnected: true },
      play: replay,
    },
    approved: {
      note: "A human checks the evidence before creating an integration intent. This gallery prototype performs no server mutation.",
      props,
      play: approve,
    },
  },
});
