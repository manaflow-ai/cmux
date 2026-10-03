import { JSDOM } from "jsdom";
import { afterAll, afterEach, expect, test } from "bun:test";
import { PaneSidePanel, PaneToolToggles, type AgentPaneTool } from "./PaneTools";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});

const { act, createElement, useState } = await import("react");
const { createRoot } = await import("react-dom/client");

afterEach(() => {
  dom.window.document.getElementById("root")!.replaceChildren();
});

test("tool toggles expose shortcuts, replace the panel instantly, and close when pressed again", async () => {
  function Harness() {
    const [active, setActive] = useState<AgentPaneTool>();
    return (
      <>
        <PaneToolToggles
          active={active}
          onToggle={(tool) => setActive((current) => (current === tool ? undefined : tool))}
        />
        {active && <PaneSidePanel kind={active} onClose={() => setActive(undefined)} />}
      </>
    );
  }

  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(createElement(Harness)));
    const browser = dom.window.document.querySelector<HTMLButtonElement>('[aria-label="Browser"]')!;
    const diff = dom.window.document.querySelector<HTMLButtonElement>('[aria-label="Diff"]')!;
    const terminal = dom.window.document.querySelector<HTMLButtonElement>('[aria-label="Terminal"]')!;
    expect(browser.title).toBe("Browser ⇧⌘B");
    expect(diff.title).toBe("Diff ⇧⌘D");
    expect(terminal.title).toBe("Terminal ⇧⌘T");

    await act(async () => browser.click());
    expect(dom.window.document.querySelector('[data-panel="browser"]')).not.toBeNull();
    expect(browser.getAttribute("aria-pressed")).toBe("true");
    expect(dom.window.document.querySelector('[data-panel="terminal"]')).toBeNull();

    await act(async () => terminal.click());
    expect(dom.window.document.querySelector('[data-panel="terminal"]')).not.toBeNull();
    expect(dom.window.document.querySelector('[data-panel="browser"]')).toBeNull();
    expect(terminal.getAttribute("aria-pressed")).toBe("true");

    await act(async () => terminal.click());
    expect(dom.window.document.querySelector("[data-panel]")).toBeNull();
    expect(terminal.getAttribute("aria-pressed")).toBe("false");
  } finally {
    await act(async () => root.unmount());
  }
});

afterAll(() => Object.assign(globals, saved));
