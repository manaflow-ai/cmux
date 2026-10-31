// The chat header shows the chat branch's pull request and its checks (cx-tcwj, Codex desktop's PR
// chip). The App pushes `pullRequest` with the header state: the chip opens the pull request's status, says
// how its checks stand, and goes away when the App says there is none (another chat, a closed PR).
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

test("the header links the pull request with its checks, and drops it when the App says none", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  root = createRoot(host);
  act(() =>
    root!.render(<ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => []} />),
  );
  const chip = () => host.querySelector<HTMLButtonElement>("button.acpmux-header-pr");
  expect(chip()).toBeNull();
  const pullRequest = {
    url: "https://github.com/o/r/pull/7",
    number: 7,
    state: "open",
    checks: { state: "failing", passed: 3, total: 5 },
  };
  act(() => applyHostEvent({ kind: "headerState", value: { version: 1, pullRequest } }));
  expect(chip()?.textContent).toBe("#7");
  expect(chip()?.getAttribute("data-checks")).toBe("failing");
  // Its text shows, so no tooltip; a screen reader hears the state and checks (test/tooltip-rules.ts).
  // Aggregate failure must still be spoken when the host supplies no individual check rows.
  expect(chip()?.getAttribute("aria-label")).toBe("Pull request #7, open: 3 of 5 checks passed · Failing");
  expect(chip()?.hasAttribute("title")).toBe(false);
  // A push about something else keeps it; one that says there is none drops it.
  act(() => applyHostEvent({ kind: "headerState", value: { version: 2, lit: ["splitRight"] } }));
  expect(chip()).not.toBeNull();
  act(() => applyHostEvent({ kind: "headerState", value: { version: 3, pullRequest: null } }));
  expect(chip()).toBeNull();
});
