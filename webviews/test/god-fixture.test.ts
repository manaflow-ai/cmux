// The god session (bench/godFixture.ts) is what its header says: the same bytes every run, seq keys acpmux would
// write, MB-sized tool outputs, subagents nested at least four deep, images, months of history, and bursts for the
// replay bench; its rows pair with the ordinary ones by one `god` segment.
import { describe, expect, test } from "bun:test";
import {
  benchFixture,
  godChat,
  godLog,
  LATEST_TEXT,
  pngBase64,
  scaledRowName,
  subagentDepth,
  toJsonLines,
} from "../bench/godFixture";
import { BURST_KINDS, checkSeq, parseLog, rowsIn } from "../bench/replayLogs";

const DAY = 86_400_000;
const god = godLog("god");

const images = (log: typeof god) =>
  log.events.filter((event) => JSON.stringify(event.msg).includes('"type":"image","mimeType":"image/png"')).length;

describe("god fixture", () => {
  test("god: tens of thousands of rows, MB outputs, deep subagents, images, months of history", () => {
    expect(() => checkSeq(god)).not.toThrow();
    expect(rowsIn(god.events)).toBeGreaterThan(30_000);
    const sizes = god.events.map((event) => JSON.stringify(event).length).filter((size) => size > 2 ** 20);
    expect(sizes.length).toBeGreaterThanOrEqual(4);
    expect(Math.max(...sizes)).toBeGreaterThan(4 * 2 ** 20 * 0.95);
    expect(subagentDepth(god.events)).toBeGreaterThanOrEqual(4);
    expect(images(god)).toBeGreaterThan(10);
    expect(god.events.at(-1)!.at - god.events[0]!.at).toBeGreaterThanOrEqual(90 * DAY);
    // Day gaps: some stretch of a day or more with no record.
    const gaps = god.events.slice(1).map((event, index) => event.at - god.events[index]!.at);
    expect(Math.max(...gaps)).toBeGreaterThan(3 * DAY);
    // A burst of every kind at each checkpoint, rows growing.
    for (const kind of BURST_KINDS) {
      const rows = god.bursts.filter((burst) => burst.kind === kind).map((burst) => burst.rows);
      expect(rows.length).toBeGreaterThanOrEqual(5);
      expect(rows.at(-1)!).toBeGreaterThan(rows[0]! + 20_000);
    }
    // The newest reply is the one a bench waits for, and it is there once.
    const latest = god.events.filter((event) => JSON.stringify(event.msg).includes(LATEST_TEXT));
    expect(latest.map((event) => event.seq)).toEqual([god.events.length - 1]);
  });

  test("deterministic: the same bytes every run", () => {
    const again = godLog("small");
    expect(toJsonLines(again)).toBe(toJsonLines(godLog("small")));
    expect(godLog("god").events.length).toBe(god.events.length);
    expect(JSON.stringify(godLog("god").events.slice(-200))).toBe(JSON.stringify(god.events.slice(-200)));
    expect(toJsonLines(godLog("small", { seed: 2 }))).not.toBe(toJsonLines(again));
  });

  test("small is an ordinary chat of the same shape", () => {
    const small = godLog("small");
    expect(() => checkSeq(small)).not.toThrow();
    const rows = rowsIn(small.events);
    expect(rows).toBeGreaterThan(1000);
    expect(rows).toBeLessThan(3000);
    expect(subagentDepth(small.events)).toBe(2);
    expect(images(small)).toBe(1);
    expect(small.events.every((event) => JSON.stringify(event).length < 2 ** 20)).toBe(true);
  });

  test("its JSON lines read back through parseLog, record for record", () => {
    const small = godLog("small");
    const read = parseLog("small.jsonl", toJsonLines(small));
    expect(() => checkSeq(read)).not.toThrow();
    expect(read.sessionId).toBe(small.sessionId);
    expect(read.events).toEqual(small.events);
  });

  test("the chat benches' god chat is keyed to their session", () => {
    const { events, session } = godChat("chat-a", { peer: "vm" });
    expect(events.every((event) => event.sessionId === "chat-a")).toBe(true);
    expect(session).toMatchObject({ sessionId: "chat-a", peer: "vm", lastSeq: events.length, status: "ready" });
  });

  test("images are valid PNGs", () => {
    const bytes = Buffer.from(pngBase64(3), "base64");
    expect([...bytes.subarray(0, 8)]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    expect(bytes.subarray(12, 16).toString()).toBe("IHDR");
    expect(pngBase64(3)).not.toBe(pngBase64(4));
  });

  test("a row's god twin has one `god` segment after the prefix; small keeps its name", () => {
    expect(scaledRowName("chat_open.compact.latest", "small")).toBe("chat_open.compact.latest");
    expect(scaledRowName("chat_open.compact.latest", "god")).toBe("chat_open.god.compact.latest");
    expect(scaledRowName("transcript_replay.long.token_ms", "god")).toBe("transcript_replay.god.long.token_ms");
    for (const name of ["chat_switch.unread.latest", "transcript_replay.open.cls"])
      expect(scaledRowName(name, "god").replace(".god.", ".")).toBe(name);
    expect(benchFixture({})).toBe("small");
    expect(benchFixture({ FIXTURE: "god" })).toBe("god");
    expect(() => benchFixture({ FIXTURE: "huge" })).toThrow("FIXTURE must be small or god");
  });
});
