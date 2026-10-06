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
const { HomeLists, age, homeLists } = await import("./HomeLists");

const minute = 60_000;
const now = Date.now();
const sessions: AcpmuxSessionEntry[] = [
  {
    sessionId: "new",
    displayTitle: "New chat",
    cwd: "/src/cmux",
    updatedAt: now,
    status: "waiting",
  },
  {
    sessionId: "perm",
    displayTitle: "Fix the checkout page",
    cwd: "/src/web",
    updatedAt: now - 9 * minute,
    pendingPermissions: 1,
    preview: "May I run the migration?",
  },
  {
    sessionId: "wait",
    displayTitle: "Port the sidebar",
    cwd: "/src/app",
    updatedAt: now - 3 * 60 * minute,
    status: "waiting",
    pullRequest: { number: 212, title: "Resume sessions after a daemon restart", state: "open", reviewReady: true },
  },
  { sessionId: "busy", displayTitle: "Busy", updatedAt: now - minute, status: "running" },
  {
    sessionId: "draft",
    displayTitle: "Localize",
    updatedAt: now - minute,
    pullRequest: { number: 18166, title: "Localize the changes view", state: "draft", reviewReady: true },
  },
  {
    sessionId: "merged",
    displayTitle: "Composer",
    updatedAt: now - minute,
    pullRequest: { number: 16601, title: "Composer", state: "merged", reviewReady: true },
  },
  {
    sessionId: "unready",
    displayTitle: "Billing",
    updatedAt: now - minute,
    pullRequest: { number: 87, title: "Seats", state: "open" },
  },
];

test("the home lists the other sessions needing input and the open PRs ready for review, newest first", () => {
  const { input, review } = homeLists(sessions, "new");
  expect(input.map((session) => session.sessionId)).toEqual(["perm", "wait"]);
  expect(review.map((session) => session.sessionId)).toEqual(["wait"]);
  const many = Array.from({ length: 5 }, (_, index): AcpmuxSessionEntry => ({
    sessionId: `s${index}`,
    updatedAt: index,
    status: "waiting",
  }));
  expect(homeLists(many).input.map((session) => session.sessionId)).toEqual(["s4", "s3", "s2"]);
});

test("ages are compact", () => {
  expect(age(undefined, now)).toBeUndefined();
  expect(age(now - 20_000, now)).toBe("now");
  expect(age(now - 5 * minute, now)).toBe("5m ago");
  expect(age(now - 3 * 60 * minute, now)).toBe("3h ago");
  expect(age(now - 6 * 24 * 60 * minute, now)).toBe("6d ago");
  expect(age(now - 70 * 24 * 60 * minute, now)).toBe("2mo ago");
  expect(age(now - 362 * 24 * 60 * minute, now)).toBe("1y ago");
  expect(age(now - 800 * 24 * 60 * minute, now)).toBe("2y ago");
  expect(age(now + minute, now)).toBe("now");
});

test("rows show the session or PR with its project and age, and open the session", async () => {
  const doc = dom.window.document;
  const root = createRoot(doc.getElementById("root")!);
  const picked: string[] = [];
  try {
    await act(async () =>
      root.render(createElement(HomeLists, { sessions, currentId: "new", onSelect: (id: string) => picked.push(id) })),
    );
    const lists = [...doc.querySelectorAll(".acpmux-home-list")];
    expect(lists.map((list) => list.getAttribute("aria-label"))).toEqual(["Needs input", "Ready for review"]);
    const rows = (list: Element) =>
      [...list.querySelectorAll(".acpmux-home-row")].map((row) =>
        [...row.querySelectorAll("span:not(.acpmux-home-dot)")].map((span) => span.textContent),
      );
    expect(rows(lists[0]!)).toEqual([
      ["Fix the checkout page", "May I run the migration?", "web", "9m ago"],
      ["Port the sidebar", "app", "3h ago"],
    ]);
    expect(rows(lists[1]!)).toEqual([["Resume sessions after a daemon restart", "#212", "app", "3h ago"]]);
    await act(async () => lists[1]!.querySelector<HTMLButtonElement>(".acpmux-home-row")!.click());
    expect(picked).toEqual(["wait"]);
    // Nothing to list: no home lists at all.
    await act(async () => root.render(createElement(HomeLists, { sessions: [], onSelect: () => {} })));
    expect(doc.querySelector(".acpmux-home")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("an archived chat stays off Home even when it waits on the user", () => {
  const waiting: AcpmuxSessionEntry = { sessionId: "a", pendingPermissions: 1, updatedAt: now };
  const ready: AcpmuxSessionEntry = {
    sessionId: "b",
    updatedAt: now,
    pullRequest: { number: 1, title: "PR", state: "open", reviewReady: true },
  };
  expect(
    homeLists([
      { ...waiting, archived: true },
      { ...ready, archived: true },
    ]),
  ).toEqual({ input: [], review: [] });
  expect(homeLists([waiting, ready]).input.map((session) => session.sessionId)).toEqual(["a"]);
});
