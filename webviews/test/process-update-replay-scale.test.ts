// l10n-allow-file: synthetic process commands are only test fixtures.
import { expect, test } from "bun:test";
import { replayProcessUpdates } from "../src/agent-session/acpmux/session-info/processUpdateReplay";
import type { SessionInfoProcess } from "../src/agent-session/acpmux/session-info/processes";

const record = (id: string, state = "running"): SessionInfoProcess => ({
  id,
  command: `command ${id}`,
  startedAt: 1,
  state,
});

test("newer process updates overwrite older list rows and append new IDs in arrival order", () => {
  const old = record("chat/a");
  const duplicate = record("chat/a", "failed");
  const second = record("chat/b");
  const pending = new Map([
    ["chat/b", record("chat/b", "exited")],
    ["chat/c", record("chat/c", "running")],
    ["chat/a", record("chat/a", "killed")],
    ["chat/d", record("chat/d", "running")],
  ]);
  // Updating an existing map key keeps the slot for the first arrival of a new process.
  pending.set("chat/c", record("chat/c", "exited"));
  const result = replayProcessUpdates([old, duplicate, second], pending);
  expect(result.map((process) => [process.id, process.state])).toEqual([
    ["chat/a", "killed"],
    ["chat/a", "failed"], // A duplicate in a corrupt list follows the old findIndex behavior.
    ["chat/b", "exited"],
    ["chat/c", "exited"],
    ["chat/d", "running"],
  ]);
  expect(result[1]).toBe(duplicate);
  expect(replayProcessUpdates([old], new Map())).toEqual([old]);
});

test("3,000 historical rows plus 3,000 updates examine each existing ID once", () => {
  let reads = 0;
  const listed: SessionInfoProcess[] = Array.from({ length: 3_000 }, (_, i) => ({
    ...record(`chat/${i}`),
    get id() {
      reads += 1;
      return `chat/${i}`;
    },
  }));
  const pending = new Map<string, SessionInfoProcess>();
  for (let i = 1_500; i < 4_500; i += 1) {
    pending.set(`chat/${i}`, record(`chat/${i}`, "exited"));
  }
  const merged = replayProcessUpdates(listed, pending);
  expect(merged).toHaveLength(4_500);
  expect(merged[0]).toBe(listed[0]);
  expect(merged[1_500]?.state).toBe("exited");
  expect(merged[2_999]?.state).toBe("exited");
  expect(merged[3_000]?.id).toBe("chat/3000");
  expect(merged[4_499]?.id).toBe("chat/4499");
  expect(reads).toBe(3_000);
});
