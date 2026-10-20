// l10n-allow-file: gallery fixtures (sample prompts, replies and todo items), not shipped UI.
// The agent's todo list (PlanList.tsx, cx-ncc.80): Claude's TodoWrite or Codex's plan draws as a
// quiet card, outside a finished turn's "Worked for" fold, and live while the
// turn runs.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxPlanEntry } from "../model";

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });

export default agentPaneEntry({
  id: "agent-pane.plan-list",
  title: "Todo list",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/PlanList.tsx"],
  variants: {
    running: {
      note: "A turn under way: one item done (filled check), one in progress (spinner), one waiting (dashed circle).",
      snapshot: chat([
        user("Add retry to the uploader, cover it and update the docs", 3),
        row("plan", 2, {
          plan: [
            todo("Add retry to the uploader", "completed"),
            todo("Cover it with a test", "in_progress"),
            todo("Update the docs", "pending"),
          ],
        }),
      ]),
    },
    finished: {
      note: "A finished turn keeps its list beside the fold, all done.",
      snapshot: chat([
        user("Add retry to the uploader, cover it and update the docs", 6),
        row("plan", 5, {
          plan: [
            todo("Add retry to the uploader", "completed"),
            todo("Cover it with a test", "completed"),
            todo("Update the docs", "completed"),
          ],
        }),
        assistant("All three done: retry backs off from 200 ms, one test covers it, and the README says so.", 4),
        summary(4, { status: "completed", durationMs: 64_000, toolCount: 6 }),
      ]),
    },
  },
});
