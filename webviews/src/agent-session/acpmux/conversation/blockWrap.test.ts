// The form a Shell card and a call's output open in. Leo, 2026-11-04, on a Shell card whose `ps`
// table had every row folded back under itself: "why isn't this just prettified by default?" So
// output opens with each printed line on its own row, columns aligned, and Wrap lines (the card's
// one toggle, blockWrap.ts) is the way back to the folded form. A diff of a code file keeps its
// lines too; prose still wraps.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { blockWrapOf, setBlockWrap } from "./blockWrap";

// A viewer who never touched Wrap lines: a storage of its own, so what another test in this
// process chose (the module keeps the last choice) is not what these read.
const scope = globalThis as { localStorage?: Storage };
let had: PropertyDescriptor | undefined;
beforeEach(() => {
  had = Object.getOwnPropertyDescriptor(scope, "localStorage");
  const store = new Map<string, string>();
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => void store.set(key, value),
      removeItem: (key: string) => void store.delete(key),
    } as unknown as Storage,
  });
});
afterEach(() => {
  if (had) Object.defineProperty(scope, "localStorage", had);
  else delete scope.localStorage;
});

test("a call's output opens aligned, not folded", () => {
  expect(blockWrapOf("output")).toBe(false);
});

test("prose still wraps and code still does not", () => {
  expect({ prose: blockWrapOf("prose"), code: blockWrapOf("code") }).toEqual({ prose: true, code: false });
});

test("Wrap lines flips output to the folded form and back", () => {
  setBlockWrap("output", true);
  expect(blockWrapOf("output")).toBe(true);
  setBlockWrap("output", false);
  expect(blockWrapOf("output")).toBe(false);
});
