// l10n-allow-file: gallery fixtures (sample prompts, replies and todo items), not shipped UI.
// The agent's todo list (PlanList.tsx, cx-ncc.80): Claude's TodoWrite or Codex's plan draws as a
// quiet card. While the turn runs it is in the hat over the composer, "2 of 4 · <the step at work>",
// whose chevron opens the checklist (subagents/SubagentTray.tsx `plan`; Leo, 2026-11-03: "we said
// earlier the composer hat is kinda ok?"); Settings > Agent Chat > Pin Task List in Chat pins it under
// the latest message instead (`pinned-setting`). Once the turn ends it folds, where it stood, to its
// "3 of 3 tasks done" line. With Debug Settings agent.sessionStatus on, the activity line under it names what
// the agent is doing now (ActivityLine.tsx, cx-ncc.102). A new prompt whose turn has no list of its
// own yet keeps the earlier list with steps left in sight, "From before your last message", as Claude
// desktop does (`earlier-*`; turns.ts earlierTurnPlan; Leo, 2026-11-05: "i like these plans too...").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxPlanEntry } from "../model";

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });

/// A turn stopped with steps left, then the person's next message, whose turn runs with no list yet.
const earlierTurn = (extra: ReturnType<typeof row>[] = []) =>
  chat(
    [
      user("Add retry to the uploader, cover it and update the docs", 8),
      row("plan", 7.9, {
        plan: [
          todo("Add retry to the uploader", "completed"),
          todo("Cover it with a test", "in_progress"),
          todo("Update the docs", "pending"),
        ],
      }),
      assistant("Retry is in. Stopped before the test.", 7),
      summary(7, { status: "cancelled", durationMs: 41_000, toolCount: 3 }),
      user("Use 250 ms for the first backoff, then carry on", 0.4),
      assistant("Switching the first backoff to 250 ms.", 0.2),
      ...extra,
    ],
    { isWorking: true },
  );

export default agentPaneEntry({
  id: "agent-pane.plan-list",
  title: "Todo list",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/PlanList.tsx",
    "agent-session/acpmux/conversation/ActivityLine.tsx",
    "agent-session/acpmux/subagents/SubagentTray.tsx",
  ],
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
      note: 'A running Claude turn with its list, by default: the hat over the composer reads "2 of 4 · Reserve space with an aspect-ratio fallback" and the transcript holds no list; the hat\'s chevron opens the checklist.',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        if (title !== "2 of 4 · Reserve space with an aspect-ratio fallback")
          throw new Error(`unexpected hat: ${title}`);
        if (ctx.document.querySelector(".cv-plan:not(.acpmux-running-tray .cv-plan)"))
          throw new Error("the running list is in the hat, not the transcript");
      },
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
    "hat-open": {
      note: "The hat's chevron opened: the checklist over the composer, its marks in the lines' icon column.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .cv-plan__item").length === 3);
      },
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
        ],
        { isWorking: true },
      ),
    },
    "earlier-hat": {
      note: 'The person wrote again after a turn stopped with steps left, and the new turn has no list yet: the hat keeps the earlier one, "Earlier plan · 1 of 3", naming no step at work.',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        if (title !== "Earlier plan · 1 of 3") throw new Error(`unexpected hat: ${title}`);
      },
      snapshot: earlierTurn(),
    },
    "earlier-hat-open": {
      note: 'The hat opened on the earlier list: its line says "From before your last message", the steps read muted and nothing spins.',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .cv-plan[data-earlier]"));
        if (ctx.document.querySelector(".acpmux-running-tray .cv-plan .cv-spinner__arc"))
          throw new Error("an earlier list never spins");
      },
      snapshot: earlierTurn(),
    },
    "earlier-pinned": {
      note: "Pin Task List in Chat on: the earlier list pins under the running turn's latest message, over the live line, marked as from before the last message; its own turn keeps its folded line.",
      display: { "agentPane.display.pinnedPlan": true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-plan[data-earlier]"));
        if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("no hat: the list is pinned");
      },
      snapshot: earlierTurn(),
    },
    "earlier-replaced": {
      note: "The new turn wrote its own list: only that one shows, as the running turn's, and the earlier one stays folded in its turn.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        if (title !== "0 of 2 · Change the first backoff to 250 ms") throw new Error(`unexpected hat: ${title}`);
      },
      snapshot: earlierTurn([
        row("plan", 0.1, {
          plan: [todo("Change the first backoff to 250 ms", "in_progress"), todo("Cover it with a test", "pending")],
        }),
      ]),
    },
    "pinned-setting": {
      note: "Settings > Agent Chat > Pin Task List in Chat on: the list is pinned under the latest message with the live line under it, and the hat shows no plan.",
      display: { "agentPane.display.pinnedPlan": true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-plan"));
        if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("no hat: the list is pinned");
      },
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
        ],
        { isWorking: true },
      ),
    },
    "hat-tuck-chevron": {
      note: 'The hat under the pointer: its chevron at the top middle tucks it away (Leo, 2026-11-04: "what if you wanted to collapse that one line?").',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__tuck"));
        // A click on the header's middle opens the hat: the chevron takes only the hat's top band.
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .cv-plan__item").length === 3);
        // The pointer over the hat shows its chevron.
        await ctx.hover({ selector: ".acpmux-running-tray__head" });
      },
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
        ],
        { isWorking: true },
      ),
    },
    "hat-tucked": {
      note: "Settings > Agent Chat > Tuck Away Running Tray on (or the hat's chevron clicked): only a faint up chevron at the composer's top middle, in the accent while work runs; hovered, it brightens on a small pill and brings the hat back.",
      display: { "agentPane.display.trayTucked": true },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-tray-pull__tab"));
        if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("no hat: it is tucked away");
      },
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
        ],
        { isWorking: true },
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
      display: { "agentPane.display.pinnedPlan": true },
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
