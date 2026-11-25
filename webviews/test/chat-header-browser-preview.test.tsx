// The chat header's Browser (the globe) always opens a new, blank browser
// (https://github.com/manaflow-ai/cmux/issues/49623). It used to open the local page the chat's last
// turns mentioned, and a dev build's Tag Opener link (http://127.0.0.1:17320/<tag>) is such a page: the
// globe reopened it and relaunched the build. The chat's page stays Preview's: a "..." row by default
// (chat-header-fold.test.tsx), or its own button.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

test("Browser opens a blank browser even with a local page in the chat, and never lights for one", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/chatHeaderToolsModel");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  // The default buttons, and nothing open yet (other files in this run share the page's modules).
  configureQuickActions({});
  applyHostEvent({ kind: "headerState", value: { lit: [] } });
  const runs: string[] = [];
  root = createRoot(host);
  const render = (previewUrl: string | undefined) =>
    act(() =>
      root!.render(
        <ChatHeaderTools
          onTerminal={() => {}}
          onBrowser={(mode) => runs.push(`browser ${mode}`)}
          previewUrl={previewUrl}
          onPreview={(url, mode) => runs.push(`preview ${mode} ${url}`)}
          summary={null}
          menu={() => []}
        />,
      ),
    );
  const button = (label: string) =>
    host.querySelector<HTMLButtonElement>(`.acpmux-header-tools button[aria-label="${label}"]`);
  const browser = () => button("Browser");

  // No page: a plain browser split, and no Preview button beside it.
  render(undefined);
  expect(button("Preview")).toBeNull();
  expect(browser()?.getAttribute("title")).toBe("Browser");
  act(() => browser()!.click());
  expect(runs).toEqual(["browser toggle"]);

  // The chat handed over a dev build: its Tag Opener link is the chat's latest local page. The globe
  // still opens a blank browser and says nothing about the page.
  runs.length = 0;
  render("http://127.0.0.1:17320/49623-globe-opens-old-tab");
  expect(button("Preview")).toBeNull();
  expect(browser()?.getAttribute("title")).toBe("Browser");
  expect(browser()?.getAttribute("aria-pressed")).toBe("false");
  act(() => browser()!.click());
  expect(runs).toEqual(["browser toggle"]);

  // A preview open beside the chat is not the globe's: it stays unlit and still opens a blank browser.
  runs.length = 0;
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.preview] } }));
  expect(browser()?.getAttribute("aria-pressed")).toBe("false");
  act(() => browser()!.click());
  expect(runs).toEqual(["browser toggle"]);

  // Its own browser split open: lit, and the click toggles that one.
  runs.length = 0;
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.browser] } }));
  expect(browser()?.getAttribute("aria-pressed")).toBe("true");
  act(() => browser()!.click());
  expect(runs).toEqual(["browser toggle"]);

  // Preview shown as its own button (layout.json): it opens the page; Browser stays blank.
  runs.length = 0;
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [] } }));
  act(() => configureQuickActions({ quickActions: ["preview", "terminal", "browser"] }));
  render("http://localhost:5173/");
  expect(button("Preview")).not.toBeNull();
  act(() => button("Preview")!.click());
  act(() => browser()!.click());
  expect(runs).toEqual(["preview toggle http://localhost:5173/", "browser toggle"]);
  act(() => root?.unmount());
  root = undefined;
  configureQuickActions({});
});
