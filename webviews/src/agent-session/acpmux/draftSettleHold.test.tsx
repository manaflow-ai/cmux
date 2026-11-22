// A chat whose draft is already read arms no hold timer: a chat at rest after a switch wakes for nothing
// (Leo, 2026-11-12: "infinite everything feels like nothing"). The hold still ends a draft read that never answers.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { DRAFT_SETTLE_HOLD_MS, useDraftWaitOver } from "./draftSettleHold";

let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  // A global the file added (`document`, `IS_REACT_ACT_ENVIRONMENT`) goes away, not left as undefined.
  await teardownDom(
    [...saved].map(([key, value]) => [key, value !== undefined, value] as const),
    { window: dom?.window, scope },
  );
  saved.clear();
  dom = undefined;
});

function harness() {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>");
  const timers = new Map<number, { at: number; run: () => void }>();
  let now = 0;
  let next = 1;
  let armed = 0;
  const view = dom.window as unknown as Window;
  view.setTimeout = ((run: () => void, ms: number) => {
    armed += 1;
    timers.set(next, { at: now + ms, run });
    return next++;
  }) as unknown as typeof view.setTimeout;
  view.clearTimeout = ((id: number) => void timers.delete(id)) as typeof view.clearTimeout;
  for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: view,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.querySelector("main")!);
  let over: string | undefined;
  function Probe(props: { rows: string | undefined; draft: string | undefined }) {
    over = useDraftWaitOver(props.rows, props.draft);
    return null;
  }
  return {
    render: (rows: string | undefined, draft: string | undefined) =>
      act(() => root!.render(<Probe rows={rows} draft={draft} />)),
    advance: (ms: number) =>
      act(() => {
        now += ms;
        for (const [id, timer] of Array.from(timers)) {
          if (timer.at > now) continue;
          timers.delete(id);
          timer.run();
        }
      }),
    armed: () => armed,
    live: () => timers.size,
    over: () => over,
  };
}

test("a chat whose draft settled before or with its rows arms no hold timer", () => {
  const pane = harness();
  pane.render(undefined, undefined);
  // A switch: the composer read B's draft from memory as B's rows came in.
  pane.render("B", "B");
  pane.advance(DRAFT_SETTLE_HOLD_MS * 3);
  expect(pane.armed()).toBe(0);
  expect(pane.over()).toBeUndefined();
});

test("a draft that settles during the hold clears its timer", () => {
  const pane = harness();
  pane.render("A", undefined);
  expect(pane.live()).toBe(1);
  pane.render("A", "A");
  expect(pane.live()).toBe(0);
  pane.advance(DRAFT_SETTLE_HOLD_MS * 3);
  expect(pane.over()).toBeUndefined();
});

test("a draft read that never answers still ends the wait after DRAFT_SETTLE_HOLD_MS", () => {
  const pane = harness();
  pane.render("A", "earlier");
  pane.advance(DRAFT_SETTLE_HOLD_MS - 1);
  expect(pane.over()).toBeUndefined();
  pane.advance(1);
  expect(pane.over()).toBe("A");
  expect(pane.armed()).toBe(1);
});
