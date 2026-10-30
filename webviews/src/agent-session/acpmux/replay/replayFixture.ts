// l10n-allow-file: a recorded chat for the gallery and tests, not shipped UI.
// A recorded acpmux chat as `_acpmux/events` returns it: one turn that reads a file, runs the
// tests, edits the file and runs them again, with the wall-clock gaps a real turn has
// (and one long pause, which replay shortens).
import type { EventRecord } from "../direct";

export const REPLAY_SESSION = "replay-fixture";
const START = Date.UTC(2026, 9, 10, 16, 20, 0);

type Step = [afterMs: number, dir: string, kind: string, msg: Record<string, any>];

const update = (sessionUpdate: string, fields: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate, ...fields } },
});
const say = (text: string) => update("agent_message_chunk", { content: { type: "text", text } });
const output = (text: string) => [{ type: "content", content: { type: "text", text } }];

const OLD = `export async function withRetry<T>(run: () => Promise<T>, attempts = 3): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= attempts) throw error;
      await sleep(100 * attempt);
    }
  }
}
`;
const NEW = OLD.replace("attempt >= attempts", "attempt + 1 >= attempts").replace(
  "100 * attempt",
  "100 * 2 ** attempt",
);

const STEPS: Step[] = [
  [0, "mux", "user_message", { text: "The retry test in api/client.test.ts is flaky. Find out why and fix it." }],
  [300, "mux", "turn_started", {}],
  [
    900,
    "in",
    "agent_thought_chunk",
    update("agent_thought_chunk", { content: { type: "text", text: "Read the retry helper first." } }),
  ],
  [
    1200,
    "in",
    "tool_call",
    update("tool_call", {
      toolCallId: "read-1",
      title: "Read api/client.ts",
      kind: "read",
      status: "in_progress",
      locations: [{ path: "api/client.ts" }],
    }),
  ],
  [
    400,
    "in",
    "tool_call_update",
    update("tool_call_update", { toolCallId: "read-1", status: "completed", content: output(OLD) }),
  ],
  [
    1500,
    "in",
    "tool_call",
    update("tool_call", {
      toolCallId: "run-1",
      title: "bun test api/client.test.ts",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "bun test api/client.test.ts" },
    }),
  ],
  [
    3200,
    "in",
    "tool_call_update",
    update("tool_call_update", {
      toolCallId: "run-1",
      status: "failed",
      content: output(
        "✗ retries three times before failing\n  Expected calls: 3\n  Received calls: 4\n\n1 fail, 11 pass",
      ),
    }),
  ],
  [
    1800,
    "in",
    "agent_message_chunk",
    say("The loop allows one attempt too many: `attempt >= attempts` lets attempt 3 run, "),
  ],
  [600, "in", "agent_message_chunk", say("and the first retry waits 0 ms. ")],
  [500, "in", "agent_message_chunk", say("I'll count attempts from one and back off exponentially.")],
  [
    2400,
    "in",
    "tool_call",
    update("tool_call", {
      toolCallId: "edit-1",
      title: "Edit api/client.ts",
      kind: "edit",
      status: "in_progress",
      content: [{ type: "diff", path: "api/client.ts", oldText: OLD, newText: NEW }],
      locations: [{ path: "api/client.ts", line: 6 }],
    }),
  ],
  [300, "in", "tool_call_update", update("tool_call_update", { toolCallId: "edit-1", status: "completed" })],
  // The agent waited on a rate limit here; replay keeps two seconds of it.
  [
    45_000,
    "in",
    "tool_call",
    update("tool_call", {
      toolCallId: "run-2",
      title: "bun test api/client.test.ts",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "bun test api/client.test.ts" },
    }),
  ],
  [
    2900,
    "in",
    "tool_call_update",
    update("tool_call_update", {
      toolCallId: "run-2",
      status: "completed",
      content: output("✓ retries three times before failing\n✓ backs off between attempts\n\n12 pass"),
    }),
  ],
  [
    1100,
    "in",
    "agent_message_chunk",
    say("Fixed: `withRetry` now makes exactly `attempts` calls and waits 100, 200, 400 ms between them. "),
  ],
  [500, "in", "agent_message_chunk", say("All 12 tests in api/client.test.ts pass.")],
  [600, "mux", "turn_result", { status: "completed" }],
];

export function replayFixtureEvents(): EventRecord[] {
  let at = START;
  return STEPS.map(([after, dir, kind, msg], index) => {
    at += after;
    return { sessionId: REPLAY_SESSION, seq: index + 1, at, dir, kind, msg };
  });
}
