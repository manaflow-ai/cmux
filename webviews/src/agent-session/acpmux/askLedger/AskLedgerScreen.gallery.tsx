// l10n-allow-file: gallery fixtures, not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AskLedgerScreen } from "./AskLedgerScreen";

type Props = ComponentProps<typeof AskLedgerScreen>;

export default componentEntry<Props>({
  id: "agent-pane.ask-ledger",
  title: "Your asks",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/askLedger/AskLedgerScreen.tsx#AskLedgerScreen"],
  styles: () => import("../styles.css"),
  load: () => import("./AskLedgerScreen").then((module) => module.AskLedgerScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 520,
  variants: {
    recent: {
      note: "Accepted prompts from two harnesses, with their source and time.",
      props: {
        load: async () => ({
          entries: [
            {
              id: "ask-one",
              text: "Review the upload retry behavior.",
              createdAt: 1795132800000,
              sessionId: "review",
              harness: "claude",
              host: "My Mac",
              truncated: false,
            },
            {
              id: "ask-two",
              text: "Keep the experimental feature off by default.\nLet me try it from History.",
              createdAt: 1795132700000,
              sessionId: "implementation",
              harness: "codex",
              host: "My Mac",
              truncated: false,
            },
          ],
        }),
      },
    },
    empty: {
      note: "No accepted asks since this daemon started; no fabricated history.",
      props: { load: async () => ({ entries: [] }) },
    },
    unavailable: {
      note: "An older daemon or failed read is a visible error, never an empty ledger.",
      props: {
        load: async () => {
          throw new Error("method not found");
        },
      },
    },
  },
});
