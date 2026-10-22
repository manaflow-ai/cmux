// l10n-allow-file: gallery fixtures (prompts, subagent names, commands, chat titles), not shipped UI.
// Running subagents, background commands and chats the agent started in one tray at the foot of
// the chat, right above the composer (SubagentTray.tsx, runningTray.ts), never in the middle of
// history, in a turn and after it ("Running in background · …"): one running is its line alone;
// several get a header ("3 subagents running · 1 command") with a line each; past three they start
// folded to the header. The transcript has no "Running in background" row. A subagent that ended leaves one line where it ended
// (SubagentDoneLine.tsx), a failure in the danger color. The tray's lines are the summary card's
// Subagents rows (AgentLine.tsx). The group card and the agents pill this replaces are
// subagents.gallery.ts, under Debug Settings agentPane.debug.subagentTray off.
import { agentPaneEntry } from "../../../gallery/format";
import {
  activity,
  assistant,
  chat,
  row,
  session,
  SESSION_ID,
  summary,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const prompt = "Find out how the daemon updates itself, and check the docs agree";

/** A subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.3, ...rest } = fields;
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(minutes - ran) }),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

/** A Bash call Claude runs in the background, still running. */
const devServer = activity(
  [
    tool("bun run dev", "execute", "completed", {
      inputSummary: JSON.stringify({ command: "bun run dev", run_in_background: true }),
      startedAt: minutesAgo(1.5),
    }),
  ],
  1.5,
);

/** Waits for the tray's `count` lines, and checks no group card is left in the transcript. */
const trayLines = (count: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === count);
  if (ctx.document.querySelector(".cv-subagents"))
    throw new Error("a running subagent must not draw a transcript card");
  if (ctx.document.querySelector(".acpmux-agents-pill"))
    throw new Error("the tray is the agents chip; no pill beside it");
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray",
  title: "Running subagents tray",
  area: "Agent pane",
  height: 520,
  // The header and the composer stay put while the tray opens or folds.
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
  ],
  variants: {
    "one-running": {
      note: "One subagent running: its line alone above the composer, its icon in the theme's accent, what it does now, its time and state.",
      play: trayLines(1),
      snapshot: chat(
        [
          user(prompt, 2),
          group([agent("Explain daemon update mechanism", 1.8, "running", { kind: "Explore", action: "Bash" })], 1.8),
          assistant("A subagent is reading the update code now; I'll report back when it is done.", 1.7),
        ],
        { isWorking: true },
      ),
    },
    "several-running": {
      note: "Two subagents and a background command: a header with the counts and the time since the first started, a line each (up to three show open). The one that ended left its line in the transcript.",
      play: trayLines(3),
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            [
              agent("Read the updater", 1.9, "running", { kind: "Explore", action: "Read Sources/Updater.swift" }),
              agent("Check the docs", 1.9, "running", { kind: "general-purpose", action: "Read docs/updates.md" }),
              agent("Find the release script", 1.9, "completed", { kind: "Explore", ran: 0.6 }),
            ],
            1.9,
          ),
          devServer,
          assistant("Two subagents are on it, and the dev server is up.", 1.2),
        ],
        { isWorking: true },
      ),
    },
    "command-and-subagent": {
      note: "A turn with a subagent and a background command: a header with both counts, then a line each; the working line counts nothing, the tray is the count.",
      play: async (ctx) => {
        await trayLines(2)(ctx);
        if (ctx.document.querySelector(".cv-worked__open")) throw new Error("the tray is the count, not the line");
      },
      snapshot: chat(
        [
          user("Start the dev server, then have a subagent check the routes", 2),
          devServer,
          group([agent("Check the routes", 1.2, "running", { kind: "Explore", action: "Read src/routes.ts" })], 1.2),
        ],
        { isWorking: true },
      ),
    },
    "between-turns": {
      note: "After the turn: a background subagent and two chats the agent started still run. The tray says so above the composer; the transcript ends with the turn's footer.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 3);
        if (ctx.document.querySelector(".cv-bgwork")) throw new Error("no Running in background row in the transcript");
      },
      snapshot: (() => {
        const base = chat([
          user("Split the migration into two chats and keep an eye on the logs", 7),
          group([agent("Watch the logs", 6.5, "running", { kind: "general-purpose", background: true })], 6.5),
          assistant("Two chats are migrating the settings store and the history page; a subagent watches the logs.", 5),
          summary(5, { status: "completed", durationMs: 70_000, toolCount: 1 }),
        ]);
        return {
          ...base,
          sessions: [
            ...base.sessions,
            session({
              sessionId: "child-1",
              title: "Migrate the settings store to SQLite",
              spawnedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              createdAt: minutesAgo(5.5),
            }),
            session({
              sessionId: "child-2",
              title: "Port the history page to React Aria",
              spawnedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              createdAt: minutesAgo(5.4),
            }),
          ],
        };
      })(),
    },
    "many-folded": {
      note: "Five running: the tray starts folded to its header so it never takes the transcript's room; the chevron opens the list.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        if (ctx.find({ selector: ".acpmux-running-tray__head" }).getAttribute("aria-expanded") !== "false")
          throw new Error("more than three running lines start folded");
      },
      snapshot: chat(
        [
          user("Review each package for unused exports", 2),
          group(
            ["net", "ui", "store", "router", "i18n"].map((name, index) =>
              agent(`Package ${name}`, 1.9 - index * 0.1, "running", { action: `Read src/${name}/index.ts` }),
            ),
            1.9,
          ),
        ],
        { isWorking: true },
      ),
    },
    "finished-line": {
      note: "A finished turn: each subagent left one quiet line where it ended, with its name and how long it ran; no tray.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent-done").length === 2);
        if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("nothing runs: no tray");
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Explain daemon update mechanism", 11.8, "completed", { ran: 1.3 }),
            agent("Check the docs", 11.8, "completed", { ran: 2.1 }),
          ],
          11.8,
        ),
        assistant("The daemon updates itself on launch; the docs agree except for the channel name.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
    "failed-line": {
      note: "A subagent that failed says so in the danger color; one the person stopped says Stopped.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('.cv-subagent-done[data-state="failed"]'));
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Run the update tests", 11.8, "failed", { ran: 0.8 }),
            agent("Check the docs", 11.8, "cancelled", { ran: 1.6 }),
          ],
          11.8,
        ),
        assistant("The update tests failed to start; the docs check was stopped.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
  },
});
