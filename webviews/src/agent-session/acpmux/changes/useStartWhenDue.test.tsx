import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const saved = { window: globals.window, document: globals.document, act: globals.IS_REACT_ACT_ENVIRONMENT };
Object.assign(globals, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
afterAll(() => {
  Object.assign(globals, { window: saved.window, document: saved.document, IS_REACT_ACT_ENVIRONMENT: saved.act });
});

const { act, createElement, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useStartWhenDue } = await import("./useStartWhenDue");

test("start runs once each time due turns true, and not while it stays false", async () => {
  const starts: number[] = [];
  let setNeed: (value: boolean) => void = () => {};
  let rerender: () => void = () => {};
  function Probe() {
    const [need, setNeedState] = useState(true);
    const [, bump] = useState(0);
    setNeed = setNeedState;
    rerender = () => bump((n) => n + 1);
    // `start` clears the need, as a list that moves to loading does.
    useStartWhenDue(need, () => {
      starts.push(starts.length);
      setNeedState(false);
    });
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(createElement(Probe)));
  expect(starts.length).toBe(1);
  await act(async () => rerender());
  expect(starts.length).toBe(1);
  await act(async () => setNeed(true));
  expect(starts.length).toBe(2);
  await act(async () => root.unmount());
});
