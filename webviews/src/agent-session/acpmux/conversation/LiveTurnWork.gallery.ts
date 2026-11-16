// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A running turn as chatgpt.com draws it: one live status line that replaces itself at each step,
// with no finished run stacked over it (the user, 2026-11-10: "we need to match and be the same").
// The replies to the person stay in sight (Leo, 2026-11-06). The arms of liveTurnWork.experiment.ts
// differ only in the finished runs: none (`line`, shipped) or each in sight (`runs`).
// Tests: live-turn-one-line.test.ts.
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, assistant, chat, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { liveTurnWork } from "./liveTurnWork.experiment";

const run = (command: string, status = "completed"): AcpmuxActivity =>
  tool(command, "execute", status, { command, output: status === "completed" ? "ok\n" : undefined, exitCode: 0 });
const prompt = () => user("The reconnect test fails about one run in five on CI. Find out why and fix it.", 3);
const live = (rows: AcpmuxRow[]) => chat(rows, { isWorking: true, turnStartedAtMs: GALLERY_NOW - 74_000 });

/// Mid-turn: three finished calls and a thought, a test run in flight.
const running = () =>
  live([
    prompt(),
    activity(
      [
        run("rg -n scheduleReconnect src"),
        run("git log -5 --oneline src/net"),
        thought("The backoff timer is armed twice when the socket closes during a retry."),
        run("bun test src/net/reconnect.test.ts --rerun-each 10", "in_progress"),
      ],
      1,
    ),
  ]);

/// A reply to the person between two runs, a command in flight after it.
const withReply = () =>
  live([
    prompt(),
    activity([run("rg -n scheduleReconnect src"), run("git log -5 --oneline src/net")], 2),
    assistant(
      "Found it: the backoff timer is armed twice when the socket closes during a retry, so a second " +
        "reconnect can race the first. I'm moving the arm into one place and rerunning the test.",
      1.5,
    ),
    activity(
      [run("bun run lint src/net"), run("bun test src/net/reconnect.test.ts --rerun-each 20", "in_progress")],
      1,
    ),
  ]);

/// Between steps: the calls all finished, the agent thinks.
const thinking = () =>
  live([prompt(), activity([run("rg -n scheduleReconnect src"), thought("Now check who else arms the timer.")], 1)]);

/// Waits for the turn's live line, which both arms draw at the bottom: the stage is then what the arm
/// shows for the running turn.
const liveLine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-row[data-row-id="thinking-live"]'), { capMs: 10_000 });
};

export default agentPaneEntry({
  id: "agent-pane.live-turn-work",
  title: "Running turn: one live line",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/turns.ts#codexRuns", "agent-session/acpmux/conversation/Thinking.tsx"],
  keywords: ["running turn", "live line", "status", "tool calls", "chatgpt", "streaming"],
  experiment: { definition: liveTurnWork, script: [{ name: "The live line shows", run: liveLine }] },
  variants: {
    running: {
      note: "A test run in flight: the prompt, then one live line naming it; the finished calls and the thought leave no row.",
      snapshot: running(),
    },
    "with-reply": {
      note: "A reply between two runs stays in sight; the runs around it do not.",
      snapshot: withReply(),
    },
    thinking: {
      note: "Every call finished: the same line reads Thinking, in place.",
      snapshot: thinking(),
    },
  },
});
