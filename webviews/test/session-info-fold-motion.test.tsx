// Session Info's Show more / Show less folds (session-info/foldMotion.ts) and its section grip. A fold
// that closes keeps its rows drawn and its box clipped (`data-folding`) only while its animation runs:
// finished or cancelled from outside (turning the pane's animations off cancels every animation in
// the page), it lands on the closed state, the rows gone and the box unclipped. The hidden grip takes no
// press, so a click on the head's count under it folds the section (sessionInfo.css).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useFoldMotion } from "../src/agent-session/acpmux/session-info/foldMotion";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
type FakeAnimation = { onfinish: null | (() => void); oncancel: null | (() => void); cancel(): void };
let animations: FakeAnimation[] = [];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
  // JSDOM lays nothing out: a list is 28px a row.
  Object.defineProperty(proto, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.children.length * 28;
    },
  });
  // JSDOM has no Web Animations: record each one; the test ends or cancels it.
  proto.animate = () => {
    const animation: FakeAnimation = {
      onfinish: null,
      oncancel: null,
      cancel() {
        animation.oncancel?.();
      },
    };
    animations.push(animation);
    return animation;
  };
  animations = [];
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// Two rows, and three more behind Show more: open at first.
function List() {
  const [all, setAll] = useState(true);
  const fold = useFoldMotion<HTMLUListElement>(all, () => 2 * 28);
  const rows = fold.drawn ? [1, 2, 3, 4, 5] : [1, 2];
  return (
    <>
      <ul ref={fold.ref}>
        {rows.map((row) => (
          <li key={row}>{row}</li>
        ))}
      </ul>
      <button type="button" aria-expanded={all} onClick={() => fold.toggle(!all, setAll)}>
        fold
      </button>
      {/* A reveal from outside (SessionInfo's own reveal path): sets the state without toggle. */}
      <button type="button" className="reveal" onClick={() => setAll(true)}>
        reveal
      </button>
    </>
  );
}

async function render() {
  const container = dom!.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () => root!.render(<List />));
  const list = container.querySelector("ul")!;
  const button = container.querySelector("button")!;
  const reveal = container.querySelector<HTMLButtonElement>("button.reveal")!;
  return { list, button, reveal };
}

test("a Show less keeps its rows drawn and its box clipped while it closes, then lands closed", async () => {
  const { list, button } = await render();
  await act(async () => button.click());
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(animations.length).toBe(1);
  expect(list.children.length).toBe(5);
  expect(list.dataset.folding).toBe("");
  await act(async () => animations[0]!.onfinish?.());
  expect(list.children.length).toBe(2);
  expect(list.dataset.folding).toBeUndefined();
});

test("the host's Reduce Motion (a zero move duration) folds at once", async () => {
  dom!.window.document.documentElement.dataset.agentMove = "instant";
  const { list, button } = await render();
  await act(async () => button.click());
  expect(animations.length).toBe(0);
  expect(list.children.length).toBe(2);
  expect(list.dataset.folding).toBeUndefined();
  const css = readFileSync(
    path.join(import.meta.dir, "../src/agent-session/acpmux/session-info/sessionInfo.css"),
    "utf8",
  );
  expect(css.match(/\[data-agent-move="instant"\]\)/g)?.length).toBe(2);
});

test("a reveal from outside during Show less stops the close, so the reopened box is never left clipped", async () => {
  const { list, button, reveal } = await render();
  await act(async () => button.click());
  expect(list.dataset.folding).toBe("");
  const closing = animations[0]!;
  let cancelled = false;
  const cancel = closing.cancel.bind(closing);
  closing.cancel = () => {
    cancelled = true;
    cancel();
  };
  await act(async () => reveal.click());
  expect(cancelled).toBe(true);
  expect(list.children.length).toBe(5);
  expect(list.dataset.folding).toBeUndefined();
  // The stale close finishing late (a real animation's fill: forwards would hold its height) settles nothing.
  await act(async () => closing.onfinish?.());
  expect(list.children.length).toBe(5);
  expect(list.dataset.folding).toBeUndefined();
});

test("a closing fold cancelled from outside (animations turned off) lands closed, not stuck open", async () => {
  const { list, button } = await render();
  await act(async () => button.click());
  expect(list.children.length).toBe(5);
  // What applyAgentTheme does when the pane's animations go off: every animation in the page cancels.
  await act(async () => animations[0]!.cancel());
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(list.children.length).toBe(2);
  expect(list.dataset.folding).toBeUndefined();
});

test("an opening fold cancelled from outside unclips its box", async () => {
  const { list, button } = await render();
  await act(async () => button.click());
  await act(async () => animations[0]!.onfinish?.());
  await act(async () => button.click());
  expect(list.children.length).toBe(5);
  expect(list.dataset.folding).toBe("");
  await act(async () => animations[1]!.cancel());
  expect(list.children.length).toBe(5);
  expect(list.dataset.folding).toBeUndefined();
});

test("a fold turned back midway settles only the newest motion", async () => {
  const { list, button } = await render();
  await act(async () => button.click());
  await act(async () => button.click());
  // The close was replaced (cancelled by the hook itself): its late end must not drop the reopened rows,
  // and the box is left unclipped.
  await act(async () => animations[0]!.onfinish?.());
  await act(async () => animations[0]!.oncancel?.());
  expect(button.getAttribute("aria-expanded")).toBe("true");
  expect(list.children.length).toBe(5);
  expect(list.dataset.folding).toBeUndefined();
});

// The hidden grip covers the right end of its head, where the count is: it must take no press there, or a
// click on the count would start a reorder instead of folding the section. It takes the pointer only while
// it shows (gallery agent-pane.chat-inspector#heads-plain checks the same with the browser's hit-testing).
test("the hidden section grip takes no press; it takes the pointer only while it shows", () => {
  const css = readFileSync(
    path.resolve(import.meta.dir, "../src/agent-session/acpmux/session-info/sessionInfo.css"),
    "utf8",
  );
  const base = /\n\.acpmux-session-info-section__handle \{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(base).toMatch(/opacity:\s*0;/);
  expect(base).toMatch(/pointer-events:\s*none;/);
  const shown = /([^}]*)\{\s*opacity:\s*var\(--acpmux-session-info-grip-shown\);([^}]*)\}/.exec(css);
  expect(shown?.[1]).toContain(".ui-disclosure-trigger:hover");
  expect(shown?.[2]).toMatch(/pointer-events:\s*auto;/);
});
