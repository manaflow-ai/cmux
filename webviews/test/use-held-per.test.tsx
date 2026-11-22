// useHeldPer (acpmux/useHeldPer.ts) holds one value per key as a `useMemo` with `[key]` would, and like
// one keeps only what a committed render computed: a render React throws away leaves no trace.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, startTransition, Suspense } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

test("the same key keeps its value, a new key computes again, and a thrown-away render leaves no trace", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useHeldPer } = await import("../src/agent-session/acpmux/useHeldPer");
  const computed: { key: string; rows: number }[] = [];
  const shown: { key: string; rows: number }[] = [];
  const never = new Promise<never>(() => {});
  function Hold({ k, rows }: { k: string; rows: number }) {
    const value = useHeldPer(k, () => {
      const made = { key: k, rows };
      computed.push(made);
      return made;
    });
    shown.push(value);
    return null;
  }
  function Suspends({ on }: { on: boolean }): null {
    if (on) throw never;
    return null;
  }
  function View({ k, rows, suspend = false }: { k: string; rows: number; suspend?: boolean }) {
    return (
      <Suspense fallback="loading">
        <Hold k={k} rows={rows} />
        <Suspends on={suspend} />
      </Suspense>
    );
  }
  root = createRoot(host);

  act(() => root!.render(<View k="a" rows={1} />));
  const first = shown.at(-1)!;
  expect(first).toEqual({ key: "a", rows: 1 });

  // Same key, other inputs: the committed value, same object.
  act(() => root!.render(<View k="a" rows={2} />));
  expect(shown.at(-1)).toBe(first);
  expect(computed.length).toBe(1);

  // A new key computes again.
  act(() => root!.render(<View k="b" rows={3} />));
  const second = shown.at(-1)!;
  expect(second).toEqual({ key: "b", rows: 3 });
  expect(computed.length).toBe(2);

  // A transition to key "c" suspends: its render computes a value and never commits.
  act(() => startTransition(() => root!.render(<View k="c" rows={4} suspend />)));
  const thrownAway = computed.find((value) => value.key === "c");
  expect(thrownAway).toEqual({ key: "c", rows: 4 });
  expect(host.textContent).not.toBe("loading");

  // Key "c" again, committed now: computed from this render's inputs, not the thrown-away one's.
  act(() => root!.render(<View k="c" rows={5} />));
  const third = shown.at(-1)!;
  expect(third).toEqual({ key: "c", rows: 5 });
  expect(third).not.toBe(thrownAway);

  // And that committed value is the one the key keeps.
  act(() => root!.render(<View k="c" rows={6} />));
  expect(shown.at(-1)).toBe(third);
});
