// The row the transcript names to the client as the oldest in view (`onKeepFrom`, direct.ts `setKeepFrom`) is the
// current render's, whatever turns following on: opening a chat, switching to another, or a send while scrolled up.
// The client sheds its oldest records while the view follows, never above that row, so a row from the chat before the
// switch (one the client holds under no id) or one picked from the last render's layout let the next shed cut rows
// on screen (#46511 review: `keepFromNow` was refreshed in a layout effect declared after the placement pass and the
// send effect, which call `follow(true, ...)` and read it first).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";
import { settleReact } from "./support/domTeardown";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
dom.window.document.documentElement.dataset.agentMotion = "off";
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport over a long conversation, and a scroll offset the test moves.
const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (name: string, count: number) =>
  turnView(
    Array.from({ length: count }, (_, index) => [
      row(`${name}${index}-user`, "user", `Question ${index}`),
      row(`${name}${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
      { ...row(`${name}${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
    ]).flat(),
    new Set(),
  );
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

type Told = { id: string | null; rows: readonly AcpmuxRow[] };

/// Renders the transcript with a client stand-in that records each row it is told to keep from, with the rows the
/// transcript was rendering when it said so.
function mount() {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const told: Told[] = [];
  const following: boolean[] = [];
  let current: readonly AcpmuxRow[] = [];
  const render = (props: { sessionId: string; rows: AcpmuxRow[]; sends?: number }) => {
    current = props.rows;
    return act(async () =>
      root.render(
        <VirtualTranscript
          sessionId={props.sessionId}
          rows={props.rows}
          sends={props.sends ?? 0}
          onToggleActivity={() => {}}
          expanded={new Set()}
          onFollowingChange={(next) => following.push(next)}
          onKeepFrom={(id) => told.push({ id, rows: current })}
        />,
      ),
    );
  };
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  /// The reader wheels up a screen: following ends, and the client is told to keep nothing.
  const scrollUp = () =>
    act(async () => {
      const node = scroller();
      node.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -120, bubbles: true }));
      node.scrollTop = scrollerEnd(node) - VIEWPORT;
      node.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
  /// The rows in view now, by where the transcript's layout places them (each row's `top`; jsdom draws no height, so
  /// a row reaches down to the next row's top, and the last to the content's end).
  const inView = () => {
    const node = scroller();
    const top = node.scrollTop;
    const placed = [...node.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)]
      .map((element) => ({ id: element.dataset.rowId!, at: parseFloat(element.style.top) }))
      .filter((entry) => Number.isFinite(entry.at))
      .sort((a, b) => a.at - b.at);
    return placed
      .filter((entry, index) => {
        const end = placed[index + 1]?.at ?? node.scrollHeight;
        return entry.at < top + VIEWPORT && end > top;
      })
      .map((entry) => entry.id);
  };
  return { root, told, following, render, scrollUp, scroller, inView };
}

/// Every row named since `from` is one of the rows being rendered when it was named, and the last is in the chat
/// now; none is null while the view follows (a null keeps nothing, and the count alone sheds the rows on screen).
function expectCurrent(told: Told[], from: number, rows: readonly AcpmuxRow[]) {
  const named = told.slice(from);
  const ids = new Set(rows.map((entry) => entry.id));
  expect(named.length, "the client was told a row to keep from").toBeGreaterThan(0);
  expect(
    named.filter((entry) => entry.id === null || !ids.has(entry.id)).map((entry) => entry.id),
    "rows named that the chat on screen does not hold",
  ).toEqual([]);
  // Each one is the render's own: a row the rows being rendered then held.
  expect(
    named
      .filter((entry) => entry.id !== null && !entry.rows.some((each) => each.id === entry.id))
      .map((entry) => entry.id),
    "rows named from another render's rows",
  ).toEqual([]);
}

test("opening a chat names one of its own rows, at its latest row", async () => {
  const { root, told, render } = mount();
  try {
    const rows = chat("open", 30);
    await render({ sessionId: "open", rows });
    await act(async () => nextFrame());
    expectCurrent(told, 0, rows);
    // The row named is the one at the top of the view at the latest row.
    const ids = rows.map((entry) => entry.id);
    expect(ids.indexOf(told.at(-1)!.id!), "a row near the latest, not the first").toBeGreaterThan(ids.length / 2);
  } finally {
    await act(async () => root.unmount());
  }
});

test("switching from a chat scrolled up names a row of the chat switched to, never one of the chat left", async () => {
  const { root, told, following, render, scrollUp, inView } = mount();
  try {
    await render({ sessionId: "left", rows: chat("left", 30) });
    await act(async () => nextFrame());
    await scrollUp();
    expect(following.at(-1), "the reader scrolled up in the chat left").toBe(false);
    const from = told.length;
    const rows = chat("next", 30);
    await render({ sessionId: "next", rows });
    await act(async () => nextFrame());
    expect(following.at(-1), "the chat switched to opens at its latest row").toBe(true);
    expectCurrent(told, from, rows);
    expect(told.at(-1)!.id, "the row named last is the first in view").toBe(inView()[0]!);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a send while scrolled up names the row in view at the new latest row, from the render that sent", async () => {
  const { root, told, following, render, scrollUp, inView } = mount();
  try {
    const before = chat("sent", 30);
    await render({ sessionId: "sent", rows: before });
    await act(async () => nextFrame());
    await scrollUp();
    expect(following.at(-1)).toBe(false);
    const from = told.length;
    // The send's commit brings the prompt's row and the reply's first, as a host that answers at once does.
    const rows = [
      ...before,
      ...turnView(
        [
          row("prompt-user", "user", "Build it"),
          row("prompt-answer", "assistant", "Building.\n\nA second paragraph.\n\nAnd a third, so the turn is tall."),
        ],
        new Set(),
      ),
    ];
    await render({ sessionId: "sent", rows, sends: 1 });
    await act(async () => nextFrame());
    expect(following.at(-1), "the send follows the latest row").toBe(true);
    expectCurrent(told, from, rows);
    // Each row named since the send is the one the view keeps now: no row from the layout before the send.
    const settled = told.at(-1)!.id;
    expect(settled, "the row named is the first in view").toBe(inView()[0]!);
    expect(
      told.slice(from).map((entry) => entry.id),
      "every row named since the send",
    ).toEqual(told.slice(from).map(() => settled));
  } finally {
    await act(async () => root.unmount());
  }
});
