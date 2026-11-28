// A task acpmux's daemon runs (acpmux hub/bg_registry.rs, `daemonTask`) keeps its output in
// acpmux's own spool, which `process/tail` reads whatever the chat's harness: in a Codex chat its
// output shows, while a Codex harness's own background process still reads as unavailable.
import { expect, test } from "bun:test";
import {
  readBackgroundTaskOutput,
  type BackgroundTaskOutputReader,
} from "../src/agent-session/acpmux/conversation/backgroundTaskOutput";

function reader(row: Record<string, unknown>): { reader: BackgroundTaskOutputReader; tails: string[] } {
  const tails: string[] = [];
  const source = {
    listProcesses: async () => ({ processes: [row] }),
    tailProcess: async (id: string) => {
      tails.push(id);
      return { data: btoa("review: no findings\n"), fromByte: 0 };
    },
  } as unknown as BackgroundTaskOutputReader["source"];
  return { reader: { source, sessionId: "chat" }, tails };
}

const row = { id: "chat/bg-1", toolCallId: "call-1", harness: "codex", state: "running" };

test("a daemon task's output shows in a Codex chat", async () => {
  const { reader: read, tails } = reader({ ...row, daemonTask: true });
  const output = await readBackgroundTaskOutput(read, "call-1");
  expect(tails).toEqual(["chat/bg-1"]);
  expect(output).toMatchObject({ running: true, output: "review: no findings\n" });
});

test("a Codex harness's own process still reads as unavailable", async () => {
  const { reader: read, tails } = reader(row);
  const output = await readBackgroundTaskOutput(read, "call-1");
  expect(tails).toEqual([]);
  expect(output).toMatchObject({ running: true, unavailable: true });
});
