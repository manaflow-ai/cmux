// l10n-allow-file: gallery fixtures (sample prompts and thoughts), not shipped UI.
// Every shape a Thought row takes in a transcript, one chat each, for the click test
// (test/thought-click-targets-browser.test.ts): Leo, 2026-11-21, "inconsistent clicks (thought)".
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";

const PROMPT = "Find every retry loop and give them one capped backoff";
const SHORT = "Check the retry helper first, then the callers.";
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
    "working-settled": {
      note: "A settled thought in a turn that still runs.",
      snapshot: settled([done(SHORT), read(0), done(LONG), search(1)], true),
    },
  },
});
