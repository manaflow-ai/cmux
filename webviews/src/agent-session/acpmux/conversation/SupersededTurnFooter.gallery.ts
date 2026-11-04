// l10n-allow-file: gallery fixtures (sample prompts, replies and commands), not shipped UI.
// A stretch of a turn the person came in on counts as ended and gets the end-of-turn row (Copy, Pin,
// Read aloud, its time), as Claude Code desktop draws it (Leo, 2026-11-03: "i also think a lot of
// these should've been counted as "ended"-ish turns that allow me to copy/paste your stuff / cuz look
// claude code lets that happen if the user comes in"). The agent ended on prose and a run of commands,
// the person replied into the turn while it still ran (a steer), and the work goes on under it; each
// variant points at the agent's reply, which shows its stretch's row (turns.ts supersededFooters).
// test/transcript-superseded-footer.test.ts holds the rows.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const command = (title: string, line: string) =>
  tool(title, "execute", "completed", { command: line, description: title });

const PLAN =
  "Three follow-ups, in order:\n\n1. Hook the GitHub seed into starting a chat.\n2. Compress what's sent and stop encoding it as text.\n3. Send several files at once, and send git's packs whole instead of loose files.\n\nAll three are contained Rust changes. Want me to put a lane on them, starting with the seed?";

const reply = () => assistant(PLAN, 9.4, { id: "plan-reply" });
const commands = () =>
  activity(
    [
      command("Read the transfer module", "rg -n transfer src/"),
      command("Count the loose files", "git count-objects -v"),
      command("List the open PRs", "gh pr list"),
      command("Check the seed path", "rg -n seed src/"),
    ],
    9.3,
  );

/// Steered: the person replies into the running turn, and the agent goes on under it.
const steered = (harness: string) =>
  chat(
    [
      user("What's left on the file transfer work?", 10, { seq: 1 }),
      reply(),
      commands(),
      user("ofc", 9, { steer: "landed" }),
      activity([command("Start the seed lane", "sessions new -n 'GitHub seed'")], 8.8),
    ],
    { title: "File transfer follow-ups", harness, isWorking: true },
  );

/// A new prompt over a turn that never got its end (no summary): it ended where he came in.
const unended = () =>
  chat(
    [
      user("What's left on the file transfer work?", 10, { seq: 1 }),
      reply(),
      commands(),
      user("ofc", 9, { seq: 2 }),
      assistant("Started the seed lane.", 8.8),
      summary(8.7, { status: "completed", seq: 3 }),
    ],
    { title: "File transfer follow-ups" },
  );

const pointAtReply: Play = async (ctx) => {
  await ctx.hover({ selector: '[data-row-id="plan-reply"]' });
};

export default agentPaneEntry({
  id: "agent-pane.superseded-turn-footer",
  title: "A turn the person came in on",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter"],
  variants: {
    "steered-claude": {
      note: "Claude Code: the reply before the steer ends on its row (Copy, Pin, Read aloud, time) while the turn still runs.",
      snapshot: steered("claude"),
      play: pointAtReply,
    },
    "steered-codex": {
      note: "Codex: the same stretch, the same row.",
      snapshot: steered("codex"),
      play: pointAtReply,
    },
    "next-prompt-no-summary": {
      note: "A turn with no clean end that the person's next prompt opened over ends on its row too.",
      snapshot: unended(),
      play: pointAtReply,
    },
  },
});
