import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { compileFunction } from "node:vm";
import { act, startTransition, useCallback, useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

// Exercise the production callback with React's real priority queues, without mounting the
// whole agent pane. In particular, an updater is not interchangeable with its eager result.
const source = readFileSync(
  process.env.CMUX_TEST_DRAWN_SOURCE ?? new URL("../src/agent-session/acpmux/VirtualTranscript.tsx", import.meta.url),
  "utf8",
);
const comparison = source.slice(source.indexOf("function sameDrawn("), source.indexOf("/// RowFrame redraws"));
// flushDrawn alone, up to its own `}, []);`: other callbacks (reportRow, placeRowNow) sit between it and
// the observer and need the pane's other refs.
const flushStart = source.indexOf("  const flushDrawn = useCallback(");
const flushEnd = "\n  }, []);\n";
const productionCallback = source.slice(flushStart, source.indexOf(flushEnd, flushStart) + flushEnd.length);
// The mutation run must fail the priority regression: rendered state alone misses queued work.
const callback =
  process.env.CMUX_TEST_NAIVE_DRAWN_GUARD === "1"
    ? productionCallback.replace(
        "    setDrawn((current) => {",
        "    if (!changesDrawn(drawnRef.current, updates)) return;\n    setDrawn((current) => {",
      )
    : productionCallback;
type Height = {
  sessionId: string;
  version: number;
  width: number;
  height: number;
  actions?: boolean;
  status?: string;
};
type Heights = Map<string, Height>;
type Ref<T> = { current: T };
type Inputs = {
  drawnRef: Ref<Heights>;
  pendingDrawn: Ref<Heights>;
  changedDrawn: Ref<Set<string>>;
  setDrawn: (update: (current: Heights) => Heights) => void;
};
const useFlush = compileFunction(
  new Bun.Transpiler({ loader: "ts" }).transformSync(`
${comparison}
function useFlush({ drawnRef, pendingDrawn, changedDrawn, setDrawn }) {
${callback}
return flushDrawn;
}`) + "\nreturn useFlush;",
  ["useCallback"],
)(useCallback) as (inputs: Inputs) => () => void;

let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else Object.defineProperty(scope, key, { configurable: true, writable: true, value });
  }
  saved.clear();
});

async function setup() {
  dom = new JSDOM("<!doctype html><div id='root'></div>");
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    Object.defineProperty(scope, key, { configurable: true, writable: true, value });
  }
  const h1: Height = { sessionId: "chat", version: 1, width: 600, height: 100 };
  const control = {
    calls: 0,
    renders: 0,
    painted: [] as number[],
    dirty: new Set<string>(),
    report: (_entries: Heights) => {},
    tick: () => {},
  };
  function Probe() {
    control.renders += 1;
    const [drawn, setDrawn] = useState<Heights>(
      () =>
        new Map([
          ["row", h1],
          ["unchanged", h1],
        ]),
    );
    const [, setTick] = useState(0);
    const drawnRef = useRef(drawn);
    drawnRef.current = drawn;
    const pendingDrawn = useRef<Heights>(new Map());
    const changedDrawn = useRef(control.dirty);
    const flush = useFlush({
      drawnRef,
      pendingDrawn,
      changedDrawn,
      setDrawn: (update) => {
        control.calls += 1;
        setDrawn(update);
      },
    });
    control.report = (entries) => {
      pendingDrawn.current = entries;
      flush();
    };
    control.tick = () => setTick((value) => value + 1);
    useLayoutEffect(() => {
      control.painted.push(drawn.get("row")!.height);
    });
    return <div data-height={drawn.get("row")!.height} />;
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root!.render(<Probe />));
  return { control, h1 };
}

test("an equal correction supersedes a queued lower-priority height", async () => {
  const { control, h1 } = await setup();
  await act(async () => {
    startTransition(() => control.report(new Map([["row", { ...h1, height: 200 }]])));
    flushSync(() => {
      control.tick();
      control.report(new Map([["row", { ...h1 }]]));
    });
    expect(dom!.window.document.querySelector("[data-height]")!.getAttribute("data-height")).toBe("100");
  });
  expect(dom!.window.document.querySelector("[data-height]")!.getAttribute("data-height")).toBe("100");
  expect(control.painted).not.toContain(200);
});

test("idle equal-height confirmations leave no dirty placement IDs", async () => {
  const { control, h1 } = await setup();
  const before = control.renders;
  let dirtyIds = 0;
  for (let tick = 0; tick < 120; tick += 1) {
    await act(async () => control.report(new Map([["row", { ...h1 }]])));
    dirtyIds += control.dirty.size;
    control.dirty.clear();
  }
  console.log(
    `drawn-height idle confirmations: ${JSON.stringify({ ticks: 120, setDrawn: control.calls, renders: control.renders - before, dirtyIds })}`,
  );
  // Keep the updater: an equal entry may supersede an update queued at another priority.
  expect(control.calls).toBe(120);
  expect(dirtyIds).toBe(0);
  expect(control.renders).toBe(before);
  expect([...control.dirty]).toEqual([]);
});

test("a mixed batch dirties only changed rows and applies fractional corrections", async () => {
  const { control, h1 } = await setup();
  await act(async () => {
    flushSync(() =>
      control.report(
        new Map([
          ["row", { ...h1, height: 100.25 }],
          ["unchanged", { ...h1 }],
        ]),
      ),
    );
    expect(dom!.window.document.querySelector("[data-height]")!.getAttribute("data-height")).toBe("100.25");
  });
  expect([...control.dirty]).toEqual(["row"]);
});
