// The chat header's toggle buttons light while their panel is open (cx-00n1), as Claude Code desktop's
// top right does. The App pushes which header splits are open (`headerState`); a toggling Terminal or
// Browser shows pressed while its split is open, and goes dark when the App says it closed. A button
// in open mode makes another pane on every click, so it never shows pressed.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
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

test("a toggle lights while the App reports its split open, and not in open mode", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  // Other header cases change these shared stores; this case starts from its own toggle state.
  configureQuickActions({});
  applyHostEvent({ kind: "headerState", value: { lit: [], browserOpensPreview: true } });
  root = createRoot(host);
  act(() =>
    root!.render(<ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => []} />),
  );
  const pressed = () =>
    Object.fromEntries(
      [...host.querySelectorAll(".acpmux-header-tools button")].map((button) => [
        button.getAttribute("aria-label"),
        button.getAttribute("aria-pressed"),
      ]),
    );
  expect(pressed()).toMatchObject({ Terminal: "false", Browser: "false" });
  act(() => applyHostEvent({ kind: "headerState", value: { lit: ["splitRight"] } }));
  expect(pressed()).toMatchObject({ Terminal: "true", Browser: "false" });
  act(() => applyHostEvent({ kind: "headerState", value: { lit: ["splitRight", "splitBrowserRight"] } }));
  expect(pressed()).toMatchObject({ Terminal: "true", Browser: "true" });
  // The user closed the terminal from its own tab: the App's next push turns it off.
  act(() => applyHostEvent({ kind: "headerState", value: { lit: ["splitBrowserRight"] } }));
  expect(pressed()).toMatchObject({ Terminal: "false", Browser: "true" });
  // In open mode every click opens another browser: there is no one panel to show as on.
  act(() => configureQuickActions({ quickActions: ["terminal", { id: "browser", mode: "open" }] }));
  expect(pressed()).toMatchObject({ Terminal: "false", Browser: null });
  act(() => {
    configureQuickActions({});
    applyHostEvent({ kind: "headerState", value: { lit: [] } });
  });
});
