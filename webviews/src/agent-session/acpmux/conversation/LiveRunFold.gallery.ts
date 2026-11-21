// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// When a running turn's run closes to its summary line (liveRunFold.experiment.ts). The moment shown:
// the run the agent works in has a thought, a command, a thought and a second command that just
// finished, and no paragraph under it yet. Before (`now`), that second call closed the run to one "Ran 2
// commands" line, mid-turn (Leo, 2026-11-21: "sometimes it does so too soon in the midst of a turn.
// thats not great"). Tests: live-run-holds-open.test.tsx.
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, assistant, chat, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { liveRunFold } from "./liveRunFold.experiment";

const run = (command: string, status = "completed"): AcpmuxActivity =>
  tool(command, "execute", status, { command, output: status === "completed" ? "ok\n" : undefined, exitCode: 0 });
const prompt = () => user("Restart the broker on both hosts and tell me when it's back.", 3);
const live = (rows: AcpmuxRow[]) => chat(rows, { isWorking: true, turnStartedAtMs: GALLERY_NOW - 41_000 });

/// An earlier run, closed by the paragraph under it.
const earlier = () => activity([run("broker status --all"), run("tailscale status")], 2);
const said = () =>
  assistant("Both hosts answer. The broker runs on each; I'll check how it restarts before touching it.", 1.5);
/// The run the agent works in: its second command just finished.
const working = () =>
  activity(
    [
      thought("I'm checking whether restarting the broker is safe while a lane is pushing."),
      run("broker queue --pending"),
      thought("There's no restart subcommand; reading its help."),
      run("broker --help"),
    ],
    1,
  );

/// Mid-turn, the second call of the latest run just finished.
const midTurn = () => live([prompt(), earlier(), said(), working()]);
/// The agent's next paragraph arrived: the run above it closes in every arm but `turn-end`.
const replied = () =>
  live([
    prompt(),
    earlier(),
    said(),
    working(),
    assistant("The broker restarts with `broker stop` then `broker start`; doing that on each host now.", 1),
  ]);

const liveLine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-row[data-row-id="thinking-live"]'), { capMs: 10_000 });
};

export default agentPaneEntry({
  id: "agent-pane.live-run-fold",
  title: "Running turn: when a run closes",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/turns.ts#codexRuns", "agent-session/acpmux/conversation/TurnRows.tsx"],
  keywords: ["running turn", "run", "collapse", "fold", "too soon", "mid-turn", "tool calls", "summary line"],
  experiment: { definition: liveRunFold, script: [{ name: "The live line shows", run: liveLine }] },
  variants: {
    "hold-until-paragraph": {
      note: "Shipped: the run the agent works in keeps its thought, command, thought and command open under its line until the agent's next paragraph; the earlier run, a paragraph under it, is closed.",
      snapshot: midTurn(),
      experiments: { "live-run-fold": "paragraph" },
    },
    "hold-until-turn-end": {
      note: "Every run of the running turn stays open, the earlier one too, until the turn ends.",
      snapshot: midTurn(),
      experiments: { "live-run-fold": "turn-end" },
    },
    "shrink-now": {
      note: 'Before: the second command finishing closed the run to one "Ran 2 commands" line, mid-turn, with nothing new under it.',
      snapshot: midTurn(),
      experiments: { "live-run-fold": "now" },
    },
    "after-paragraph": {
      note: "The agent's next paragraph arrived: the run above it closes to its line, as an earlier run does.",
      snapshot: replied(),
      experiments: { "live-run-fold": "paragraph" },
    },
  },
});
