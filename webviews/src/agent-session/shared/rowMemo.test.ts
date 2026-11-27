import { describe, expect, test } from "bun:test";
import { RowMemo } from "./rowMemo";

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
