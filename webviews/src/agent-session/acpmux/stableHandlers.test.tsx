import { afterAll, beforeAll, expect, test } from "bun:test";
import { act, memo } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useStableHandlers } from "./stableHandlers";
import { teardownDom } from "../../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>");
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Props = { label: string; onPick?: (value: number) => number; render?: () => string };
let renders = 0;
let picked: Props["onPick"];
const Child = memo(function Child(props: Props) {
  renders++;
  picked = props.onPick;
  return null;
});
function Parent(props: Props) {
  return <Child {...useStableHandlers(props)} />;
}

test("a parent's new handler draws a memoized child no more, and calls the latest one", () => {
  const root = createRoot(document.getElementById("root")!);
  act(() => root.render(<Parent label="a" onPick={(value) => value + 1} />));
  act(() => root.render(<Parent label="a" onPick={(value) => value + 2} />));
  expect(renders).toBe(1);
  expect(picked?.(1)).toBe(3);
  // Another value draws it; a handler that goes away and comes back is told apart.
  act(() => root.render(<Parent label="b" onPick={(value) => value + 2} />));
  expect(renders).toBe(2);
  act(() => root.render(<Parent label="b" />));
  expect(renders).toBe(3);
  expect(picked).toBeUndefined();
  // A function prop not named on* passes as it is.
  const render = () => "x";
  act(() => root.render(<Parent label="b" render={render} />));
  act(() => root.render(<Parent label="b" render={() => "y"} />));
  expect(renders).toBe(5);
  act(() => root.unmount());
});
