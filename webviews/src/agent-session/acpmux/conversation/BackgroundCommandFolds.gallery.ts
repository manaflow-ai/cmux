// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A background command that finished during a turn is the turn's work: its "Background command
// completed" note folds under the turn's "Worked for" with the calls around it (Leo, 2026-11-11:
// "Background command completed. Do those not count as the f-ing works for?"). Before, every such
// note drew beside the closed fold, a bare line between it and the answer. One that failed still
// stays in sight. Test: conversation/turnFoldStyle.test.ts.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

const shellEnd = (id: string, minutes: number, command: string, state: "completed" | "failed"): AcpmuxRow =>
  row("backgroundTask", minutes, {
    id,
    backgroundTask: { toolCallId: `${id}-call`, command, state, ...(state === "failed" && { exitCode: 1 }) },
  });

/// A turn whose two background commands end between its calls; `failed` makes the second one fail.
function turn(failed = false): AcpmuxRow[] {
  return [
    user("Run the fold tests and the web build, then tell me if it's good", 12),
    activity(
      [
        run("Started the fold tests", "bun test src/agent-session/acpmux/conversation/turnFoldStyle.test.ts"),
        run("Started the web build", "bun run build"),
      ],
      11.9,
    ),
    shellEnd("bg-tests", 11, "bun test src/agent-session/acpmux/conversation/turnFoldStyle.test.ts", "completed"),
    activity([run("Read the test output", "tail -n 20 test.log")], 10.9),
    shellEnd("bg-build", 10, "bun run build", failed ? "failed" : "completed"),
    activity([run("Checked the build output", "ls dist")], 9.9),
    assistant(
      failed
        ? "The fold tests pass, but the web build failed; the log is above."
        : "Both pass: 23 tests, and the build is clean.",
      9.8,
    ),
    summary(9.75, { status: "completed", durationMs: 135_000, toolCount: 4 }),
  ];
}

const snapshot = (rows: AcpmuxRow[], family = "claude") => {
  const base = chat(rows, { title: "Background commands fold", harness: family });
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

const variant = (note: string, rows: AcpmuxRow[], family?: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(rows, family),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.background-command-folds",
  title: "Background commands fold under Worked for",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/turns.ts"],
  variants: {
    closed: variant(
      'Leo\'s case: two "Background command completed" notes inside the turn fold under its one Worked for; the answer alone draws under it (before: both notes drew beside the closed line).',
      turn(),
    ),
    open: variant("Opened: each note in its place among the calls, as it ran.", turn(), "claude", openWorked),
    failed: variant("A background command that failed stays in sight beside the closed Worked for.", turn(true)),
    codex: variant("The same turn in a Codex chat: the same fold.", turn(), "codex"),
  },
});
