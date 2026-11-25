// l10n-allow-file: gallery fixtures (sample prompts and thoughts), not shipped UI.
// Every shape a Thought row takes in a transcript, one chat each, for the click test
// (test/thought-click-targets-browser.test.ts): Leo, 2026-11-21, "inconsistent clicks (thought)".
// The row's line is the thought's own first line (Leo, 2026-11-22: "had the whole line be the line?
// then you expand and it simply shows you the rest"): one-line and wrapping-line show a thought with
// nothing under its line, and time-open and time-hover are other looks for how long it took.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";

const PROMPT = "Find every retry loop and give them one capped backoff";
const SHORT = "Check the retry helper first, then the callers.\nThe socket reconnect comes after both.";
/// A thought its row's line holds whole: no chevron, nothing to open.
const ONE = "Check the retry helper first, then the callers.";
/// One unbroken line wider than the row: cut with an ellipsis, it opens to its wrapped words alone.
const WIDE =
  "The fetch client retries in request() with its own sleep doubling each time and no cap, the socket reconnect keeps a timer of its own that resets on every open, and the upload queue retries each part five times at a fixed second, so all three need the one capped helper.";
const LONG = [
  "**Finding the loops**",
  "The fetch client retries in `request()`, with its own sleep doubling each time and no cap.",
  "The socket reconnect keeps a timer of its own, reset on every open, so a flapping server never backs off.",
  "The upload queue retries each part five times at a fixed second, which hammers a server that is down.",
  "**Plan**",
  "One `backoff(attempt)` helper, capped at eight seconds with jitter, that all three call.",
].join("\n\n");
const done = (text: string) => thought(text, { startedAt: 0, endedAt: 4_000 });
const search = (n: number) => tool(`Search pattern${n}`, "search", "completed");
const read = (n: number) =>
  tool(`Read file${n}.ts`, "read", "completed", { locations: [{ path: `/Users/you/src/atlas-web/file${n}.ts` }] });
const settled = (items: ReturnType<typeof tool>[], working = false) =>
  chat(
    [
      user(PROMPT, 2),
      activity(items as never, 1.5),
      assistant("Done: one backoff helper.", 1.2),
      summary(1.1, { status: "completed", durationMs: 14_000, toolCount: 2 }),
    ],
    { isWorking: working },
  );

export default agentPaneEntry({
  id: "agent-pane.thought-shapes",
  title: "Thought row shapes",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/ThoughtRow.tsx", "agent-session/acpmux/conversation/ToolGroupRow.tsx"],
  variants: {
    short: { note: "One short settled thought, alone.", snapshot: settled([done(SHORT), read(0)]) },
    long: { note: "One long settled thought, alone.", snapshot: settled([done(LONG), read(0)]) },
    "lead-run": {
      note: "A thought that leads a run of searches.",
      snapshot: settled([done(SHORT), search(0), search(1), search(2)]),
    },
    "between-calls": {
      note: "Thoughts between calls of one run.",
      snapshot: settled([search(0), done(SHORT), search(1), done(LONG), search(2), search(3)]),
    },
    live: {
      note: "A thought that still streams.",
      snapshot: chat(
        [
          user(PROMPT, 0.1),
          activity([thought(SHORT, { startedAt: Date.now() - 1_500, endedAt: Date.now() })], 0.05, { streaming: true }),
        ],
        { isWorking: true },
      ),
    },
    "one-line": {
      note: "A thought its line holds whole: the brain and its words, no chevron, and it does not open.",
      snapshot: settled([done(ONE), read(0)]),
    },
    "wrapping-line": {
      note: "One unbroken line wider than the row: cut with an ellipsis closed; opened, the same words wrapped, nothing under them.",
      snapshot: settled([done(WIDE), read(0)]),
    },
    "time-open": {
      note: "Alternative: how long a thought took shows only on an opened row.",
      snapshot: settled([search(0), done(SHORT), search(1), done(LONG), search(2), search(3)]),
      documentAttributes: { "thought-time": "open" },
    },
    "time-hover": {
      note: "Alternative: how long a thought took shows on an opened row, or under the pointer or keyboard focus.",
      snapshot: settled([search(0), done(SHORT), search(1), done(LONG), search(2), search(3)]),
      documentAttributes: { "thought-time": "hover" },
    },
    "working-settled": {
      note: "A settled thought in a turn that still runs.",
      snapshot: settled([done(SHORT), read(0), done(LONG), search(1)], true),
    },
  },
});
