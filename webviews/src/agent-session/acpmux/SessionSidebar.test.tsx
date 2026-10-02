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
  // Needs input and working are told apart from the unread dot by their glyphs, not only by colour.
  expect(container.querySelector(".acpmux-session-mark-input svg")).not.toBeNull();
  expect(container.querySelector(".acpmux-session-mark-running svg")).not.toBeNull();
  expect(container.querySelector(".acpmux-session-mark-unread svg")).toBeNull();
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

test("pinned sessions get their own section, an all-cloud project names its machine, and rows show where they run", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const list: AcpmuxSessionEntry[] = [
    { sessionId: "pin", displayTitle: "Set up 24/7 agent work", cwd: "/src/web", updatedAt: 9, pinned: true },
    { sessionId: "web", displayTitle: "Fix the checkout page", cwd: "/src/web", updatedAt: 8 },
    {
      sessionId: "cloud",
      displayTitle: "Tags with a TTL",
      cwd: "/home/u/acpmux",
      host: "cobalt-butte",
      hostKind: "cloud",
      updatedAt: 7,
    },
    {
      sessionId: "local",
      displayTitle: "Lint",
      cwd: "/src/web",
      host: "This Mac",
      hostKind: "local",
      branch: "lint",
      updatedAt: 6,
    },
    {
      sessionId: "far",
      displayTitle: "CI",
      cwd: "/src/web",
      host: "hearty-elk",
      hostKind: "cloud",
      branch: "ci",
      updatedAt: 5,
    },
    {
      sessionId: "tree",
      displayTitle: "Home",
      cwd: "/src/web",
      branch: "home",
      worktree: "/src/web-home",
      updatedAt: 4,
    },
  ];
  await act(async () => root.render(createElement(SessionSidebar, { sessions: list, onSelect: () => {} })));
  expect([...container.querySelectorAll(".acpmux-sidebar-section")].map((node) => node.textContent)).toEqual([
    "Pinned",
    "Projects",
  ]);
  expect(
    [...container.querySelectorAll(".acpmux-sidebar-pinned .acpmux-session-row")].map((node) => node.textContent),
  ).toEqual(["Set up 24/7 agent work"]);
  expect([...container.querySelectorAll(".acpmux-sidebar-project")].map((node) => node.textContent)).toEqual([
    "web",
    "acpmuxcobalt-butte",
  ]);
  const row = (id: string) =>
    [...container.querySelectorAll<HTMLButtonElement>(".acpmux-session-row")].find(
      (node) => node.textContent === list.find((session) => session.sessionId === id)!.displayTitle,
    )!;
  const place = (id: string) => row(id).querySelector(".acpmux-session-place")?.className.split("-").pop();
  // This Mac is never named; a cloud row in a mixed project carries the machine instead of its branch.
  expect([place("web"), place("local"), place("far"), place("tree"), place("cloud")]).toEqual([
    undefined,
    "branch",
    "cloud",
    "worktree",
    undefined,
  ]);
  expect(row("far").title).toBe("CI\nRuns on hearty-elk, Branch ci");
  expect(row("tree").getAttribute("aria-label")).toBe("Home, Worktree home");
  await act(async () => root.unmount());
});

test("search narrows the list, shows every match, and Escape clears it before closing anything", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(SessionSidebar, { sessions, onSelect: () => {} })));
  const field = container.querySelector<HTMLInputElement>('input[aria-label="Search sessions"]')!;
  const type = async (value: string) =>
    act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, value);
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  const titles = () => [...container.querySelectorAll(".acpmux-session-row")].map((node) => node.textContent);

  await type("older");
  expect(titles()).toEqual(Array.from({ length: 8 }, (_, index) => `Older ${index}`));
  expect(container.querySelector(".acpmux-sidebar-more")).toBeNull();
  await type("src/web checkout");
  expect(titles()).toEqual(["Fix the checkout page"]);
  await type("nothing like this");
  expect(container.querySelector(".acpmux-sidebar-empty")?.textContent).toBe("No matching sessions");

  let reached = 0;
  const onKey = () => reached++;
  dom.window.document.addEventListener("keydown", onKey);
  const escape = () =>
    act(async () => {
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
  await escape();
  expect(field.value).toBe("");
  expect(reached).toBe(0);
  // The full list folds behind "Show more" again.
  expect(titles()).toHaveLength(1 + 6);
  expect(container.querySelector(".acpmux-sidebar-more")).not.toBeNull();
  await escape();
  expect(reached).toBe(1);
  dom.window.document.removeEventListener("keydown", onKey);
  await act(async () => root.unmount());
});
