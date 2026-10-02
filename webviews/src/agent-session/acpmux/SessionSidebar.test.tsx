import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSessionEntry } from "./sessionList";

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
const { SessionSidebar } = await import("./SessionSidebar");

const sessions: AcpmuxSessionEntry[] = [
  {
    sessionId: "web-1",
    displayTitle: "Fix the checkout page",
    cwd: "/src/web",
    updatedAt: 50,
    status: "waiting",
    pendingPermissions: 1,
  },
  { sessionId: "app-1", displayTitle: "Port the sidebar", cwd: "/src/app", updatedAt: 40, status: "running" },
  ...Array.from({ length: 8 }, (_, index): AcpmuxSessionEntry => ({
    sessionId: `app-old-${index}`,
    displayTitle: `Older ${index}`,
    cwd: "/src/app",
    updatedAt: 30 - index,
    status: "idle",
    unread: index === 0,
  })),
];

test("the sidebar groups sessions by folder, marks them, and selects on click", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const selected: string[] = [];
  await act(async () =>
    root.render(
      createElement(SessionSidebar, { sessions, selectedId: "app-1", onSelect: (id: string) => selected.push(id) }),
    ),
  );

  const projects = [...container.querySelectorAll(".acpmux-sidebar-project")].map((node) => node.textContent);
  expect(projects).toEqual(["web", "app"]);
  const marks = [...container.querySelectorAll(".acpmux-session-mark")].map((node) => node.getAttribute("title"));
  expect(marks).toEqual(["Needs input", "Working", "New activity"]);
  // Needs input is told from the unread dot by its glyph, not only its colour.
  expect(container.querySelector(".acpmux-session-mark-input")?.textContent).toBe("?");
  // The state is part of the row's accessible name.
  expect(container.querySelector(".acpmux-session-row")?.getAttribute("aria-label")).toBe(
    "Fix the checkout page, Needs input",
  );
  expect(container.querySelector(".is-selected")?.textContent).toBe("Port the sidebar");

  // The app group has nine sessions: six rows and "Show more", which names the hidden count.
  const more = container.querySelector<HTMLButtonElement>(".acpmux-sidebar-more")!;
  expect(more.textContent).toBe("Show more");
  expect(more.getAttribute("aria-label")).toBe("Show more, 3 hidden");
  expect(container.querySelectorAll(".acpmux-session-row").length).toBe(7);
  await act(async () => more.click());
  expect(container.querySelectorAll(".acpmux-session-row").length).toBe(10);

  const row = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-session-row")].find((node) =>
    node.textContent?.startsWith("Fix the checkout"),
  )!;
  await act(async () => row.click());
  expect(selected).toEqual(["web-1"]);
  await act(async () => root.unmount());
});

test("an empty list says so", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(SessionSidebar, { sessions: [], onSelect: () => undefined })));
  expect(container.textContent).toBe("No sessions yet");
  await act(async () => root.unmount());
});
