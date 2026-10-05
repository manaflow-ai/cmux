import { JSDOM } from "jsdom";
import { afterAll, afterEach, expect, test } from "bun:test";
import { PaneSidePanel, PaneToolToggles, type AgentPaneTool } from "./PaneTools";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
const { act, createElement, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
afterEach(() => dom.window.document.getElementById("root")!.replaceChildren());

test("compact cluster keeps three visible controls, exposes shortcut menus, and preserves active diff", async () => {
  const actions: string[] = [];
  function Harness() {
    const [active, setActive] = useState<AgentPaneTool | undefined>("diff");
    return <>
      <PaneToolToggles active={active} onToggle={(tool) => setActive((current) => current === tool ? undefined : tool)} onAction={(action) => actions.push(action)} />
      {active && <PaneSidePanel kind={active} onClose={() => setActive(undefined)} />}
    </>;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(createElement(Harness)));
    const buttons = [...dom.window.document.querySelectorAll(".acpmux-pane-tools > .acpmux-pane-menu-wrap > button, .acpmux-pane-tools > .acpmux-pane-tool")];
    expect(buttons).toHaveLength(4);
    expect(dom.window.document.querySelector('[aria-label="New agent chat"]')!.getAttribute("title")).toContain("⇧⌘I");
    expect(dom.window.document.querySelector('[aria-label="Split right"]')!.getAttribute("title")).toContain("⌘D");
    expect(dom.window.document.querySelector('[aria-label="Diff"]')!.getAttribute("aria-pressed")).toBe("true");
    await act(async () => (dom.window.document.querySelector('[aria-label="More pane actions"]') as HTMLButtonElement).click());
    expect(dom.window.document.querySelector('[role="menu"]')).not.toBeNull();
    expect(dom.window.document.body.textContent).toContain("Duplicate tab");
    await act(async () => (dom.window.document.querySelector('[aria-label="New agent chat"]') as HTMLButtonElement).click());
    expect(actions).toEqual(["chat.new"]);
  } finally { await act(async () => root.unmount()); }
});

afterAll(() => Object.assign(globals, saved));
