// l10n-allow-file: gallery fixtures (sample prompts, replies and todo items), not shipped UI.
// The agent's todo list (PlanList.tsx, cx-ncc.80): Claude's TodoWrite or Codex's plan draws as a
// quiet card, pinned under the latest message while the turn runs (Leo, 2026-11-03, on Claude Code
// desktop's task list), and folded, where it stood, to its "3 of 3 tasks done" line once the turn
// ends. With Debug Settings agent.sessionStatus on, the activity line under it names what
// the agent is doing now (ActivityLine.tsx, cx-ncc.102).
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
    pinned: {
      note: "A running Claude turn: the list came first, the agent's messages and calls since then draw over it, and it stays pinned under the latest message with the live line under it.",
      snapshot: chat(
        [
          user("Fix the layout shift on the product grid", 3),
          row("plan", 2.9, {
            plan: [
              todo("Reproduce the shift, run baseline tests", "completed"),
              todo("Add image dimensions to ProductCard", "completed"),
              todo("Reserve space with an aspect-ratio fallback", "in_progress"),
              todo("Check the product grid in the preview", "pending"),
            ],
          }),
          activity(
            [
              tool("Read src/components/ProductCard.tsx", "read", "completed"),
              tool("Edit src/components/ProductCard.tsx", "edit", "completed", {
                locations: [{ path: "src/components/ProductCard.tsx" }],
              }),
            ],
            2.5,
          ),
          assistant(
            "ProductCard now sets width and height on its image. Next I'll reserve the grid's space with an aspect-ratio fallback.",
            1.5,
          ),
          activity([tool("Read src/components/ProductGrid.module.css", "read", "completed")], 1),
          activity(
            [
              tool("Edit src/components/ProductGrid.module.css", "edit", "in_progress", {
                locations: [{ path: "src/components/ProductGrid.module.css" }],
              }),
            ],
            0.2,
          ),
        ],
        { isWorking: true },
      ),
    },
    "pinned-codex": {
      note: "A running Codex turn with its update_plan list: the same pinned card under the latest message, the live line under it.",
      snapshot: chat(
        [
          user("Add retry to the uploader, cover it and update the docs", 2),
          row("plan", 1.9, {
            plan: [
              todo("Add retry to the uploader", "completed"),
              todo("Cover it with a test", "in_progress"),
              todo("Update the docs", "pending"),
            ],
          }),
          assistant("Retry is in: three attempts, backing off from 200 ms. Writing the test now.", 0.8),
          activity([tool("Run bun test uploader", "execute", "in_progress", { command: "bun test uploader" })], 0.1),
        ],
        { isWorking: true, harness: "codex", model: "gpt-6.1-sol" },
      ),
    },
    "finished-folded": {
      note: "Shipped: the turn ended, and its list folded where it stood to its one line, under the answer; the chevron opens the steps again.",
      snapshot: chat([
        user("Fix the layout shift on the product grid", 6),
        row("plan", 5.9, {
          plan: [
            todo("Reproduce the shift, run baseline tests", "completed"),
            todo("Add image dimensions to ProductCard", "completed"),
            todo("Reserve space with an aspect-ratio fallback", "completed"),
            todo("Check the product grid in the preview", "completed"),
          ],
        }),
        activity([tool("Edit src/components/ProductCard.tsx", "edit", "completed")], 5),
        assistant("Fixed: images carry their size, and the grid reserves the space with an aspect-ratio fallback.", 4),
        summary(4, { status: "completed", durationMs: 118_000, toolCount: 6 }),
      ]),
    },
    "finished-stopped": {
      note: "A turn stopped midway: its folded line counts what got done, the ring says the rest did not.",
      snapshot: chat([
        user("Add retry to the uploader, cover it and update the docs", 6),
        row("plan", 5.9, {
          plan: [
            todo("Add retry to the uploader", "completed"),
            todo("Cover it with a test", "in_progress"),
            todo("Update the docs", "pending"),
          ],
        }),
        assistant("Retry is in. Stopped before the test.", 5),
        summary(5, { status: "cancelled", durationMs: 41_000, toolCount: 3 }),
      ]),
    },
    "activity-line": {
      note: "Debug Settings agent.sessionStatus on: the list sits under the work, and the line under it names the running edit by its file name and ticks the turn's time, in Working for's place, with no blinking dots before it.",
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
            ],
          }),
          activity(
            [
              tool("Edit src/components/ProductGrid.module.css", "edit", "in_progress", {
                locations: [{ path: "src/components/ProductGrid.module.css" }],
              }),
            ],
            2 / 60,
          ),
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
