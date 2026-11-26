// l10n-allow-file: gallery fixtures (prompts, replies, commands), not shipped UI.
// Turns something other than the person started that said nothing to them, in the composer hat
// instead of the transcript (silentTurns.ts). Leo, 2026-11-25, on bare "Worked for 3s >" rows with
// nothing between them: "so... why were these 0 text output from you (is that a personal setting on
// my end)". The transcript keeps the person's turn; the hat lists each silent turn as a finished
// line in the command's row style, which opens to the calls it made. Synthetic data.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const opening = [
  user("Land #412 once CI passes", 6, { id: "silent-prompt" }),
  assistant("Queued it. I'll land it when CI is green.", 5.9, { id: "silent-reply" }),
  summary(5.9, { id: "silent-footer", status: "completed", durationMs: 4_000 }),
];

const check = (command: string, output: string) =>
  tool(command, "execute", "completed", { command, output, description: command });

/// A quiet background turn that checked something and had nothing to say.
const quiet = (id: string, minutes: number, commands: [string, string][]): AcpmuxRow[] => [
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: { id, trigger: "system", running: false, quiet: true, reason: "result", hasRows: true },
  }),
  activity(
    commands.map(([command, output]) => check(command, output)),
    minutes - 0.02,
    { id: `${id}-work`, inBackground: id },
  ),
];

const rows = [
  ...opening,
  ...quiet("silent-a", 1.2, [["gh pr checks 412", "3 pending"]]),
  ...quiet("silent-b", 0.8, [
    ["gh run list --branch lane/412", "in_progress"],
    ["gh pr checks 412", "2 pending"],
  ]),
  ...quiet("silent-c", 0.4, [["gh pr checks 412", "1 pending"]]),
];

const openHat = async (ctx: PlayContext) => {
  const head = { selector: ".acpmux-running-tray__head" };
  await ctx.waitFor(() => ctx.document.querySelector(head.selector));
  await ctx.click(head);
};

export default agentPaneEntry({
  id: "agent-pane.silent-turns",
  title: "Silent background turns go to the composer hat",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/silentTurns.ts"],
  variants: {
    folded: {
      note: "Three quiet background turns: the transcript ends on the person's turn; the hat counts them as done.",
      snapshot: chat(rows),
    },
    open: {
      note: "The hat opened: one finished line per turn, each with its time, opening to the calls it made.",
      snapshot: chat(rows),
      play: openHat,
    },
  },
});
