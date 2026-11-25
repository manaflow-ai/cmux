// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// Leo 2026-11-22: "this still goes to the top instead of staying at the bottom when composer grows."
// A chat long enough to scroll, with the composer at one line and at five: the last message sits
// right above the composer in both, and a reader scrolled up keeps their place
// (test/transcript-composer-grow-anchor.test.ts types the draft and samples every frame).
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";

const turns = (count = 24) =>
  Array.from({ length: count }, (_, index) => [
    user(`Question ${index + 1}: how does the retry helper back off?`, 600 - index * 20),
    assistant(
      `Answer ${index + 1}. The helper waits a jittered backoff between tries, only for network errors and 5xx answers, and gives up after three attempts. A 404 never retries.`,
      590 - index * 20,
    ),
  ]).flat();

const FIVE_LINES = { draft: "First line of the plan\nsecond line\nthird line\nfourth line\nfifth line" };

export default agentPaneEntry({
  id: "agent-pane.transcript-composer-grow",
  title: "Transcript stays put as the composer grows",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 700, wide: 900 },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx", "agent-session/acpmux/Composer.tsx"],
  variants: {
    "bottom-one-line": {
      note: "At the bottom with a one-line draft: the last message sits right above the composer. Type Shift-Return to grow it; the message stays above it.",
      snapshot: chat(turns()),
      ready: { draft: "Also cover the 503 path" },
    },
    "bottom-five-lines": {
      note: "At the bottom with a five-line draft: the last message still sits right above the composer.",
      snapshot: chat(turns()),
      ready: FIVE_LINES,
    },
    "scrolled-up-five-lines": {
      note: "Scrolled up away from the bottom with a five-line draft: the reader's place holds as the composer grows or shrinks.",
      snapshot: chat(turns()),
      ready: FIVE_LINES,
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, 600);
      },
    },
  },
});
