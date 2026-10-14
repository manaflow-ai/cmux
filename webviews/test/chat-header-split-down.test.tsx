// The chat header's Split Down (cx-kk7lm): every pane's toolbar has Split Right and Split Down, and a
// chat's is its header. Split Down shows beside Terminal (the chat's Split Right) with its key in the
// tooltip, a click asks the App for the split in the button's mode, and it lights while the App
// reports the terminal it opened.
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

test("Split Down sits after Terminal, runs in its mode and lights while its split is open", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  // Split Down shown as a button (it is in the chat menu by default).
  configureQuickActions({ quickActions: ["terminal", "splitDown", "browser", "changes", "preview", "newTab"] });
  const runs: string[] = [];
  root = createRoot(host);
  act(() =>
    root!.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onSplitDown={(mode: string) => runs.push(mode)}
        onBrowser={() => {}}
        summary={null}
        menu={() => []}
      />,
    ),
  );
  const labels = () =>
    [...host.querySelectorAll(".acpmux-header-tools [data-quick-action]")].map((button) =>
      button.getAttribute("aria-label"),
    );
  const splitDown = () => host.querySelector<HTMLButtonElement>('[data-quick-action="splitDown"]');
  expect(labels().slice(0, 2)).toEqual(["Terminal", "Split Down"]);
  act(() => splitDown()!.click());
  expect(runs).toEqual(["toggle"]);
  expect(splitDown()!.getAttribute("aria-pressed")).toBe("false");
  act(() => applyHostEvent({ kind: "headerState", value: { lit: ["splitDown"] } }));
  expect(splitDown()!.getAttribute("aria-pressed")).toBe("true");
  act(() => configureQuickActions({ quickActions: ["terminal", { id: "splitDown", mode: "open" }] }));
  act(() => splitDown()!.click());
  expect(runs).toEqual(["toggle", "open"]);
});
