import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { compileFunction } from "node:vm";
import { act, startTransition, Suspense, useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { placeRowsIndexed, placedFromEstimate, nextDrawnRow, prevDrawnRow, keepsReplyRoom, statusEdge, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { drawnOpenStateHolds } from "../src/agent-session/acpmux/conversation/rowOpenState";
import { LayeredMap } from "../src/agent-session/acpmux/conversation/layeredMap";
import { settleReact } from "./support/domTeardown";

// Exercise the production callback with React's real priority queues, without mounting the
// whole agent pane. In particular, an updater is not interchangeable with its eager result.
const source = readFileSync(
  process.env.CMUX_TEST_DRAWN_SOURCE ?? new URL("../src/agent-session/acpmux/VirtualTranscript.tsx", import.meta.url),
  "utf8",
);
// sameDrawn and changesDrawn, up to the end of changesDrawn's body.
const comparisonStart = source.indexOf("function sameDrawn(");
const comparisonEnd = source.indexOf("\n}\n", source.indexOf("function changesDrawn(")) + 3;
const comparison = source.slice(comparisonStart, comparisonEnd);
// A production callback alone, up to the end of its own dependency list (`}, [...]);`): other
// callbacks (reportRow, placeRowNow) sit between flushDrawn and the observer and need the pane's
// other refs.
function productionCallbackOf(name: string): string {
  const start = source.indexOf(`  const ${name} = useCallback(`);
  if (start < 0) throw new Error(`VirtualTranscript.tsx has no ${name} callback`);
  const end = /\n  \}, \[[^\]]*\]\);\n/g;
  end.lastIndex = start;
  const match = end.exec(source);
  if (!match) throw new Error(`${name} has no end`);
  return source.slice(start, match.index + match[0].length);
}
// flushDrawn asks its update through askDrawn, which notes it in drawnAsk (`setDrawn` here).
const askCallback = productionCallbackOf("askDrawn");
const productionCallback = productionCallbackOf("flushDrawn");
// The mutation run must fail the priority regression: rendered state alone misses queued work.
const callback =
  process.env.CMUX_TEST_NAIVE_DRAWN_GUARD === "1"
    ? productionCallback.replace(
        "    askDrawn((current) => {",
        "    if (!changesDrawn(drawnRef.current, updates)) return;\n    askDrawn((current) => {",
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
/// The drawn heights as the transcript keeps them (conversation/layeredMap.ts).
type Drawn = LayeredMap<Height>;
type Ref<T> = { current: T };
type Inputs = {
  drawnRef: Ref<Drawn>;
  pendingDrawn: Ref<Heights>;
  changedDrawn: Ref<Set<string>>;
  setDrawn: (update: (current: Drawn) => Drawn) => void;
};
const useFlush = compileFunction(
  new Bun.Transpiler({ loader: "ts" }).transformSync(`
${comparison}
function useFlush({ drawnRef, pendingDrawn, changedDrawn, setDrawn }) {
const drawnAsk = useRef({ ran: false });
${askCallback}
${callback}
return flushDrawn;
}`) + "\nreturn useFlush;",
  ["useCallback", "useRef"],
)(useCallback, useRef) as (inputs: Inputs) => () => void;

let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else Object.defineProperty(scope, key, { configurable: true, writable: true, value });
  }
  saved.clear();
});

