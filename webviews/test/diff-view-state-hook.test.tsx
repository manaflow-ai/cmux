// The diff page's half of a discard: it answers `cmux.diff.viewState`, tells the
// host when it starts or stops holding input a new page would lose (`cmux.diff.input`, which keeps
// the page), and puts a saved state back once the restored diff has arrived: the files the reader
// had unfolded first, then the scroll. On the page host it also saves that state on each hide,
// for a discard whose host could not ask.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { DiffItem } from "../src/diff-stream";
import type { ItemScrollAnchor } from "../src/diff-viewer/item-navigation";
import { DIFF_PAGE, savedDiffView, useDiffViewState, type DiffViewState } from "../src/diff-viewer/viewState";
import type { PageClient, PageHandler } from "../src/pages/shared/pageClient";
import { openPageState } from "../src/pages/shared/pageState";
import { FakePageDom, discardAndRestore } from "../src/pages/shared/pageStateTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "requestAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (run: () => void) => {
      run();
      return 0;
    },
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function fakeClient() {
  const calls: { op: string; params: unknown }[] = [];
  const handlers = new Map<string, PageHandler>();
  const client = {
    async call<R>(op: string, params?: unknown): Promise<R> {
      calls.push({ op, params });
      return null as R;
    },
    async subscribe() {
      return () => {};
    },
    handle(op: string, handler: PageHandler) {
      handlers.set(op, handler);
      return () => handlers.delete(op);
    },
  } satisfies PageClient;
  return { client, calls, handlers };
}

const item = (id: string, collapsed: boolean) => ({ id, type: "diff", collapsed, fileDiff: { name: id } }) as DiffItem;

test("the page reports held input when it changes, answers its state and restores a saved one", async () => {
  const { client, calls, handlers } = fakeClient();
  const unfolded: string[][] = [];
  const scrolled: ItemScrollAnchor[] = [];
  const savedState: DiffViewState = { anchor: { itemId: "b.ts", offset: 64 }, expanded: ["big.lock"], options: {} };
  const items = [item("big.lock", true), item("b.ts", false)];
  const Probe = (props: { unsaved: boolean; ready: boolean }) => {
    useDiffViewState({
      client,
      unsaved: props.unsaved,
      saved: savedState,
      ready: props.ready,
      items,
      capture: () => ({ expanded: ["now"], options: {} }),
      unfold: (ids) => unfolded.push(ids),
      scrollTo: (anchor) => scrolled.push(anchor),
    });
    return null;
  };
  root = createRoot(host);
  act(() => root!.render(<Probe unsaved={false} ready={false} />));
  expect(calls).toEqual([]);
  expect(unfolded).toEqual([]);
  expect(await handlers.get("cmux.diff.viewState")?.(null)).toEqual({ expanded: ["now"], options: {} });

  act(() => root!.render(<Probe unsaved={true} ready={false} />));
  act(() => root!.render(<Probe unsaved={true} ready={false} />));
  expect(calls).toEqual([{ op: "cmux.diff.input", params: { unsaved: true } }]);

  act(() => root!.render(<Probe unsaved={false} ready={true} />));
  expect(calls.at(-1)).toEqual({ op: "cmux.diff.input", params: { unsaved: false } });
  expect(unfolded).toEqual([["big.lock"]]);
  expect(scrolled).toEqual([{ itemId: "b.ts", offset: 64 }]);

  act(() => root!.render(<Probe unsaved={false} ready={true} />));
  expect(unfolded).toHaveLength(1);
  expect(scrolled).toHaveLength(1);
});

test("on the page host the page saves its view each time it hides, and that save comes back after a discard", () => {
  const { client } = fakeClient();
  const before = new FakePageDom("");
  const pageState = openPageState(client, DIFF_PAGE, before);
  const view: DiffViewState = { anchor: { itemId: "a.ts", offset: 120 }, expanded: ["big.lock"], options: {} };
  const Probe = () => {
    useDiffViewState({
      client,
      pageState,
      unsaved: false,
      saved: null,
      ready: false,
      items: [],
      capture: () => view,
      unfold: () => {},
      scrollTo: () => {},
    });
    return null;
  };
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<Probe />));
  const restored = discardAndRestore(before);
  expect(savedDiffView(undefined, openPageState(restored, DIFF_PAGE, new FakePageDom("")))).toEqual(view);
  // The host's own answer to its discard-time ask wins.
  const fromHost = { expanded: [], options: { collapsed: true } };
  expect(savedDiffView(fromHost, openPageState(restored, DIFF_PAGE, new FakePageDom("")))).toEqual(fromHost);
});
