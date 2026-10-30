// Projects on the New Tab page (cx-ncc.66, Claude parity): All chats has a Projects view beside Chats.
// It groups the loaded chats under their project folder (the newest project first, a chat without a
// folder under No project), and a project's header folds its chats away.
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
  // TanStack Virtual sizes the list from its scroller; JSDOM lays nothing out, so every element
  // reports a tall box and the list draws its rows.
  window.HTMLElement.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, top: 0, left: 0, right: 600, bottom: 800, width: 600, height: 800, toJSON() {} }) as DOMRect;
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
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

const chat = (key: string, title: string, cwd: string | undefined, updatedAt: number) => ({
  key,
  harness: "claude",
  title,
  ...(cwd ? { cwd } : {}),
  updatedAt,
});
const chats = [
  chat("a", "Retry uploads", "/Users/me/src/uploader", 9),
  chat("b", "Fix the sidebar", "/Users/me/src/cmux", 8),
  chat("c", "Scratch question", undefined, 7),
  chat("d", "Cover retry with tests", "/Users/me/src/uploader", 6),
];

/// The list's rows in order: a project header as `# name (count)`, a chat as its title.
const listed = () =>
  [...host.querySelectorAll<HTMLElement>(".nt-all-item")].map((item) => {
    const header = item.querySelector(".nt-all-group");
    if (header)
      return `# ${header.querySelector(".nt-all-group-name")?.textContent} (${header.querySelector(".nt-all-group-count")?.textContent})`;
    return item.querySelector(".nt-all-title")?.textContent ?? "";
  });
const button = (name: string) =>
  [...host.querySelectorAll("button")].find((element) => element.textContent?.trim() === name);

test("Projects groups the chats by folder, newest project first, and a header folds its chats", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={async () => ({ chats, ready: true })} onOpen={() => {}} />));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(listed()).toEqual(["Retry uploads", "Fix the sidebar", "Scratch question", "Cover retry with tests"]);

  await act(async () => button("Projects")!.click());
  expect(button("Projects")?.getAttribute("aria-pressed")).toBe("true");
  expect(listed()).toEqual([
    "# uploader (2)",
    "Retry uploads",
    "Cover retry with tests",
    "# cmux (1)",
    "Fix the sidebar",
    "# No project (1)",
    "Scratch question",
  ]);

  const uploader = host.querySelector<HTMLButtonElement>(".nt-all-group")!;
  await act(async () => uploader.click());
  expect(uploader.getAttribute("aria-expanded")).toBe("false");
  expect(listed()).toEqual(["# uploader (2)", "# cmux (1)", "Fix the sidebar", "# No project (1)", "Scratch question"]);

  await act(async () => button("Chats")!.click());
  expect(listed()).toEqual(["Retry uploads", "Fix the sidebar", "Scratch question", "Cover retry with tests"]);
});
