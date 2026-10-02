import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { NewTabPage, ageLabel, cycleKind, newTabHost, recentSessions } = await import("./NewTabPage");

const sessions = [
  { sessionId: "old", title: "Old", cwd: "/src/app", updatedAt: 10, status: "idle" },
  { sessionId: "new", title: "New", cwd: "/src/app", updatedAt: 30, status: "idle" },
  { sessionId: "ask", title: "Ask", cwd: "/src/web", updatedAt: 20, status: "waiting", pendingPermissions: 1 },
] as unknown as AcpmuxSnapshot["sessions"];
const snapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions,
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};

test("the handshake's newTab becomes the page's kind, hotkeys and folder", () => {
  expect(newTabHost({})).toBeUndefined();
  expect(newTabHost({ newTab: true })).toEqual({ hotkeys: {}, initialKind: "agent" });
  expect(
    newTabHost({
      newTab: { kind: "browser", hotkeys: { terminal: "⌃⇧⌘T", agent: "", spreadsheet: "x" }, cwd: "~/code" },
    }),
  ).toEqual({ hotkeys: { terminal: "⌃⇧⌘T" }, initialKind: "browser", cwd: "~/code" });
  expect(newTabHost({ newTab: { kind: "spreadsheet" } })?.initialKind).toBe("agent");
});

test("Tab cycles the kinds both ways, and recent sessions put the ones waiting on you first", () => {
  expect(cycleKind("terminal")).toBe("browser");
  expect(cycleKind("agent")).toBe("terminal");
  expect(cycleKind("terminal", -1)).toBe("agent");
  expect(recentSessions(sessions).map((entry) => entry.sessionId)).toEqual(["ask", "new", "old"]);
  expect(recentSessions(sessions, 1).map((entry) => entry.sessionId)).toEqual(["ask"]);
  const at = 1_000;
  expect([
    ageLabel(undefined, at),
    ageLabel(at, at + 20_000),
    ageLabel(at, at + 5 * 60_000),
    ageLabel(at, at + 3 * 3_600_000),
    ageLabel(at, at + 2 * 86_400_000),
  ]).toEqual(["", "now", "5m", "3h", "2d"]);
});

test("the page switches kind with Tab, submits the field, and opens or edits from the page", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const submitted: string[] = [];
  const opened: string[] = [];
  const edited: string[] = [];
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        hotkeys: { terminal: "⌃⇧⌘T", agent: "⇧⌘I" },
        initialKind: "terminal",
        cwd: "~/code/cmux",
        onSubmit: (kind: string, text: string) => submitted.push(`${kind}:${text}`),
        onOpenSession: (id: string) => opened.push(id),
        onShowAll: () => {},
        onEditShortcut: (kind: string) => edited.push(kind),
      }),
    ),
  );
  const page = container.querySelector(".acpmux-newtab")!;
  const field = container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  expect(page.getAttribute("data-kind")).toBe("terminal");
  expect([...container.querySelectorAll(".acpmux-newtab-kind kbd")].map((node) => node.textContent)).toEqual([
    "⌃⇧⌘T",
    "⇧⌘I",
  ]);

  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
  });
  expect(page.getAttribute("data-kind")).toBe("browser");
  // An empty field has no page to open.
  await act(async () => {
    container.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(submitted).toEqual([]);

  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true }));
  });
  expect(page.getAttribute("data-kind")).toBe("terminal");
  await act(async () => {
    container.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(submitted).toEqual(["terminal:"]);

  const agent = container.querySelectorAll<HTMLButtonElement>(".acpmux-newtab-kind")[2]!;
  await act(async () => {
    agent.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
  });
  expect(edited).toEqual(["agent"]);
  await act(async () => {
    agent.click();
  });
  expect(page.getAttribute("data-kind")).toBe("agent");

  const cards = container.querySelectorAll<HTMLButtonElement>(".acpmux-newtab-card");
  expect(cards.length).toBe(3);
  await act(async () => {
    cards[0]!.click();
  });
  expect(opened).toEqual(["ask"]);
  await act(async () => root.unmount());
});

test("a pane without a known folder names none", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(NewTabPage, {
        snapshot,
        initialKind: "terminal",
        onSubmit: () => {},
        onOpenSession: () => {},
        onShowAll: () => {},
      }),
    ),
  );
  expect(container.querySelector<HTMLInputElement>(".acpmux-newtab-field")!.placeholder).toBe("Run a command");
  expect(container.querySelector(".acpmux-newtab-context")!.textContent).not.toContain("No folder");
  await act(async () => root.unmount());
});
