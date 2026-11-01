// l10n-allow-file: gallery fixtures (prompts, subagent names, tool calls, documents), not shipped UI.
// The Background tasks panel (BackgroundTasksPanel.tsx, backgroundTasks.ts), Claude Desktop's panel of
// the same name (Leo, 2026-10-29: "i like these tasks i like the order that things split on the right
// i want that in cmux next"). The chat's ⋯ menu opens it in the chat's right column, docked under the
// side panel when one is open: one block per agent, its time and stop button, "N tasks, M failed",
// its running tasks with their own stop buttons, then "N finished". A click on an agent or a task
// opens its transcript in place, from the snapshot, with nothing to wait for (Leo: "i also like the
// way it just loads in the subagent stuff instantly :(").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { backgroundTasksLook } from "./backgroundTasksLook.experiment";

const fence = (lang: string, code: string) => "```" + lang + "\n" + code + "\n```";

const ledger = `# Leo's asks

275 of his messages since Oct 18, rolled up into asks, decisions and standing orders.

| Open | In progress | Landed | Dropped |
| --- | --- | --- | --- |
| 85 | 109 | 64 | 1 |`;

const agent = (id: string, task: string, minutes: number, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: task,
  task,
  kind: "general-purpose",
  state: "running",
  startedAt: minutesAgo(minutes),
  background: true,
  ...fields,
});

/// A finished tool call that started `minutes` ago and ran `seconds`.
const done = (title: string, minutes: number, seconds: number, status = "completed") =>
  tool(title, "execute", status, {
    description: title,
    startedAt: minutesAgo(minutes),
    endedAt: minutesAgo(minutes) + seconds * 1000,
    output: status === "failed" ? "error: exit status 1" : "ok",
  });
const running = (title: string, minutes: number) =>
  tool(title, "execute", "in_progress", { description: title, startedAt: minutesAgo(minutes) });

const ATTRIBUTION = agent("agent-attribution", "Attachment source attribution badge", 49.2);
const WORKSPACE = agent("agent-workspace", "Workspace link + copy menus", 49.4);
const AUDIT = agent("agent-audit", "Audit the composer menus for fade-in", 31, {
  state: "completed",
  endedAt: minutesAgo(12),
});

const FINISHED_STEPS: [string, number][] = [
  ["Read composer img rule and CSS imports", 5],
  ["Compile-check the app at PR1 head on the fleet", 159],
  ["Read an xcstrings entry and i18n loader", 3],
  ["Start an independent Codex review of PR1", 15],
  ["Open PR1", 4],
  ["Push PR1 branch through the Git Data API", 53],
  ["Create draft branch from PR1 patch", 193],
  ["Check provider list context and other method lists", 11],
  ["Extract base copies of files to edit", 9],
  ["Stop my own stalled wt process", 4],
  ["Inspect SentImage, callHost and gallery discovery", 7],
];

/// The attribution agent's own transcript: replies, thoughts, tool calls; one still running.
const attributionView = (): AcpmuxRow[] => [
  user("Add a source attribution badge to sent attachments", 49.2, { id: "attr-ask" }),
  ...FINISHED_STEPS.map(([title, seconds], index) =>
    activity(
      [
        thought(`Checking ${title.toLowerCase()} before the next edit.`),
        done(title, 48 - index * 3.5, seconds, index === 2 || index === 6 ? "failed" : "completed"),
      ],
      48 - index * 3.5,
      { id: `attr-step-${index}` },
    ),
  ),
  assistant("The scratch repo holds only edited files; I read the rest from the mirror.", 6, { id: "attr-note" }),
  activity([running("Start the Codex review detached", 5.15)], 5.15, { id: "attr-review" }),
];

const workspaceView = (): AcpmuxRow[] => [
  user("Workspace link + copy menus", 49.4, { id: "ws-ask" }),
  ...Array.from({ length: 36 }, (_, index) =>
    activity(
      [done(`Step ${index + 1} of the copy menus`, 48 - index, 6 + index, index % 12 === 3 ? "failed" : "completed")],
      48 - index,
      {
        id: `ws-step-${index}`,
      },
    ),
  ),
  activity([running("Run the menu gallery on Linux", 2), running("Read the menu tokens", 1)], 2, { id: "ws-live" }),
];

