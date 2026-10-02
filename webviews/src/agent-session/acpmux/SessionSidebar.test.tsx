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

  const projects = [...container.querySelectorAll(".acpmux-sidebar-project > span:first-of-type")].map(
    (node) => node.textContent,
  );
  expect(projects).toEqual(["web", "app"]);
  const marks = [...container.querySelectorAll(".acpmux-session-row .acpmux-session-mark")].map((node) =>
    node.getAttribute("title"),
  );
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

test("pinned sessions get their own section and projects on another machine name it", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const list: AcpmuxSessionEntry[] = [
    { sessionId: "pin", displayTitle: "Set up 24/7 agent work", cwd: "/src/web", updatedAt: 9, pinned: true },
    { sessionId: "web", displayTitle: "Fix the checkout page", cwd: "/src/web", updatedAt: 8 },
    { sessionId: "cloud", displayTitle: "Tags with a TTL", cwd: "/home/u/acpmux", host: "cobalt-butte", updatedAt: 7 },
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
  await act(async () => root.unmount());
});

test("the rail switches the list; the sessions view adds New chat, project marks and the account", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const list: AcpmuxSessionEntry[] = [
    { sessionId: "ask", displayTitle: "Fix the checkout page", cwd: "/src/web", updatedAt: 50, status: "waiting" },
    { sessionId: "lost", displayTitle: "Tune the cache", cwd: "/src/api", updatedAt: 40, status: "disconnected" },
    { sessionId: "done", displayTitle: "Ship the redirect", cwd: "/src/web", updatedAt: 30, status: "closed" },
  ];
  let newChats = 0;
  await act(async () =>
    root.render(
      createElement(SessionSidebar, {
        sessions: list,
        onSelect: () => undefined,
        onNewChat: () => {
          newChats += 1;
        },
        account: { name: "leo", detail: "Max" },
      }),
    ),
  );

  const rail = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-rail-button")];
  expect(rail.map((button) => button.getAttribute("aria-label"))).toEqual([
    "New chat",
    "Sessions, needs input",
    "History",
    "Pull requests",
    "Closed sessions",
  ]);
  expect(rail[1].getAttribute("aria-current")).toBe("page");
  // A project repeats its most urgent session's mark: needs input over a lost agent.
  const projectMarks = [...container.querySelectorAll(".acpmux-sidebar-project .acpmux-session-mark")];
  expect(projectMarks.map((node) => node.textContent)).toEqual(["Needs input", "Disconnected"]);
  expect(container.querySelector(".acpmux-account")?.textContent).toBe("LleoMax");

  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-sidebar-action")!.click());
  await act(async () => rail[0].click());
  expect(newChats).toBe(2);

  await act(async () => rail[2].click());
  expect(container.querySelector(".acpmux-sidebar-title")?.textContent).toBe("History");
  const titles = () => [...container.querySelectorAll(".acpmux-session-row-title")].map((node) => node.textContent);
  expect(titles()).toEqual(["Fix the checkout page", "Tune the cache", "Ship the redirect"]);
  // The age is part of the row's name, not only drawn.
  expect(container.querySelector(".acpmux-session-row")?.getAttribute("aria-label")).toMatch(
    /^Fix the checkout page, \d+[mhdw]|now/,
  );

  await act(async () => rail[3].click());
  expect(container.querySelector(".acpmux-sidebar-empty")?.textContent).toBe("No pull requests yet");
  await act(async () => rail[4].click());
  expect(container.querySelector(".acpmux-sidebar-title")?.textContent).toBe("Closed sessions");
  expect(titles()).toEqual(["Ship the redirect"]);
  await act(async () => root.unmount());
});
