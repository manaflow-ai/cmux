// l10n-allow-file: gallery fixtures (sample prompts, notes and commands), not shipped UI.
// Interim prose between tool rows (Leo, 2026-11-01: "the thoughts in between tool calls probably
// want a bit more padding"). A running turn's run of calls holds two short notes the agent wrote
// between its calls (turns.ts mergeShortNotes): a command, a note, two commands under "Ran 2
// commands", a note, a command, then the latest call on the live line. The run is opened, as in the
// reader's view. Each note has the plain status gap (`--cv-note-gap`, 12px) to the rows above and
// below it, as a longer reply between two runs has; the rows of the run keep their 22px rhythm
// (transcript-interim-prose-gap.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const command = (title: string, line: string) =>
  tool(title, "execute", "completed", { command: line, description: title });

const rows = [
  user("Find who owns the retry fix and whether anyone has claimed it.", 10),
  activity([command("List the worktree subcommands", "wt --help")], 9.9),
  assistant("No claim on the retry fix yet; checking the other branch's owner with a longer fetch bound.", 9.8),
  activity(
    [
      command("Show the open pull requests", "gh pr list --limit 20"),
      command("Find the retry helper", "rg -n fetchWithRetry src"),
    ],
    9.7,
  ),
  assistant("Its owner merged an hour ago, so the helper is free.", 9.6),
  activity([command("Run the helper's tests", "bun test fetch")], 9.5),
  // The running turn's latest step draws as its live line, outside the run (#29938), so one more
  // call keeps the second note between two of the run's rows.
  activity([command("Show the test log", "tail -n 40 fetch.log")], 9.4),
];

const snapshot = chat(rows, { title: "Retry fix", isWorking: true });

/// Open the run (its "Ran 2 commands" group draws opened), so both notes sit between drawn tool rows.
const openRun: Play = async (ctx) => {
  const run = '.acpmux-activity .cv-tool.is-toggle[aria-expanded="false"]';
  await ctx.waitFor(() => ctx.document.querySelector(run));
  await ctx.click({ selector: run });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-note"));
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
