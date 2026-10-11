import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vite-plus/test";
import { dateIn, MemoryService } from "../src/memory-service.ts";

function open(db = new DatabaseSync(":memory:"), now = () => new Date("2026-10-02T23:30:00Z")) {
  const sql = (q: string, ...p: Array<unknown>) => db.prepare(q).all(...(p as Array<string | number>)) as never;
  const transaction = <T>(fn: () => T): T => {
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
  return { db, service: new MemoryService(sql, transaction, now) };
}

describe("MemoryService", () => {
  it("dates entries in the chief's time zone", () => {
    const { service } = open();
    expect(service.note(["utc entry"])).toEqual({ first: 0, count: 1 });
    service.setTimeZone("America/Los_Angeles");
    service.note(["pacific entry"]);
    expect(service.memo(["recall", "entry"]).stdout).toBe(
      "#0 2026-10-02 utc entry\n#1 2026-10-02 pacific entry\n2 matches.\n",
    );
    service.setTimeZone("Asia/Tokyo");
    service.note(["tokyo entry"]);
    expect(service.memo(["zoom", "2-3"]).stdout).toBe("#2 2026-10-03 tokyo entry\n");
    expect(() => service.setTimeZone("Mars/Base")).toThrow(RangeError);
  });

  it("answers a retried keyed write with the first result and writes once", () => {
    const { service } = open();
    const first = service.note(["a", "b"], "turn:1");
    expect(service.note(["a", "b"], "turn:1")).toEqual(first);
    expect(service.memo(["note", "c"], { key: "n:1" }).stdout).toContain("Saved as #2.");
    expect(service.memo(["note", "c"], { key: "n:1" }).stdout).toContain("Saved as #2.");
    expect(service.view().length).toBe(3);
  });

  it("refuses a batch with one bad line and keeps nothing of it", () => {
    const { service } = open();
    expect(service.note(["ok", "two\nlines"])).toEqual({
      error: "2 lines. A memory is one line: merge them, or note them separately.",
    });
    expect(service.view().length).toBe(0);
  });

  it("rolls back and re-reads its length when a write throws", () => {
    const { db, service } = open();
    db.exec(
      "CREATE TRIGGER boom BEFORE INSERT ON mem_entry WHEN NEW.text = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END",
    );
    service.note(["a"]);
    expect(() => service.note(["b", "boom"])).toThrow(/boom/);
    expect(service.view().length).toBe(1);
    expect(service.note(["c"])).toEqual({ first: 1, count: 1 });
  });

  it("shows the cover, or the block that must be compressed first, with the next nap", () => {
    const { service } = open();
    service.memo(["config", "WAKE_LINES=3"]);
    service.note(["a", "b", "c", "d"]);
    const view = service.view();
    expect(view.missing).toBe("0-1");
    expect(view.nap?.block).toBe("0-1");
    expect(view.nap?.prompt).toContain("Compress memories #0-1 into one line");
    service.nap("0-1", "a and b");
    expect(service.view()).toMatchObject({ length: 4, lines: ["#0-1 a and b", "#2 2026-10-02 c", "#3 2026-10-02 d"] });
  });

  it("keeps its state across reopen (a Durable Object restart)", () => {
    const { db, service } = open();
    service.note(["persisted"]);
    service.setTimeZone("Europe/Paris");
    const again = open(db).service;
    expect(again.view().length).toBe(1);
    expect(again.timeZone()).toBe("Europe/Paris");
  });

  it("formats dates per zone", () => {
    expect(dateIn("UTC", new Date("2026-12-31T23:59:59Z"))).toBe("2026-12-31");
    expect(dateIn("Pacific/Kiritimati", new Date("2026-12-31T23:59:59Z"))).toBe("2027-01-01");
  });
});
