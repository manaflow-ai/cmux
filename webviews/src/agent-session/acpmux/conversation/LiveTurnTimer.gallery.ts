// l10n-allow-file: gallery fixtures (sample prompts and tool titles), not shipped UI.
// The running turn's clock (#26214, carried by #28303): a resumed turn still opens with a prompt
// from days before, and its line counted from that prompt ("Thinking 118h 21m 48s"). It counts from
// the live turn's start (the snapshot's `turnStartedAtMs`, direct.ts) instead: 26 s here.
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, chat, tool, user } from "../../../gallery/fixtures/acpmux";

// The resumed turn's opener: the prompt sent 118 h 21 m before the gallery's now.
const OLD_PROMPT_MINUTES = 118 * 60 + 21;
const turnStartedAtMs = GALLERY_NOW - 26_000;

const thinking = () =>
  chat([user("Keep going with the retry fix", OLD_PROMPT_MINUTES, { id: "live-timer-prompt" })], {
    isWorking: true,
    turnStartedAtMs,
  });

const working = () =>
  chat(
    [
      user("Keep going with the retry fix", OLD_PROMPT_MINUTES, { id: "live-timer-prompt" }),
      activity([tool("bun test src/fetch", "execute", "running", { command: "bun test src/fetch" })], 0),
    ],
    { isWorking: true, turnStartedAtMs },
  );

export default agentPaneEntry({
  id: "agent-pane.live-turn-timer",
  title: "Running turn's clock: from the live turn, not its old prompt",
  area: "Agent pane",
  height: 320,
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/WorkingFor.tsx"],
  keywords: ["working for", "thinking", "timer", "elapsed", "resumed turn"],
  variants: {
    thinking: {
      note: "A resumed turn with nothing drawn yet: its clock reads the live turn's 26 s, not 118 h.",
      snapshot: thinking(),
    },
    working: {
      note: "A resumed turn running a command: the working line counts from the live turn's start.",
      snapshot: working(),
    },
  },
});
