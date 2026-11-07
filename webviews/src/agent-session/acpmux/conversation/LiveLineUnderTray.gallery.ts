// l10n-allow-file: gallery fixtures (prompts, commands, replies), not shipped UI.
// A new turn under a background command an earlier turn left running in the tray (Leo, 2026-11-04,
// on a turn under a running background command's card: "why does it not display Thinking or
// anything here???", then "it appears and disappears????"). The running turn's live line is its
// last row from the send to the reply (conversation/turns.ts), at every phase, and it stands in
// sight over the bottom stack, never under the tray (App.tsx `room`).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

const devServer = "cd ~/Projects/app && bun run dev";
const watcher = "cd ~/Projects/app && bun run watch:css";
/// A call that started `command` in the background, which runs on.
const inBackground = (command: string, description: string) =>
  tool(command, "execute", "completed", {
    command,
    inputSummary: JSON.stringify({ command, description, run_in_background: true }),
    startedAt: minutesAgo(63),
  });
const earlier: AcpmuxRow[] = [
  user("Start the dev server and keep it running", 64),
  // Two commands, so the tray has its header, which opens and folds its list.
  activity([inBackground(devServer, "Run the dev server"), inBackground(watcher, "Watch the styles")], 63),
  assistant("The dev server runs in the background.", 63),
  summary(63, { status: "completed", durationMs: 40_000, toolCount: 1 }),
];
const prompt = user("Why has this taken so long?", 0.1);
const log = (status: string) =>
  tool("git log --oneline -5", "execute", status, {
    command: "git log --oneline -5",
    startedAt: minutesAgo(0.05),
    ...(status === "completed" && { output: "abc123 fix the fold\n", exitCode: 0 }),
  });

const phase = (rows: AcpmuxRow[]) => chat([...earlier, prompt, ...rows], { isWorking: true });

/// The live line drawn, with its words, and in sight over the stack: its box above the tray's top.
const lineInSight = async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const line = ctx.document.querySelector(".acpmux-row--below .cv-worked--live:not(.is-quiet)");
    const tray = ctx.document.querySelector(".acpmux-running-tray");
    if (!line || !tray) return false;
    return line.getBoundingClientRect().bottom <= tray.getBoundingClientRect().top + 0.5;
  });
};
const trayOpened = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await lineInSight(ctx);
};

export default agentPaneEntry({
  id: "agent-pane.live-line-under-tray",
  title: "Live line under a running background command",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/App.tsx"],
  variants: {
    thinking: {
      note: "Sent, nothing out yet: Thinking under the prompt, over the tray.",
      play: lineInSight,
      snapshot: phase([]),
    },
    "thought-streaming": {
      note: "A thought streams: the line stays, the last row.",
      play: lineInSight,
      snapshot: phase([activity([thought("Looking at what ran")], 0.08)]),
    },
    "call-running": {
      note: "A call runs: the line names it.",
      play: lineInSight,
      snapshot: phase([activity([thought("Looking at what ran"), log("in_progress")], 0.06)]),
    },
    "thinking-again": {
      note: "The call is done and the agent thinks again: the line keeps going.",
      play: lineInSight,
      snapshot: phase([activity([thought("Looking at what ran"), log("completed"), thought("Now the reasons")], 0.05)]),
    },
    "tray-open": {
      note: "The reader opens the tray while the turn runs: the room under the line takes it, so the line stands over it.",
      play: trayOpened,
      snapshot: phase([]),
    },
  },
});
