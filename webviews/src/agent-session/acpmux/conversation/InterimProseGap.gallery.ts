// l10n-allow-file: gallery fixtures (sample prompts, notes and commands), not shipped UI.
// Interim prose between tool rows (Leo, 2026-11-01: "the thoughts in between tool calls probably
// want a bit more padding"). A run of calls holds two short notes the agent wrote between its
// calls, as a finished turn's opened fold joins them (turns.ts mergeShortNotes; a running turn keeps
// each note its own row, cmux#38339): a command, a note, two commands under "Ran 2 commands", a
// note, a command, then the live line. Each note is an aside that splits the calls
// around it into their own runs (toolGroups.ts `isAside`), and "Ran 2 commands" is opened, as in
// the reader's view. Each note has the plain status gap (`--cv-note-gap`, 12px) to the rows above and
// below it, as a longer reply between two runs has; the rows of the run keep their 22px rhythm
// (transcript-interim-prose-gap.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";

const command = (title: string, line: string) =>
  tool(title, "execute", "completed", { command: line, description: title });

const note = (text: string): AcpmuxActivity => ({ kind: "note", text });

const rows = [
  user("Find who owns the retry fix and whether anyone has claimed it.", 10),
  // The run as mergeShortNotes leaves it: the notes among its calls. A finished call stays in its
  // run (the live line reads Thinking under it), so the last one keeps the second note between two
  // of the run's rows.
  activity(
    [
      command("List the worktree subcommands", "wt --help"),
      note("No claim on the retry fix yet; checking the other branch's owner with a longer fetch bound."),
      command("Show the open pull requests", "gh pr list --limit 20"),
      command("Find the retry helper", "rg -n fetchWithRetry src"),
      note("Its owner merged an hour ago, so the helper is free."),
      command("Run the helper's tests", "bun test fetch"),
    ],
    9.9,
  ),
];

const snapshot = chat(rows, { title: "Retry fix", isWorking: true });

/// Open the "Ran 2 commands" line, so both notes sit between drawn tool rows. Its line, not a lone
/// command's row, which opens that command's output instead.
const openRun: Play = async (ctx) => {
  const run = '.acpmux-activity .cv-tool.is-run[aria-expanded="false"]';
  await ctx.waitFor(() => ctx.document.querySelector(`${run}, .cv-tool-note`));
  if (ctx.document.querySelector(run)) await ctx.click({ selector: run });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-tool-note").length === 2);
};

const variant = (note: string, gap?: string) => ({
  note,
  snapshot,
  play: openRun,
  ...(gap && { documentAttributes: { "transcript-note-gap": gap } }),
});

export default agentPaneEntry({
  id: "agent-pane.interim-prose-gap",
  title: "Notes between tool rows",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx", "agent-session/acpmux/conversation/conversation.css"],
  variants: {
    shipped: variant(
      "Shipped: 12px (the plain status gap, the transcript's inner gap) above and below each note, as a longer reply between two runs has.",
    ),
    tight: variant("Before: 3px above and below each note, tight against the tool rows.", "tight"),
    snug: variant("8px above and below each note (the message gap).", "snug"),
    roomy: variant("16px above and below each note (the turn gap).", "roomy"),
  },
});
