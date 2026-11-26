import { expect, test } from "bun:test";
import { TerminalHistoryStore } from "./store";
import { TERMINAL_HISTORY_FIND, type TranscriptHit, type TranscriptProvider } from "./types";

test("a completed oversized record is folded, searchable and read only at the requested offset", async () => {
  const calls: Record<string, unknown>[] = [];
  const range = { start: 32, end: 96, position: "after" as const };
  const hit: TranscriptHit = {
    role: "raw",
    pageEnd: 96,
    rawStart: 32,
    rawEnd: 96,
    rawOffset: 72,
    completeThrough: 128,
    snippet: "needle",
  };
  const provider: TranscriptProvider = {
    async call<T>(op: string, params: unknown): Promise<T> {
      const request = params as Record<string, unknown>;
      calls.push(request);
      if (op === TERMINAL_HISTORY_FIND) return { hits: [hit], before: null } as T;
      if (request.rawStart !== undefined) return { text: "needle", nextOffset: null } as T;
      if (request.before === 96)
        return {
          turns: [],
          rawRanges: [range],
          pageEnd: 96,
          before: 32,
          completeThrough: 128,
        } as T;
      return {
        turns: [{ prompt: "latest", answer: "", tools: [] }],
        pageEnd: 128,
        before: 96,
        completeThrough: 128,
      } as T;
    },
  };
  const store = new TerminalHistoryStore(provider, "claude-code:test");
  await store.load();
  await store.find("needle");
  await store.jumpToHit(hit);
  const section = store.getSnapshot().turns[0]?.raw;
  expect(section).toEqual({ ...range, pageEnd: 96, completeThrough: 128 });
  expect(calls.some((call) => "rawOffset" in call)).toBe(false);
  expect(await store.readRaw(section!, 72)).toEqual({ text: "needle", nextOffset: null });
  expect(calls.at(-1)).toMatchObject({
    before: 96,
    rawStart: 32,
    rawEnd: 96,
    rawOffset: 72,
    completeThrough: 128,
  });
});
