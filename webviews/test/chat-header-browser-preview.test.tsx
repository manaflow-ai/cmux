// The chat header's Browser opens what the chat is about (Leo 2026-10-20: "something different was
// opening here"): with a local page from the chat's last turns it opens that page beside the chat,
// names it in its tooltip and lights while it is open, and a second click closes it; without one it
// opens a plain browser split, as before. Preview is no longer a button of its own by default; a
// person who shows it gets the separate Preview and a plain Browser back.
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

test("Browser opens the chat's local page beside it, lights while it is open, and closes it again", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools, HEADER_ACTIONS } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
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

  // A page: the same button opens it and says so.
  runs.length = 0;
  render("http://localhost:5173/");
  expect(button("Preview")).toBeNull();
  expect(browser()?.getAttribute("title")).toBe("Preview localhost:5173");
  expect(browser()?.getAttribute("aria-pressed")).toBe("false");
  act(() => browser()!.click());
  expect(runs).toEqual(["preview toggle http://localhost:5173/"]);

  // Open: lit, and the next click closes the preview it opened.
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.preview] } }));
  expect(browser()?.getAttribute("aria-pressed")).toBe("true");
  act(() => browser()!.click());
  // The page goes along: a preview closed since the last state push opens again rather than nothing.
  expect(runs).toEqual(["preview toggle http://localhost:5173/", "preview toggle http://localhost:5173/"]);

  // A plain browser split already open: the click closes that one, not opens the page.
  runs.length = 0;
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [HEADER_ACTIONS.browser] } }));
  expect(browser()?.getAttribute("aria-pressed")).toBe("true");
  act(() => browser()!.click());
  expect(runs).toEqual(["browser toggle"]);

  // Preview shown as its own button (layout.json): Browser is a plain browser again.
  runs.length = 0;
  act(() => applyHostEvent({ kind: "headerState", value: { lit: [] } }));
  act(() => configureQuickActions({ quickActions: ["preview", "terminal", "browser"] }));
  render("http://localhost:5173/");
  expect(button("Preview")).not.toBeNull();
  expect(browser()?.getAttribute("title")).toBe("Browser");
  act(() => browser()!.click());
  expect(runs).toEqual(["browser toggle"]);
  act(() => root?.unmount());
  root = undefined;
  configureQuickActions({});
});

test("with Debug Settings agentChat.browserOpensPreview off, the default header is Preview beside a plain Browser", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  configureQuickActions({});
  applyHostEvent({ kind: "headerState", value: { lit: [], browserOpensPreview: false } });
  const runs: string[] = [];
  root = createRoot(host);
  act(() =>
    root!.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={(mode) => runs.push(`browser ${mode}`)}
        previewUrl="http://localhost:5173/"
        onPreview={(url, mode) => runs.push(`preview ${mode} ${url}`)}
        summary={null}
        menu={() => []}
      />,
    ),
  );
  const shown = [...host.querySelectorAll("[data-quick-action]")].map((button) =>
    button.getAttribute("data-quick-action"),
  );
  expect(shown).toEqual(["preview", "terminal", "browser"]);
  const browser = host.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Browser"]')!;
  expect(browser.getAttribute("title")).toBe("Browser");
  act(() => browser.click());
  expect(runs).toEqual(["browser toggle"]);
  // Back on: the page follows the next push.
  act(() => applyHostEvent({ kind: "headerState", value: { browserOpensPreview: true } }));
  expect(
    [...host.querySelectorAll("[data-quick-action]")].map((button) => button.getAttribute("data-quick-action")),
  ).toEqual(["terminal", "browser"]);
  act(() => root?.unmount());
  root = undefined;
});
