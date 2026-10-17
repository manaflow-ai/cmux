// l10n-allow-file: gallery fixtures (Run board prototype), not shipped UI.
import { componentEntry } from "../../../../../gallery/format";
import type { Play } from "../../../../../gallery/play";
import { replayedBoardFixture, runBoardFixture } from "../../fixtures";
import type { OpsConsoleProps } from "./OpsConsole";

const props: OpsConsoleProps = {
  snapshot: runBoardFixture,
  recovered: replayedBoardFixture,
  onAttach: async (intent) => ({
    ...intent,
    ticket: `fixture-ticket-${intent.attemptId}`,
  }),
  onAttachTicket: async () => {},
  onApprove: async () => {},
};

/**
 * Capture receipt: start disconnected, recover the durable cursor, select B,
 * attach its worker terminal, then pass the evidence gate and approve it.
 */
const recoveryAndApproval: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Attempt B/ });
  await ctx.click({ role: "button", name: "Reconnect and replay" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-connection="live"]'));
  await ctx.click({ role: "button", name: "Attach worker terminal" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-attach-state="attached"]'));
  await ctx.click({ role: "checkbox", name: "I reviewed this attempt" });
  await ctx.click({ role: "button", name: "Approve candidate" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-approved="attempt-b"]'));
};

export default componentEntry<OpsConsoleProps>({
  id: "agent-pane.run-board-ops-console",
  title: "Run board · operations console",
  area: "Agent pane",
  height: 1010,
  widths: { narrow: 580, normal: 1200, wide: 1480 },
  covers: ["agent-session/acpmux/run-board/variants/ops-console/OpsConsole.tsx#OpsConsole"],
  styles: () => import("./styles.css"),
  load: async () => (await import("./OpsConsole")).OpsConsole,
  variants: {
    working: {
      note: "Dense split pane for comparing workers, durable activity, evidence receipts, and the human gate.",
      props,
    },
    disconnected: {
      note: "The rail stays inspectable through a disconnect; replay recovers the owner cursor without restarting workers.",
      props: { ...props, disconnected: true },
    },
    "recovery-attach-approve": {
      note: "Capture receipt: select an attempt → reconnect and replay → attach its terminal → approve the evidence-backed candidate.",
      props: { ...props, disconnected: true },
      play: recoveryAndApproval,
    },
  },
});
