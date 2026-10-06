import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vite-plus/test";
import {
  CHIEF_SYSTEM,
  type ChiefEvent,
  cutBytes,
  entryFor,
  type MemoryPort,
  type ModelPort,
  type ModelReply,
  type ModelRequest,
  runTurn,
} from "../src/chief/turn.ts";
import { utf8Length } from "../src/memory/text.ts";
import { MemoryService } from "../src/memory-service.ts";

function memory(wakeLines?: number): { service: MemoryService; port: MemoryPort } {
  const db = new DatabaseSync(":memory:");
  const sql = (q: string, ...p: Array<unknown>) => db.prepare(q).all(...(p as Array<string | number>)) as never;
  const tx = <T>(fn: () => T): T => {
    db.exec("BEGIN");
    try {
      const r = fn();
      db.exec("COMMIT");
      return r;
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  };
  const service = new MemoryService(sql, tx, () => new Date("2026-10-02T12:00:00Z"));
  if (wakeLines) service.memo(["config", `WAKE_LINES=${wakeLines}`]);
  return {
    service,
    port: {
      view: async () => service.view(),
      note: async (texts, key) => service.note(texts, key),
      nap: async (block, text, key) => service.nap(block, text, key),
    },
  };
}

/** Answers compressions with "sum(<ids>)" and turns with a scripted reply; records every request. */
class FakeModel implements ModelPort {
  readonly requests: Array<ModelRequest> = [];
  constructor(private readonly turn: (r: ModelRequest) => ModelReply = () => ({ text: "On it.", spawns: [] })) {}
  async complete(r: ModelRequest): Promise<ModelReply> {
    this.requests.push(r);
    if (!r.tools)
      return { text: `sum(${[...r.user.matchAll(/^ {2}#(\S+)/gm)].map((m) => m[1]).join(",")})`, spawns: [] };
    return this.turn(r);
  }
}

const human = (id: string, text: string): ChiefEvent => ({ id, kind: "human", from: "Lawrence", text });

describe("chief turn", () => {
  it("appends events and the reply, and the model sees only the cover and the new events", async () => {
    const { service, port } = memory();
    const model = new FakeModel(() => ({
      text: "Starting a worker.",
      spawns: [{ name: "fix", prompt: "Fix the bug in X." }],
    }));
    await runTurn("t1", [human("m1", "fix the bug in X")], port, model);
    await runTurn("t2", [human("m2", "what did you start?")], port, model);
    const second = model.requests.filter((r) => r.tools)[1]!;
    expect(second.system).toBe(CHIEF_SYSTEM);
    expect(second.user).toBe(
      [
        "<memory>",
        "#0 2026-10-02 Lawrence: fix the bug in X",
        "#1 2026-10-02 chief: Starting a worker.",
        "#2 2026-10-02 chief spawned fix: Fix the bug in X.",
        "#3 2026-10-02 Lawrence: what did you start?",
        "</memory>",
        "",
        "New since your last turn (already appended to your memory):",
        "",
        "Lawrence says:\nwhat did you start?",
      ].join("\n"),
    );
    expect(service.view().length).toBe(6);
  });

  it("pays the compressions the cover needs before the turn, in order, and spare ones after", async () => {
    const { service, port } = memory(4);
    service.note(["a", "b", "c", "d", "e", "f", "g", "h"]);
    const model = new FakeModel();
    const result = await runTurn("t1", [human("m1", "hi")], port, model);
    const naps = model.requests.filter((r) => !r.tools).map((r) => /#(\d+-\d+) into/.exec(r.user)![1]);
    const turnAt = model.requests.findIndex((r) => r.tools);
    // cover(9, 4) = 0-3, 4-5, 6-7, 8: those first. The reply makes T = 10; spares then go smallest first.
    expect(naps.slice(0, turnAt)).toEqual(["0-1", "2-3", "4-5", "6-7", "0-3"]);
    expect(naps.slice(turnAt)).toEqual(["8-9", "4-7", "0-7"]);
    expect(result.naps).toBe(naps.length);
    expect(model.requests[turnAt]!.user).toContain(
      "<memory>\n#0-3 sum(0,1,2,3)\n#4-5 sum(4,5)\n#6-7 sum(6,7)\n#8 2026-10-02 Lawrence: hi\n</memory>",
    );
  });

  it("writes nothing twice when the same turn runs again after a crash", async () => {
    const { service, port } = memory();
    const events = [human("m1", "hello"), { id: "w1", kind: "worker", from: "fix", text: "done" } as const];
    await runTurn("t1", events, port, new FakeModel());
    const after = service.view().length;
    await runTurn("t1", events, port, new FakeModel(() => ({ text: "A different reply.", spawns: [] })));
    expect(service.view().length).toBe(after);
    expect(service.memo(["recall", "different"]).stdout).toBe("No match.\n");
  });

  it("stores long messages as their first bytes plus a reference", async () => {
    const { service, port } = memory();
    await runTurn("t1", [human("msg_9", "word ".repeat(200))], port, new FakeModel());
    const entry = service.memo(["recall", "msg_9"]).stdout.split("\n")[0]!;
    expect(entry).toMatch(/^#0 2026-10-02 Lawrence: word( word)* \[msg_9\]$/);
    expect(utf8Length(entry.replace(/^#0 2026-10-02 /, ""))).toBeLessThanOrEqual(280);
  });

  it("cuts on character and word boundaries", () => {
    expect(cutBytes("é".repeat(200), 281)).toBe("é".repeat(140));
    expect(cutBytes("alpha beta gamma", 12)).toBe("alpha beta");
    expect(entryFor("a", "short")).toBe("a: short");
    expect(entryFor("a", "x\n\ny")).toBe("a: x y");
  });
});
