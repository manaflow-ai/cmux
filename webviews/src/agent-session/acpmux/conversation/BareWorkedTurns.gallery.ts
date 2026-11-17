// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// Finished turns that said nothing to the person (wakes and other agents' messages the agent answered
// with tools alone) used to stack one closed "Worked for" each with nothing between them (Austin's chat,
// 2026-11-17: "Worked for 37s", "Worked for 3s", "Worked for 1m", "Worked for 37s", "Worked for 1m 5s";
// Leo: "1 me 2 austin we sometimes have weird ui like this"). The arms of bareWorkedTurns.experiment.ts:
// one joined line (shipped), hidden, and one line each as before.
// Test: conversation/bareWorkedTurns.test.ts.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { bareWorkedTurns } from "./bareWorkedTurns.experiment";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

/// A wake the agent answered with commands alone, `minutes` ago, taking `seconds`.
function wake(minutes: number, seconds: number, commands: [string, string][]): AcpmuxRow[] {
  return [
    user("", minutes, { incoming: { kind: "hidden" } } as Partial<AcpmuxRow>),
    activity(
      commands.map(([description, command]) => run(description, command)),
      minutes - 0.01,
    ),
    summary(minutes - seconds / 60, { status: "completed", durationMs: seconds * 1_000, toolCount: commands.length }),
  ];
}

function austinsChat(): AcpmuxRow[] {
  return [
    user("Fix the tip icon test and push the new head", 30),
    activity(
      [
        run("Searched for the tint", "rg -n 'func applyTint' Sources"),
        run("Updated the tip icon test", "git apply tip-icon.patch"),
        run("Pushed the new head", "git push -q origin HEAD"),
      ],
      29,
    ),
    assistant("Pushed the new head; the test now expects the results icon at 83% alpha.", 27),
    summary(26.9, { status: "completed", durationMs: 180_000, toolCount: 3 }),
    ...wake(20, 37, [["Read the job's output", "acpmux bg output 7f2c"]]),
    ...wake(16, 3, [["Stopped the monitor", "acpmux bg stop 7f2c"]]),
    ...wake(12, 60, [["Checked the build", "gh run list --limit 3"]]),
    ...wake(8, 37, [["Read the job's output", "acpmux bg output 91ad"]]),
    ...wake(4, 65, [["Checked the PR's checks", "gh pr checks 44890"]]),
  ];
}

const snapshot = (family: string) => {
  const base = chat(austinsChat(), { title: "Reply-less turns", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the joined "Worked for 3m 22s" (the shipped arm; the others have no such line).
const openWorked: Play = async (ctx) => {
  const joined = () =>
    [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].find((line) => line.textContent?.includes("3m 22s"));
  if (joined()?.getAttribute("aria-expanded") !== "false") return;
  await ctx.click({ text: /Worked for 3m 22s/ });
  // Opened, the line becomes its first turn's own; the last wake's own line opens with it.
  await ctx.waitFor(() => !joined() && Boolean(ctx.document.body.textContent?.includes("gh pr checks 44890")), {
    capMs: 10_000,
  });
};

const variant = (note: string, family: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(family),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.bare-worked-turns",
  title: "Turns that said nothing",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  experiment: { definition: bareWorkedTurns, script: [{ name: "Open the last Worked for", run: openWorked }] },
  variants: {
    codex: variant("Austin's five wakes in a Codex chat: one Worked for 3m 22s under the reply.", "codex"),
    claude: variant("The same wakes in a Claude chat.", "claude"),
    open: variant("Opened: each wake's own Worked for and its command, all closing together.", "codex", openWorked),
  },
});
