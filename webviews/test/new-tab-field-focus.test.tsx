// The New Tab field takes the keyboard once when the page shows (and on Cmd-L), never again on its
// own. The App re-renders the page often (snapshots, the clock) and hands it a new input-ready
// callback each time; the page focused and selected the field on every one, so a click into the
// focused field, or any update, restarted the caret blink and selected the text under the caret.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

/// Shows a page as the App does (a new inline input-ready callback on every render), places the
/// caret in typed text, then re-renders and clicks the focused field as a person would.
async function caretAfterUpdates(page: (onInputReady: (token: string) => void) => ReactElement, selector: string) {
  const { createRoot } = await import("react-dom/client");
  const ready: string[] = [];
  const root: Root = createRoot(host);
  const render = () => root.render(page((token) => ready.push(token)));
  try {
    await act(async () => render());
    const field = host.querySelector<HTMLInputElement | HTMLTextAreaElement>(selector)!;
    expect(window.document.activeElement).toBe(field);
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, "hello world");
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
    field.setSelectionRange(3, 3);
    let focused = 0;
    field.addEventListener("focus", () => (focused += 1));
    const focus = field.focus.bind(field);
    field.focus = (options?: FocusOptions) => {
      focused += 1;
      focus(options);
    };
    // The App re-renders the page; then a click lands in the field that already has focus.
    await act(async () => render());
    await act(async () => render());
    await act(async () => {
      field.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
      field.dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true }));
      field.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
    });
    return { focused, selection: [field.selectionStart, field.selectionEnd], ready };
  } finally {
    await act(async () => root.unmount());
  }
}

test("the New Tab screen keeps the caret where it is across updates and a click into its field", async () => {
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const result = await caretAfterUpdates(
    (onInputReady) => (
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        inputToken="token-1"
        onInputReady={onInputReady}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    ),
    ".nt-field",
  );
  expect(result).toEqual({ focused: 0, selection: [3, 3], ready: ["token-1"] });
});

test("the classic New Tab page keeps the caret where it is across updates and a click into its field", async () => {
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const result = await caretAfterUpdates(
    (onInputReady) => (
      <NewTabPage
        snapshot={noChat()}
        inputToken="token-1"
        onInputReady={onInputReady}
        onSubmit={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    ),
    ".acpmux-newtab-field",
  );
  expect(result).toEqual({ focused: 0, selection: [3, 3], ready: ["token-1"] });
});

test("the classic kind switch gives browser and agent contexts a directional handoff", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <NewTabPage snapshot={noChat()} initialKind="browser" onSubmit={noop} onOpenSession={noop} onShowAll={noop} />,
      ),
    );
    const row = host.querySelector<HTMLElement>(".acpmux-newtab-row")!;
    const under = host.querySelector<HTMLElement>(".acpmux-newtab-under")!;
    const agent = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-newtab-kind")].find((button) =>
      button.textContent?.includes("Agent"),
    )!;
    expect(row.dataset.kindSwitch).toBeUndefined();
    await act(async () => agent.click());
    // The animation is armed on the next paint so repeated forward switches restart it.
    await act(async () => new Promise((resolve) => setTimeout(resolve, 25)));
    expect(host.querySelector(".acpmux-newtab")?.getAttribute("data-kind")).toBe("agent");
    expect(row.dataset.kindSwitch).toBe("next");
    expect(under.dataset.kindSwitch).toBe("next");
    await act(async () => new Promise((resolve) => setTimeout(resolve, 240)));
    expect(row.dataset.kindSwitch).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});
