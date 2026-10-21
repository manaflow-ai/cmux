// A chat header in the pane's tab row (chrome.tabs.rowTools, on by default since 2026-10-20) hides its
// status slot, which sits under the App's tabs; the connection warning then leads the tools instead,
// so a disconnected or failed chat still says so, with the reason in its tooltip.
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

test("the inline status shows the warning and its reason, and nothing while connected", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderInlineStatus } = await import("../src/agent-session/acpmux/header/ChatHeaderStatus");
  root = createRoot(host);
  act(() => root!.render(<ChatHeaderInlineStatus status="" />));
  expect(host.querySelector(".acpmux-status")).toBeNull();
  act(() => root!.render(<ChatHeaderInlineStatus status="Disconnected" detail="acpmux stopped answering" />));
  const label = host.querySelector(".acpmux-status--inline");
  expect(label?.textContent).toBe("Disconnected");
  expect(label?.getAttribute("title")).toBe("acpmux stopped answering");
  // Not inside the hidden slot: it renders wherever the tools put it.
  expect(host.querySelector(".acpmux-header-status-slot")).toBeNull();
  act(() => root?.unmount());
  root = undefined;
});
