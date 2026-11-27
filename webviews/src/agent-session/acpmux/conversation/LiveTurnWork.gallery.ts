// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A running turn's work above its one live status line. The arms of liveTurnWork.experiment.ts
// differ only in the finished calls: each on its own line until the turn ends (`open`, shipped:
// Leo, 2026-11-21, "i thought we dont fold while you're still going. but my steers affect these"),
// each finished run folded into its summary line (`runs`, the Codex app), or none (`line`, as
// chatgpt.com draws it). The replies to the person stay in sight (Leo, 2026-11-06).
// Tests: live-turn-open-runs.test.tsx, live-turn-one-line.test.ts, transcript-live-runs.test.tsx.
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

/// The person steered mid-turn: four finished calls before the steer, more after it, one in flight.
/// Under `open` the calls before the steer draw as they did before it came; under `runs` they fold.
const steered = () =>
  live([
    prompt(),
    activity(
      [
        run("rg -n scheduleReconnect src"),
        run("git log -5 --oneline src/net"),
        run("rg -n armBackoff src"),
        run("bun test src/net/reconnect.test.ts"),
      ],
      3,
    ),
    user("Also check the retry cap while you're there.", 2, { steer: "landed" }),
    activity(
      [
        run("rg -n MAX_RETRIES src/net"),
        run("git diff src/net/backoff.ts"),
        run("bun test src/net/backoff.test.ts --rerun-each 10", "in_progress"),
      ],
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
  title: "Running turn: its work above the live line",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/turns.ts#codexRuns", "agent-session/acpmux/conversation/Thinking.tsx"],
  keywords: ["running turn", "live line", "status", "tool calls", "chatgpt", "streaming"],
  experiment: { definition: liveTurnWork, script: [{ name: "The live line shows", run: liveLine }] },
  variants: {
    running: {
      note: "A test run in flight: the prompt, the finished calls and the thought as the arm draws them, then one live line naming the test run.",
      snapshot: running(),
    },
    "with-reply": {
      note: "A reply between two runs stays in sight under every arm; the runs around it draw as the arm draws them.",
      snapshot: withReply(),
    },
    steered: {
      note: "The person steered mid-turn. Under open the calls before the steer keep their own lines, as before it came; under runs the steer folds them into a summary line.",
      snapshot: steered(),
    },
    thinking: {
      note: "Every call finished: the same line reads Thinking, in place.",
      snapshot: thinking(),
    },
  },
});
