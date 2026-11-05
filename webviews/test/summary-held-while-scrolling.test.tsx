// The right-hand card holds what it shows while the reader scrolls (summary/heldWhileScrolling.ts;
// Leo, 2026-10-25: "session summary on top right flickers when im scrolling thru the chat"). A
// hundred scroll events notify the card twice (on, then off once the scroll settles), and older
// history that pages in under the scroll reaches the card once, after it settles.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act, Profiler } from "react";
import type { Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  HOLD_SETTLE_MS,
  ReaderScroll,
  useHeldWhileScrolling,
} from "../src/agent-session/acpmux/summary/heldWhileScrolling";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// A hand-run clock: `run()` fires the timer that is due.
function manualClock() {
  let next: { callback: () => void; handle: number } | undefined;
  let handles = 0;
  return {
    setTimer: (callback: () => void) => {
      next = { callback, handle: ++handles };
      return next.handle;
    },
    clearTimer: (handle: unknown) => {
      if (next?.handle === handle) next = undefined;
    },
    run: () => {
      const due = next;
      next = undefined;
      due?.callback();
    },
    get armed() {
      return next !== undefined;
    },
  };
}

test("a gesture's scroll events notify twice: on, then off when it settles", () => {
  const clock = manualClock();
  const flag = new ReaderScroll(clock, HOLD_SETTLE_MS);
  let notified = 0;
  const stop = flag.subscribe(() => notified++);
  for (let event = 0; event < 100; event++) flag.scrolled();
  expect({ scrolling: flag.read(), notified, armed: clock.armed }).toEqual({
    scrolling: true,
    notified: 1,
    armed: true,
  });
  clock.run();
  expect({ scrolling: flag.read(), notified, armed: clock.armed }).toEqual({
    scrolling: false,
    notified: 2,
    armed: false,
  });
  // Released by the page (another chat) before it settles: off at once, the timer cleared.
  flag.scrolled();
  flag.release();
  expect({ scrolling: flag.read(), notified, armed: clock.armed }).toEqual({
    scrolling: false,
    notified: 4,
    armed: false,
  });
  stop();
});

test("the card renders no more while history pages in under a 100-event scroll, and takes it once after", async () => {
  const { createRoot } = await import("react-dom/client");
  const clock = manualClock();
  const flag = new ReaderScroll(clock, HOLD_SETTLE_MS);
  let renders = 0;
  const shown: string[][] = [];

  // Stands in for the card: memoized on the rows it is handed, as SummaryCard's derived state is.
  function Card({ rows }: { rows: string[] }) {
    shown.push(rows);
    return <span>{rows.join(",")}</span>;
  }
  function Pane({ rows, chat }: { rows: string[]; chat: string }) {
    const held = useHeldWhileScrolling(rows, chat, flag);
    return (
      <Profiler id="card" onRender={() => renders++}>
        <Card rows={held} />
      </Profiler>
    );
  }

  let rows = ["r40", "r41"];
  root = createRoot(host);
  act(() => root!.render(<Pane rows={rows} chat="a" />));
  const before = renders;
  // 100 scroll frames; every tenth, a page of older history lands (a new rows array).
  for (let frame = 0; frame < 100; frame++) {
    act(() => flag.scrolled());
    if (frame % 10 === 9) {
      rows = [`r${39 - frame}`, ...rows];
      act(() => root!.render(<Pane rows={rows} chat="a" />));
    }
  }
  // The pane rendered on each page (its parent re-rendered); the card was handed the same rows
  // each time, so it showed what it showed when the scroll began.
  expect(shown.every((value) => value === shown[0])).toBe(true);
  expect(host.textContent).toBe("r40,r41");
  const during = renders - before;
  act(() => clock.run());
  expect(host.textContent).toBe(rows.join(","));
  expect(shown.at(-1)).toBe(rows);
  console.log(
    `card renders: during the scroll ${during} (10 parent renders, the card handed the same rows), on settle ${renders - before - during}`,
  );

  // Another chat takes its rows at once, scrolling or not.
  act(() => flag.scrolled());
  act(() => root!.render(<Pane rows={["b1"]} chat="b" />));
  expect(host.textContent).toBe("b1");
});

test("subagent-scoped Session Info holds its rows; another subagent takes its own at once", async () => {
  // App.tsx holds `snapshot.subagentViews[shown]` keyed by chat and subagent (cmux#29639), as it
  // holds the chat's rows for the session card.
  const { createRoot } = await import("react-dom/client");
  const clock = manualClock();
  const flag = new ReaderScroll(clock, HOLD_SETTLE_MS);
  function Scoped({ rows, chat, subagent }: { rows: string[] | undefined; chat: string; subagent: string }) {
    const held = useHeldWhileScrolling(rows, `${chat}\u0000${subagent}`, flag);
    return <span>{(held ?? []).join(",")}</span>;
  }
  root = createRoot(host);
  act(() => root!.render(<Scoped rows={["s5"]} chat="a" subagent="one" />));
  act(() => flag.scrolled());
  // Older history of the subagent pages in under the reader's scroll: Session Info keeps its rows.
  act(() => root!.render(<Scoped rows={["s4", "s5"]} chat="a" subagent="one" />));
  expect(host.textContent).toBe("s5");
  act(() => clock.run());
  expect(host.textContent).toBe("s4,s5");
  // Another subagent of the same chat, mid-scroll: its own rows at once.
  act(() => flag.scrolled());
  act(() => root!.render(<Scoped rows={["t1"]} chat="a" subagent="two" />));
  expect(host.textContent).toBe("t1");
});
