// A late queue.stale reply may repair only the selection that issued the edit.
import { expect, test } from "bun:test";
import type { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { QueuedPrompt } from "../src/agent-session/acpmux/model";
import { directClientStub } from "./support/directClientStub";

type Client = Pick<AcpmuxDirectClient, "editQueued"> & {
  selectedSessionId: string;
  selectionGeneration: number;
  queue: QueuedPrompt[];
};
const cut = "a long prompt…";
const whole = "a long prompt with the ending that must survive";

for (const selection of ["same", "other", "returned"] as const) {
  test(`a stale edit reply repairs only its original selection: ${selection}`, async () => {
    let reject!: (error: unknown) => void;
    let emits = 0;
    const response = new Promise((_, fail) => {
      reject = fail;
    });
    const client = directClientStub<Client>({
      selectedSessionId: "A",
      selectionGeneration: 1,
      queue: [{ id: "q", prompt: cut }],
      request: () => response,
      emit: () => {
        emits += 1;
      },
    });
    const pending = client.editQueued("q", { op: "update", text: "edited", base: cut });
    if (selection !== "same") {
      client.selectedSessionId = selection === "other" ? "B" : "A";
      client.selectionGeneration = selection === "other" ? 2 : 3;
      client.queue = [{ id: "q", prompt: cut }];
    }
    const before = client.queue;
    reject({ data: { reason: "queue.stale", text: whole } });
    expect(await pending).toEqual({ ok: false });
    if (selection === "same") {
      expect(client.queue[0].prompt).toBe(whole);
      expect(emits).toBe(1);
    } else {
      expect(client.queue).toBe(before);
      expect(client.queue[0].prompt).toBe(cut);
      expect(emits).toBe(0);
    }
  });
}
