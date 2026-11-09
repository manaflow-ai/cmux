// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A finished turn the person steered mid-turn has one fold (Leo, 2026-11-07, on "Worked for 5m 15s" with
// "Finished 2 background tasks and ran 8 commands" as a second top-level row under it: "this could have
// been, like, tucked inside the worked for", then "when you open the worked for, that, like, finished
// two, whatever, that's already automatically expanded, so it's as if you just expanded the whole
// worked for entirely"). The arms of turnFoldSteered.experiment.ts: the run lines nested and open
// (shipped), nested and closed, named on the Worked for line, and beside the fold as before.
// Test: test/one-fold-per-turn.test.tsx.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnFoldSteered } from "./turnFoldSteered.experiment";

const run = (description: string, command: string, background = false): AcpmuxActivity =>
  tool(command, "execute", "completed", {
    description,
    command,
    output: "ok\n",
    exitCode: 0,
    ...(background && { background: { state: "completed" as const, exitCode: 0 } }),
  });

/// Leo's turn: two background builds and six commands, a reply, his steer, two more commands, the
/// answer.
function steeredTurn(): AcpmuxRow[] {
  return [
    user("Land the fold fix once both builds pass", 30),
    activity(
      [
        run("Started the web build", "cmux-ci build web --ref HEAD", true),
        run("Started the fold tests", "cmux-ci test -- bun test test/turn-fold-keeps-replies.test.ts", true),
        run("Read the fold code", "rg -n 'aroundReplies' webviews/src"),
        run("Listed the fold tests", "rg -l 'WORKED' webviews/test"),
        run("Checked the branch", "git status --short"),
        run("Read the diff", "git diff --stat origin/feat-cmux-next"),
      ],
      29,
    ),
    assistant("Both builds are running. I'm reading how the fold splits a turn while they go.", 26),
    user("Also check the nightly before you land", 25.5, { steer: "landed" }),
    activity(
      [
        run("Listed the nightly runs", "gh run list --workflow nightly-next.yml --limit 3"),
        run("Read the latest nightly", "gh run view --log-failed"),
      ],
      25,
    ),
    assistant(
      "The nightly is green and both builds passed. The fold fix is up for review:\n\n" +
        "- A steered turn closes to its one Worked for.\n- Opening it shows every run already open.",
      24.8,
    ),
    summary(24.75, { status: "completed", durationMs: 315_000, toolCount: 8 }),
  ];
}

const snapshot = (rows: AcpmuxRow[], family = "claude") => {
  const base = chat(rows, { title: "One fold per turn", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the turn's "Worked for" line.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (note: string, family?: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(steeredTurn(), family),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.one-fold-per-turn",
  title: "One fold per steered turn",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor",
    "agent-session/acpmux/conversation/TurnRows.tsx#ToolRows",
    "agent-session/acpmux/conversation/ToolRun.tsx",
  ],
  // Each arm closed, then opened.
  experiment: { definition: turnFoldSteered, script: [{ name: "Open the turn's Worked for", run: openWorked }] },
  variants: {
    closed: variant("Leo's steered turn, closed: one Worked for, then the reply, his steer and the answer."),
    open: variant("Opened: the run lines inside Worked for, already open in the shipped arm.", "claude", openWorked),
    codex: variant("The same turn in a Codex chat: the same one fold.", "codex"),
  },
});
