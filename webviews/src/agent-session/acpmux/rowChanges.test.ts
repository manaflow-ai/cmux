import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import { markOneRowChange, oneRowChangeFrom } from "./rowChanges";

const row = (id: string, text: string) => ({ id, kind: "assistant", text, version: 1 }) as unknown as AcpmuxRow;

describe("oneRowChangeFrom", () => {
  test("a run of changes to one row is one change from the snapshot before the run", () => {
    const a = [row("x", "a"), row("y", "a")];
    const b = [a[0]!, row("y", "b")];
    const c = [a[0]!, row("y", "c")];
    markOneRowChange(b, a, 1);
    markOneRowChange(c, b, 1);
    expect(oneRowChangeFrom(c, b)).toBe(1);
    expect(oneRowChangeFrom(c, a)).toBe(1);
  });

  test("changes to two rows are not one change", () => {
    const a = [row("x", "a"), row("y", "a")];
    const b = [a[0]!, row("y", "b")];
    const c = [row("x", "c"), b[1]!];
    markOneRowChange(b, a, 1);
    markOneRowChange(c, b, 0);
    expect(oneRowChangeFrom(c, b)).toBe(0);
    expect(oneRowChangeFrom(c, a)).toBeUndefined();
  });
});
