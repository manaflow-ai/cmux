// l10n-allow-file: gallery fixtures (sample prompts, replies and todo items), not shipped UI.
// The agent's todo list (PlanList.tsx, cx-ncc.80): Claude's TodoWrite or Codex's plan draws as a
// checklist under its progress, outside a finished turn's "Worked for" fold, and live while the
// turn runs.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxPlanEntry } from "../model";

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });

export default agentPaneEntry({
  id: "agent-pane.plan-list",
  title: "Todo list",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/PlanList.tsx", "agent-session/acpmux/conversation/ActivityLine.tsx"],
  variants: {
    running: {
      note: "A turn under way: one item done, one in progress (bold), one waiting.",
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
    "status-card": {
      note: "In-session status (Debug Settings agent.sessionStatus, cx-ncc.102): the live list as a quiet card under the work, and the activity line under it naming the running edit and the turn's time.",
      sessionStatus: true,
      snapshot: chat(
        [
          user("Fix the layout shift on the product grid", 26 / 60),
          assistant(
            "The grid shifts because product images load without a width and height. I'll add dimensions in ProductCard, then reserve space in the grid with an aspect-ratio fallback.",
            25 / 60,
          ),
          row("plan", 24 / 60, {
            plan: [
              todo("Reproduce the shift, run baseline tests", "completed"),
              todo("Add image dimensions to ProductCard", "completed"),
              todo("Reserve space with an aspect-ratio fallback", "in_progress"),
              todo("Check the product grid in the preview", "pending"),
              todo("Add a layout shift test, final run", "pending"),
            ],
          }),
          activity([tool("Edit ProductGrid.module.css", "edit", "in_progress")], 2 / 60),
        ],
        { isWorking: true },
      ),
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
