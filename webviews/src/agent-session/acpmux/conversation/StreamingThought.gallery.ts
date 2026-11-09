// l10n-allow-file: gallery fixtures (sample prompts and thoughts), not shipped UI.
// A running turn's thought from its first words (conversation/turns.ts `codexRuns`): it streams in
// its live viewport over the turn's Thinking line, instead of showing only once the next step ends
// it (Leo, 2026-11-09: "we can be a bit more optimistic with, like, the displaying of the thinking
// ... I only started seeing your thinking bit, like, seven seconds in").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, thought, tool, user } from "../../../gallery/fixtures/acpmux";

const PROMPT = "Find every retry loop and give them one capped backoff";
const SHORT = "Looking for every retry loop: the fetch client, the socket reconnect";
const LONG = [
  "**Finding the loops**",
  "The fetch client retries in `request()`, with its own sleep doubling each time and no cap.",
  "The socket reconnect keeps a timer of its own, reset on every open, so a flapping server never backs off.",
  "The upload queue retries each part five times at a fixed second, which hammers a server that is down.",
  "**Plan**",
  "One `backoff(attempt)` helper, capped at eight seconds with jitter, that all three call.",
].join("\n\n");
const now = Date.now();
const streaming = (text: string) =>
  activity([thought(text, { startedAt: now - 1_500, endedAt: now })], 0.05, { streaming: true });

export default agentPaneEntry({
  id: "agent-pane.streaming-thought",
  title: "A running turn's thought, from its first words",
  area: "Agent pane",
  height: 380,
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/ThoughtRow.tsx"],
  variants: {
    "first-words": {
      note: "Picked. The thought draws from its first chunk, labelled Thinking, over the turn's Thinking line.",
      snapshot: chat([user(PROMPT, 0.1), streaming(SHORT)], { isWorking: true }),
    },
    long: {
      note: "A thought taller than its live viewport keeps its newest lines in view while it streams; once done it folds.",
      snapshot: chat([user(PROMPT, 0.1), streaming(LONG)], { isWorking: true }),
    },
    "then-call": {
      note: "A call ends it: the thought stays in the run as it was drawn, open in its viewport, until the turn's one fold at its end; the line names the call.",
      snapshot: chat(
        [
          user(PROMPT, 0.1),
          activity(
            [
              thought(SHORT, { startedAt: now - 3_000, endedAt: now - 1_000 }),
              tool("rg retry", "execute", "in_progress", { command: "rg -n retry src" }),
            ],
            0.05,
          ),
        ],
        { isWorking: true },
      ),
    },
    before: {
      note: "Before: only the Thinking line, the thought's text nowhere until the next step ended it, seconds later.",
      snapshot: chat([user(PROMPT, 0.1)], { isWorking: true }),
    },
  },
});
