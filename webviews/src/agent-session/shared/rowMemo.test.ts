import { describe, expect, test } from "bun:test";
import { dropRowMemosWhenHidden, HIDDEN_ROW_MEMO_LIMIT, RowMemo, ROW_MEMO_LIMIT } from "./rowMemo";

describe("RowMemo", () => {
  test("keeps a value until two retirements pass it unread", () => {
    const memo = new RowMemo<object, number>(2);
    const a = {};
    memo.set(a, 1);
    memo.set({}, 2); // retires: a is old
    expect(memo.get(a)).toBe(1); // read from old: back in young
    memo.set({}, 3); // retires again: a is old
    memo.set({}, 4);
    memo.set({}, 5); // a passed two retirements unread
    expect(memo.has(a)).toBe(false);
  });

  test("read computes once while the key stays", () => {
    const memo = new RowMemo<object, boolean | null>(4);
    const a = {};
    let calls = 0;
    const compute = () => (calls++, null);
    expect(memo.read(a, compute)).toBe(null);
    expect(memo.read(a, compute)).toBe(null);
    expect(calls).toBe(1);
  });

  test("an undefined value counts as held", () => {
    const memo = new RowMemo<object, undefined>(4);
    const a = {};
    memo.set(a, undefined);
    expect(memo.has(a)).toBe(true);
    let calls = 0;
    memo.read(a, () => void calls++);
    expect(calls).toBe(0);
  });
});

// Behind `hidden-measure-caches` (cmuxterm-hq goals/chats-flat-at-any-length.md): the dropped arm
// retires a table every HIDDEN_ROW_MEMO_LIMIT writes and clears every memo when the page hides.
describe("RowMemo on the hidden-measure-caches arms", () => {
  const withArm = (arm: string | undefined, run: () => void) => {
    const had = "cmuxExperiments" in globalThis;
    const before = globalThis.cmuxExperiments;
    try {
      globalThis.cmuxExperiments = arm === undefined ? undefined : { "hidden-measure-caches": arm };
      run();
    } finally {
      if (had) globalThis.cmuxExperiments = before;
      else delete globalThis.cmuxExperiments;
    }
  };
  const retiresBy = (writes: number) => {
    const memo = new RowMemo<object, number>();
    const first = {};
    memo.set(first, 0);
    for (let i = 1; i < writes; i += 1) memo.set({}, i);
    // Two retirements past the first key's write drop it.
    for (let i = 0; i < writes; i += 1) memo.set({}, i);
    return !memo.has(first);
  };

  test("the default arm keeps ROW_MEMO_LIMIT and its tables when hidden", () =>
    withArm(undefined, () => {
      expect(retiresBy(HIDDEN_ROW_MEMO_LIMIT)).toBe(false);
      expect(retiresBy(ROW_MEMO_LIMIT)).toBe(true);
      const memo = new RowMemo<object, number>(4);
      const key = {};
      memo.set(key, 1);
      expect(dropRowMemosWhenHidden({ visibilityState: "hidden" })).toBe(false);
      expect(memo.get(key)).toBe(1);
    }));

  test("the dropped arm retires sooner and clears on hide only", () =>
    withArm("dropped", () => {
      expect(retiresBy(HIDDEN_ROW_MEMO_LIMIT)).toBe(true);
      const memo = new RowMemo<object, number>(4);
      const key = {};
      memo.set(key, 1);
      expect(dropRowMemosWhenHidden({ visibilityState: "visible" })).toBe(false);
      expect(memo.get(key)).toBe(1);
      expect(dropRowMemosWhenHidden({ visibilityState: "hidden" })).toBe(true);
      expect(memo.has(key)).toBe(false);
    }));
});
