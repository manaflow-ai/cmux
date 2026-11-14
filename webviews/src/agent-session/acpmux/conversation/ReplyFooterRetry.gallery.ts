// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Successful replies place Send prompt again and its model choices in More. Failed and stopped
// turns retain their inline recovery controls.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const twoTurns = (last: Parameters<typeof summary>[1] = {}) => [
  user("Add a retry with backoff to the fetch helper", 9),
  assistant("Added `withRetry` around `fetchJson`: three attempts, doubling from 200 ms.", 8.5),
  summary(8.4, { durationMs: 41_000 }),
  user("Cap the backoff at two seconds", 6),
  assistant("Capped it: the delay is now `Math.min(200 * 2 ** attempt, 2000)`.", 5.5),
  summary(5.4, { durationMs: 12_000, ...last }),
];

const openModels: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Retry with another model" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
};

export default agentPaneEntry({
  id: "agent-pane.reply-footer-retry",
  title: "Retry on the reply footer",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
    "agent-session/acpmux/conversation/RetryModelMenu.tsx",
  ],
  keywords: ["retry", "regenerate", "model", "switch model", "footer", "copy"],
  variants: {
    "last-turn": {
      note: "The successful reply footer keeps Copy, Fork, Pin, Read aloud and More. Send prompt again and its model choices are in More; no inline Retry split control.",
      snapshot: chat(twoTurns()),
    },
    "model-menu": {
      note: "A failed reply retains its inline recovery model menu; the successful reply uses More.",
      snapshot: chat(twoTurns({ status: "failed", error: "Overloaded" })),
      play: openModels,
    },
    failed: {
      note: "A failed last turn: its card leads with Retry (#34588), and the footer keeps the same Retry control.",
      snapshot: chat(twoTurns({ status: "failed", error: "Overloaded", durationMs: 3_000 })),
    },
    stopped: {
      note: "A stopped last turn: Retry beside Copy, Continue after the buttons.",
      snapshot: chat(twoTurns({ status: "cancelled", durationMs: 9_000 })),
    },
  },
});
