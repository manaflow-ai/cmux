// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Retry, with its model switch, on the last turn's reply footer (TurnRows.tsx TurnFooter). Leo,
// 2026-11-04: "Retry on the reply (small to medium). Today Retry is on your prompt bubble, and appears
// on the reply only after a failure. Put it, with the model switch, in the last turn's footer." and
// "yeah but the big point is ofc the styling and theming and spacing too". Retry and its chevron are
// one split control right after Copy, Claude's and ChatGPT's place for it; an earlier turn's footer
// and every prompt bubble draw none. A failed last turn keeps its card (#34588) and the same control.
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
      note: "The last reply's footer at rest: Copy, then Retry and its model chevron as one control, then Fork, Pin, Read aloud and More. The earlier turn's footer and both prompts have no Retry.",
      snapshot: chat(twoTurns()),
    },
    "model-menu": {
      note: "The chevron opens the model menu; Retry's pill stays lit while it is open.",
      snapshot: chat(twoTurns()),
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
