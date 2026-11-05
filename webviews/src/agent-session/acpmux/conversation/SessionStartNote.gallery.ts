// l10n-allow-file: gallery fixtures (sample prompts, versions, models and paths), not shipped UI.
// Where a Claude Code chat's model or route changed (SessionStartNote.tsx): what it runs on now in
// one short line; a click opens the whole of it. A chat on one model and route draws no line at all
// (Leo, 2026-11-05: "why does it even show that ... like we know what it is ... giving tmi"); its
// facts are Session Info's agent row.
import type { PlayContext } from "../../../gallery/play";
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

const start = (harness: string, model = "claude-opus-5-5") => ({
  sessionStart: {
    agent: "claude" as const,
    version: "2.1.312",
    model,
    harness,
    cwd: "/Users/lawrence/fun/cmux",
  },
});

/// Three turns on Opus 5.5, as direct.ts draws them now: no line over any reply.
const sameModel = () =>
  chat([
    user("Fix the flaky sidebar test", 9),
    assistant("Looking at the sidebar test first.", 8),
    summary(8, { status: "completed", durationMs: 9_000, toolCount: 1 }),
    user("Now the drag test", 6),
    assistant("The drag test waits on a frame it never gets.", 5),
    summary(5, { status: "completed", durationMs: 7_000, toolCount: 1 }),
    user("Ship it", 3),
    assistant("Opened the PR.", 2),
    summary(2, { status: "completed", durationMs: 4_000, toolCount: 1 }),
  ]);

/// The second turn ran on Sonnet 5.5: one line there, none on the turns around it.
const modelSwitch = () =>
  chat([
    user("Fix the flaky sidebar test", 9),
    assistant("Looking at the sidebar test first.", 8),
    summary(8, { status: "completed", durationMs: 9_000, toolCount: 1 }),
    user("Use Sonnet for the rename", 6),
    row("sessionStart", 6, start("claude", "claude-sonnet-5-5")),
    assistant("Renamed 14 call sites.", 5),
    summary(5, { status: "completed", durationMs: 7_000, toolCount: 1 }),
    user("Thanks, back to Opus", 3),
    row("sessionStart", 3, start("claude")),
    assistant("Back on the sidebar test.", 2),
    summary(2, { status: "completed", durationMs: 4_000, toolCount: 1 }),
  ]);

/// The chat moved from the person's own setup onto sr2: the line names the route.
const routeSwitch = () =>
  chat([
    user("Summarize the open PRs", 6),
    assistant("Here are the open PRs.", 5),
    summary(5, { status: "completed", durationMs: 6_000, toolCount: 1 }),
    user("Keep going", 3),
    row("sessionStart", 3, start("claude-sr2")),
    assistant("Two more need a rebase.", 2),
    summary(2, { status: "completed", durationMs: 5_000, toolCount: 1 }),
  ]);

/// Hovers the first change line and waits for its facts tooltip.
const hoverLine = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-session-start"));
  await ctx.hover({ selector: ".cv-session-start" });
  await ctx.waitFor(() =>
    /2\.1\.312/.test(ctx.document.querySelector(".ui-title-tooltip:not([hidden])")?.textContent ?? ""),
  );
};

export default agentPaneEntry({
  id: "agent-pane.session-start-note",
  title: "Model or route change line",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/SessionStartNote.tsx"],
  variants: {
    "same-model": {
      note: "Shipped. Three turns on one model and route: no harness or model line over any reply. Session Info's Environment says what it runs on.",
      snapshot: sameModel(),
    },
    "model-switch": {
      note: 'Shipped. One line where a turn ran on another model ("Claude Code · Sonnet 5.5"), and one where it came back; the turns between draw none.',
      snapshot: modelSwitch(),
    },
    "route-switch": {
      note: 'Shipped. The chat moved onto sr2: "Claude Code · Opus 5.5 · sr2" on that turn only.',
      snapshot: routeSwitch(),
    },
    details: {
      note: "A click on the line opens the whole of it: Claude Code's version, the model id, the route and the folder.",
      snapshot: modelSwitch(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-session-start" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-session-start__detail"));
      },
    },
    hover: {
      note: "The hover preview anchors at the line's words, not the middle of the pane-wide row, and stays inside the transcript.",
      snapshot: modelSwitch(),
      play: hoverLine,
    },
  },
});