const auditView = (): AcpmuxRow[] => [
  user("Audit the composer menus for fade-in", 31, { id: "audit-ask" }),
  activity([done("Grep menu transitions", 30, 4), done("Read composer.css", 29, 3)], 30, { id: "audit-steps" }),
  assistant("No menu fades in on open; two fade out on close, which the rulebook allows.", 12, { id: "audit-answer" }),
];

const snapshot = (withDocument: boolean) =>
  chat(
    [
      user("Ship the attachment badge and the copy menus, and audit the menus", 50),
      row(SUBAGENTS, 49.4, { id: "bg-group", subagents: [WORKSPACE, ATTRIBUTION, AUDIT] }),
      assistant(
        withDocument
          ? `Three agents are on it. The ledger so far:\n\n${fence("markdown", ledger)}`
          : "Three agents are on it; I'll report when each is back.",
        49,
      ),
      summary(49, { status: "completed", durationMs: 40_000 }),
    ],
    {
      title: "Leo's asks ledger",
      subagentViews: {
        [ATTRIBUTION.id]: attributionView(),
        [WORKSPACE.id]: workspaceView(),
        [AUDIT.id]: auditView(),
      },
    },
  );

const openPanel = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.click({ role: "menuitem", name: "Background tasks" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-bg"));
};
const openDocument = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Open preview" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-artifact"));
};
const docked = async (ctx: PlayContext) => {
  await openDocument(ctx);
  await openPanel(ctx);
  const side = ctx.document.querySelector(".acpmux-artifact")!.getBoundingClientRect();
  const panel = ctx.document.querySelector(".acpmux-bg")!.getBoundingClientRect();
  if (panel.top < side.bottom - 1) throw new Error("the panel docks under the side panel, never over it");
  if (Math.abs(panel.left - side.left) > 1) throw new Error("the panel shares the side panel's column");
};
const drill = async (ctx: PlayContext) => {
  await openPanel(ctx);
  const started = performance.now();
  // The panel's own agent line (the tray above the composer names the same agent).
  await ctx.click({ selector: `.acpmux-bg__group[data-group="agent:${ATTRIBUTION.id}"] .acpmux-bg__name` });
  // The transcript draws from the snapshot, with nothing to wait on the daemon for: it is on the
  // page once React commits the click (the drill perf test holds it inside one frame).
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-bg__transcript [data-row-id]"), { capMs: 250 });
  if (!ctx.document.querySelector(".acpmux-bg__transcript [data-row-id]"))
    throw new Error("the transcript draws on the click, from the snapshot");
  ctx.document.documentElement.dataset.bgDrillMs = String(Math.round((performance.now() - started) * 10) / 10);
};
const finishedOpen = async (ctx: PlayContext) => {
  await openPanel(ctx);
  await ctx.click({ role: "button", name: /finished/ });
};

export default agentPaneEntry({
  id: "agent-pane.background-tasks",
  title: "Background tasks panel",
  area: "Agent pane",
  height: 760,
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx",
    "agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx",
    "agent-session/acpmux/backgroundTasks/backgroundTasks.ts",
  ],
  experiment: {
    definition: backgroundTasksLook,
    script: [
      { name: "open", run: openPanel },
      { name: "finished", run: async (ctx) => ctx.click({ role: "button", name: /finished/ }) },
    ],
  },
  variants: {
    closed: {
      note: "Before it opens: the tray above the composer, opened from its folded header, lists the running agents; the chat's ⋯ menu has Background tasks.",
      snapshot: snapshot(false),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
        // A headed tray starts folded (cmux#28875): open it, as the person does.
        if (ctx.document.querySelector('.acpmux-running-tray__head[aria-expanded="false"]'))
          await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list .acpmux-agent-line"));
      },
    },
    docked: {
      note: "Docked under the side panel in the right column, the chat on the left: two agents running with their counts (one with failures in red), one that ended.",
      snapshot: snapshot(true),
      play: docked,
    },
    alone: {
      note: "No side panel open: the panel is the chat's right column. The first running agent opens on its running task, then 11 finished, folded.",
      snapshot: snapshot(false),
      play: openPanel,
    },
    finished: {
      note: "The finished tasks open, the latest first, each with how long it took; failures in red; Show more past eight.",
      snapshot: snapshot(false),
      play: finishedOpen,
    },
    transcript: {
      note: "A click on an agent opens its transcript in place on the same frame, with back, expand and close; the spinner under it while it runs.",
      snapshot: snapshot(true),
      play: async (ctx) => {
        await openDocument(ctx);
        await drill(ctx);
      },
    },
  },
});
