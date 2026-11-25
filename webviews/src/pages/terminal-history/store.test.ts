import { expect, test } from "bun:test";
import { TerminalHistoryStore } from "./store";
import { TERMINAL_HISTORY_FIND, TERMINAL_HISTORY_PAGE, type TranscriptPage } from "./types";

const turn = (n: number) => ({ prompt: `prompt ${n}`, answer: `answer ${n}`, tools: [] });

test("terminal history finds a distant match across no-hit pages and jumps to its page", async () => {
  const calls: { op: string; params: any }[] = [];
  const provider = {
    async call<T>(op: string, params: any): Promise<T> {
      calls.push({ op, params });
      if (op === TERMINAL_HISTORY_PAGE) {
        const page: TranscriptPage =
          params.before === 100
            ? {
                key: "claude-code:abc",
                title: "Claude",
                createdMs: 1,
                updatedMs: 5,
                turns: [turn(1)],
                before: null,
              }
            : {
                key: "claude-code:abc",
                title: "Claude",
                createdMs: 1,
                updatedMs: 5,
                turns: [turn(5)],
                before: 100,
              };
        return page as T;
      }
      const before = params.before;
      if (before === undefined) return { hits: [], before: 200 } as T;
      if (before === 200) return { hits: [], before: 100 } as T;
      return {
        hits: [{ pageEnd: 100, turn: 0, role: "assistant", snippet: "answer 1" }],
        before: null,
      } as T;
    },
  };
  const store = new TerminalHistoryStore(provider, "claude-code:abc");
  await store.load();
  await store.find("answer 1");
  expect(store.getSnapshot().hits).toHaveLength(1);
  expect(calls.filter((call) => call.op === TERMINAL_HISTORY_FIND)).toHaveLength(3);
  await store.jumpToHit(store.getSnapshot().hits[0]!);
  expect(store.getSnapshot().turns.some((item) => item.answer === "answer 1")).toBe(true);
});

test("a newer find cancels an older search and stale results never replace it", async () => {
  let releaseOld!: () => void;
  const provider = {
    async call<T>(_op: string, params: any, options?: { signal?: AbortSignal }): Promise<T> {
      if (params.query === "old") {
        await new Promise<void>((resolve) => {
          releaseOld = resolve;
          options?.signal?.addEventListener("abort", () => resolve(), { once: true });
        });
        return { hits: [{ pageEnd: 1, turn: 0, role: "user", snippet: "old" }], before: null } as T;
      }
      return { hits: [{ pageEnd: 2, turn: 0, role: "user", snippet: "new" }], before: null } as T;
    },
  };
  const store = new TerminalHistoryStore(provider, "codex:xyz");
  const old = store.find("old");
  await store.find("new");
  releaseOld?.();
  await old;
  expect(store.getSnapshot().query).toBe("new");
  expect(store.getSnapshot().hits[0]?.snippet).toBe("new");
});

test("the initial page walks past empty cursors before presenting the latest turn", async () => {
  const seen: (number | undefined)[] = [];
  const provider = {
    async call<T>(_op: string, params: any): Promise<T> {
      seen.push(params.before);
      if (params.before === undefined) return { title: "Claude", turns: [], before: 90, pageEnd: 100 } as T;
      return { title: "Claude", turns: [turn(9)], before: null, pageEnd: 90 } as T;
    },
  };
  const store = new TerminalHistoryStore(provider, "claude-code:empty-page");
  await store.load();
  expect(seen).toEqual([undefined, 90]);
  expect(store.getSnapshot().turns.map((item) => item.prompt)).toEqual(["prompt 9"]);
});

test("loading older history skips empty pages and keeps the latest page available", async () => {
  const provider = {
    async call<T>(_op: string, params: any): Promise<T> {
      if (params.before === undefined) return { turns: [turn(9)], before: 100, pageEnd: 200 } as T;
      if (params.before === 100) return { turns: [], before: 50, pageEnd: 100 } as T;
      return { turns: [turn(1)], before: null, pageEnd: 50 } as T;
    },
  };
  const store = new TerminalHistoryStore(provider, "claude-code:empty-older");
  await store.load();
  await store.loadOlder();
  expect(store.getSnapshot().turns.map((item) => item.prompt)).toEqual(["prompt 1", "prompt 9"]);
  expect(store.getSnapshot().before).toBeNull();
});

test("continuing a common search preserves the entire last RPC batch and reaches older matches", async () => {
  const hits = (pageEnd: number, count: number) =>
    Array.from({ length: count }, (_, turn) => ({
      role: "user",
      pageEnd,
      turn,
      snippet: String(turn),
    }));
  const store = new TerminalHistoryStore(
    {
      async call<T>(_op: string, params: any): Promise<T> {
        if (params.before === undefined) return { hits: hits(300, 110), before: 200, completeThrough: 350 } as T;
        expect(params.completeThrough).toBe(350);
        if (params.before === 200) return { hits: hits(200, 30), before: 100 } as T;
        return { hits: hits(100, 1), before: null } as T;
      },
    },
    "claude-code:common",
  );
  await store.find("a");
  expect(store.getSnapshot().hits).toHaveLength(140);
  expect(store.getSnapshot().searchBefore).toBe(100);
  await store.continueFind();
  expect(store.getSnapshot().hits.map((hit) => hit.pageEnd)).toEqual([100]);
  expect(store.getSnapshot().searchComplete).toBe(true);
});
