// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A reply from a turn the agent ran on its own gets its action row (Copy, Fork, Timeline, Read aloud,
// More) in the frame its turn ends, with the icons it keeps (direct.ts `reduceBackgroundTurn` stops
// the reply's row at the ended record; turns.ts `backgroundFooters` draws the row). Before, the reply
// kept streaming past its end and the row came with the next record, 5.8 s later in Leo's chat (Leo,
// 2026-11-22: "this wrap-up had a very delayed set of icons appearing").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const REPLY = "Still running; nothing new.";

const opening = [
  user("Watch the release build and tell me when it changes", 14),
  activity(
    [tool("gh run watch", "execute", "completed", { command: "gh run watch 4412", output: "in progress" })],
    13.9,
  ),
  assistant("The build is running. I'll check it again in a few minutes and tell you when it changes.", 13.8),
  summary(13.8, { status: "completed", durationMs: 12_000, toolCount: 1, seq: 40 }),
];

/// The turn the agent woke for: its line, a check, and its reply.
const woke = (id: string, minutes: number, running: boolean, streaming: boolean): AcpmuxRow[] => [
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: running
      ? { id, trigger: "system", running: true, hasRows: true }
      : { id, trigger: "system", running: false, quiet: false, reason: "result", hasRows: true },
  }),
  activity(
    [tool("gh run view", "execute", "completed", { command: "gh run view 4412", output: "in progress" })],
    minutes - 0.1,
    {
      id: `${id}-check`,
      inBackground: id,
    },
  ),
  assistant(REPLY, minutes - 0.2, { id: `${id}-reply`, inBackground: id, ...(streaming && { streaming: true }) }),
];

export default agentPaneEntry({
  id: "agent-pane.background-reply-end",
  title: "Background reply end",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/direct.ts", "agent-session/acpmux/conversation/turns.ts"],
  variants: {
    streaming: {
      note: "The turn still runs and its reply streams: no row under it yet.",
      snapshot: chat([...opening, ...woke("gallery-bg-stream", 10, true, true)], { isWorking: true }),
    },
    "turn-ended": {
      note: "The frame the turn ends in: the reply's row is there with every icon it keeps (Copy, Fork, Timeline, Read aloud, More). Before the fix this frame drew no row; it came with the next record.",
      snapshot: chat([...opening, ...woke("gallery-bg-ended", 10, false, false)]),
    },
    "next-turn-started": {
      note: "The agent woke again: the last reply's row stays as it first drew, and the next turn runs below it.",
      snapshot: chat(
        [...opening, ...woke("gallery-bg-first", 10, false, false), ...woke("gallery-bg-next", 6, true, true)],
        { isWorking: true },
      ),
    },
    "before-fix": {
      note: "What Leo saw for ~6 s: the turn had ended, but its reply still streamed, so no row came under it.",
      snapshot: chat([...opening, ...woke("gallery-bg-before", 10, false, true)]),
    },
  },
});
