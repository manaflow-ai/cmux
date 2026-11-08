// l10n-allow-file: gallery fixtures (prompts, commands, replies), not shipped UI.
// Every phase of a running turn, under the background-tasks card an earlier turn left running, with
// and without messages the person sent mid-turn (Leo, 2026-11-04: "why does it not display Thinking
// or anything here???", "it appears and disappears????", "WHY DOES IT LOOK KLIKE YOU'RE NOT
// RESPONDING HERE???", "this is bad. it looks like you're not working."). The live line is the last
// row in each, from the send to the reply (conversation/turns.ts; test
// webviews/test/transcript-live-line-every-phase.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

const devServer = "cd ~/Projects/app && bun run dev";
const watcher = "cd ~/Projects/app && bun run watch:css";
const inBackground = (command: string, description: string) =>
  tool(command, "execute", "completed", {
    command,
    inputSummary: JSON.stringify({ command, description, run_in_background: true }),
    startedAt: minutesAgo(63),
  });
/// A turn that ended, with two commands it left running in the background: the tray's card.
const earlier: AcpmuxRow[] = [
  user("Start the dev server and keep it running", 64),
  activity([inBackground(devServer, "Run the dev server"), inBackground(watcher, "Watch the styles")], 63),
  assistant("The dev server runs in the background.", 63),
  summary(63, { status: "completed", durationMs: 40_000, toolCount: 2 }),
];
const prompt = user("Why has this taken so long?", 0.2);
const log = (status: string) =>
  tool("git log --oneline -5", "execute", status, {
    command: "git log --oneline -5",
    startedAt: minutesAgo(0.15),
    ...(status === "completed" && { output: "abc123 fix the fold\n", exitCode: 0 }),
  });
const forward = (status: string) =>
  tool("Forward the bug to the transcript lane", "execute", status, {
    command: "leo-forward --to transcript",
    description: "Forward the bug to the transcript lane",
    startedAt: minutesAgo(0.05),
    ...(status === "completed" && { output: "sent\n", exitCode: 0 }),
  });
const steer = (fields: Partial<AcpmuxRow>) => user("Why did you not respond there?", 0.1, fields);

const phase = (rows: AcpmuxRow[], isWorking = true) => chat([...earlier, ...rows], { isWorking });

/// The live line drawn last with its words, in sight over the stack.
const lineLast = async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const rows = [...ctx.document.querySelectorAll(".acpmux-scroll [data-row-id]")];
    const last = rows.at(-1);
    const line = last?.querySelector(".cv-worked--live:not(.is-quiet)");
    const stack = ctx.document.querySelector(".acpmux-running-tray") ?? ctx.document.querySelector(".acpmux-composer");
    if (!line || !stack) return false;
    return line.getBoundingClientRect().bottom <= stack.getBoundingClientRect().top + 0.5;
  });
};

export default agentPaneEntry({
  id: "agent-pane.live-line-every-phase",
  title: "Live line in every phase of a running turn",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/conversation/turns.ts"],
  variants: {
    "sent-before-record": {
      note: "Sent after a finished turn; acpmux has not written it yet: Thinking under it already.",
      play: lineLast,
      snapshot: phase([{ ...prompt, pending: true }], false),
    },
    "sent-chat-running": {
      note: "The chat reads as running before the prompt's record comes: Thinking under it, not a finished turn.",
      play: lineLast,
      snapshot: phase([{ ...prompt, pending: true }]),
    },
    thinking: {
      note: "The turn opened, nothing out yet: Thinking.",
      play: lineLast,
      snapshot: phase([prompt]),
    },
    "call-running": {
      note: "A call runs: the line names it.",
      play: lineLast,
      snapshot: phase([prompt, activity([thought("Looking at what ran"), log("in_progress")], 0.15)]),
    },
    "between-calls": {
      note: "The call is done and nothing else runs yet: the line keeps the step and the turn's clock.",
      play: lineLast,
      snapshot: phase([prompt, activity([thought("Looking at what ran"), log("completed")], 0.15)]),
    },
    "steer-waiting": {
      note: "A message sent mid-turn waits for the agent's step: the line stays under it.",
      play: lineLast,
      snapshot: phase([prompt, activity([log("completed")], 0.15), steer({ steer: "waiting" })]),
    },
    "steer-read-call-running": {
      note: "The agent read the message and runs a call: the line names the call, under the message.",
      play: lineLast,
      snapshot: phase([
        prompt,
        activity([log("completed")], 0.15),
        steer({ steer: "landed" }),
        activity([forward("in_progress")], 0.05),
      ]),
    },
    "steer-read-between-calls": {
      note: "After the message, a call finished and the agent thinks again: never a bare finished row.",
      play: lineLast,
      snapshot: phase([
        prompt,
        activity([log("completed")], 0.15),
        steer({ steer: "landed" }),
        activity([forward("completed")], 0.05),
      ]),
    },
    "reply-streaming": {
      note: "The reply streams: the line reads Writing under it until the turn ends.",
      play: lineLast,
      snapshot: phase([
        prompt,
        activity([log("completed")], 0.15),
        steer({ steer: "landed" }),
        activity([forward("completed")], 0.05),
        assistant("I did answer both; the app showed no line while I worked.", 0.02),
      ]),
    },
  },
});