// Execute production incremental placement with its immutable geometry. This fixture has no
// older/newer pages; history reserve is omitted and placement origin stays zero.
const placementStart = source.indexOf("  const measured = useMemo(() => {");
const placementEnd = source.indexOf("    // Rows that left the top", placementStart);
const publicationStart = source.indexOf("    lastPlaced.current = {", placementEnd);
const publicationEnd = source.indexOf("    return {", publicationStart);
const usePlaced = compileFunction(
  new Bun.Transpiler({ loader: "ts" }).transformSync(`
function usePlaced(rows, drawn, changedDrawn) {
  const lastPlaced = useRef(undefined);
  const registry = useRef({}).current;
  const sessionId = "chat", scaledRowWidth = 600, chatLook = "default", attachmentView = "default";
  const acpmuxPerf = { enabled: false }, DRAWN_SEARCH_ROWS = 256;
  const estimated = useMemo(() => ({ layout: {
    heights: new Float64Array(rows.length).fill(100),
    tops: Float64Array.from(rows, (_, i) => i * 100), totalHeight: rows.length * 100,
  }, partial: false }), [rows]);
  ${source.slice(placementStart, placementEnd)}
    const layout = placed;
  ${source.slice(publicationStart, publicationEnd)}
    return { layout };
  }, [rows, drawn, estimated]);
  return measured.layout;
}`) + "\nreturn usePlaced;",
  ["useRef", "useMemo", "placeRowsIndexed", "placedFromEstimate", "nextDrawnRow", "prevDrawnRow", "keepsReplyRoom", "statusEdge", "drawnOpenStateHolds"],
)(useRef, useMemo, placeRowsIndexed, placedFromEstimate, nextDrawnRow, prevDrawnRow, keepsReplyRoom, statusEdge, drawnOpenStateHolds);

test("an abandoned height render cannot place an urgent appended reply", async () => {
  dom = new JSDOM("<!doctype html><div id='root'></div>");
  for (const [key, value] of Object.entries({window: dom.window, document: dom.window.document,
    navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true})) {
    saved.set(key, scope[key]);
    Object.defineProperty(scope, key, { configurable: true, writable: true, value });
  }
  const a: AcpmuxRow = { id: "a", kind: "assistant", text: "Long answer", version: 1, at: 1 };
  const b: AcpmuxRow = { id: "b", kind: "user", text: "Follow up", version: 1, at: 1 };
  const c: AcpmuxRow = { id: "c", kind: "assistant", text: "Next answer", version: 1, at: 1 };
  const initial = [a, b], appended = [a, b, c];
  const h1: Height = { sessionId: "chat", width: 600, version: 1, height: 150, actions: true };
  let report = (_height: number) => {};
  const renders: { height: number; top: number; count: number }[] = [];
  function Probe({ rows }: { rows: AcpmuxRow[] }) {
    const [drawn, setDrawn] = useState<Drawn>(() => LayeredMap.empty<Height>().with(new Map([["a", h1]])));
    const drawnRef = useRef(drawn);
    drawnRef.current = drawn;
    const pendingDrawn = useRef<Heights>(new Map());
    const changedDrawn = useRef(new Set<string>());
    const flush = useFlush({ drawnRef, pendingDrawn, changedDrawn, setDrawn });
    report = (height) => { pendingDrawn.current = new Map([["a", { ...h1, height }]]); flush(); };
    const layout = usePlaced(rows, drawn, changedDrawn);
    const height = drawn.get("a")!.height, top = layout.geometry.topAt(1);
    renders.push({ height, top, count: rows.length });
    return <div data-height={height} data-next-top={top} />;
  }
  const never = new Promise<never>(() => {});
  function Suspends({ on }: { on: boolean }) { if (on) throw never; return null; }
  function View({ rows, suspend = false }: { rows: AcpmuxRow[]; suspend?: boolean }) {
    return <Suspense fallback="loading"><Probe rows={rows} /><Suspends on={suspend} /></Suspense>;
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<View rows={initial} />));
  expect(dom.window.document.querySelector("[data-next-top]")!.getAttribute("data-next-top")).toBe("150");
  act(() => startTransition(() => { report(100); root!.render(<View rows={initial} suspend />); }));
  expect(renders.some(({ height, top }) => height === 100 && top === 100)).toBe(true);
  expect(dom.window.document.querySelector("[data-height]")!.getAttribute("data-height")).toBe("150");
  act(() => {
    flushSync(() => root!.render(<View rows={appended} />));
    const shown = dom!.window.document.querySelector("[data-height]")!;
    console.log("abandoned-placement", JSON.stringify({ renders, committedHeight: shown.getAttribute("data-height"), committedTop: shown.getAttribute("data-next-top") }));
    expect(shown.getAttribute("data-height")).toBe("150");
    expect(shown.getAttribute("data-next-top")).toBe("150");
  });
});
