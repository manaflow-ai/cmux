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
            : { key: "claude-code:abc", title: "Claude", createdMs: 1, updatedMs: 5, turns: [turn(5)], before: 100 };
        return page as T;
      }
      const before = params.before;
      if (before === undefined) return { hits: [], before: 200 } as T;
      if (before === 200) return { hits: [], before: 100 } as T;
      return { hits: [{ pageEnd: 100, turn: 0, role: "assistant", snippet: "answer 1" }], before: null } as T;
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
