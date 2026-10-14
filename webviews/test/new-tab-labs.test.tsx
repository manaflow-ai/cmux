// Labs on the New Tab page (hq#1980): in team builds (nightly and dev, `data-labs-team` on
// <html>) the page offers the Labs flags as quick toggles, so the team tries prototypes where they
// start work. The section is one quiet line, "Labs (N on)" or plain "Labs" with none on, until it
// is opened in place, and stays open or closed for this viewer; a row's right-click menu turns the
// flag on or off and opens All Labs…. Open, each
// flag is a row with its name, its one-line intent, a "New" or "Expires soon" hint and a toggle,
// the flags this viewer toggled last first, else the newest. A toggle asks the app
// (`newTab.setLab`), which saves it and answers with a new `data-labs`; "All Labs…" opens
// Settings > Labs. Release builds show nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "localStorage",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "MutationObserver",
  "MouseEvent",
  "cmuxLabsFixture",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
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
    localStorage: window.localStorage,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    MouseEvent: window.MouseEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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

const noop = () => {};

type Options = {
  team?: boolean;
  on?: string;
  flags?: Record<string, unknown>;
  onSetLab?: (flag: string, on: boolean) => void;
  onShowLabs?: () => void;
};

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 14, 12);
const day = (offset: number) => new Date(NOW + offset * DAY).toISOString().slice(0, 10);
const flag = (title: string, created: number, expires: number) => ({
  owner: "test",
  created: day(created),
  expires: day(expires),
  cohort: "off",
  title,
  intent: `${title}: what it tries`,
});
// Four flags: one made yesterday ("New"), one that ends in two days ("Expires soon"), two plain.
const FLAGS = {
  oldest: flag("Oldest", -12, 9),
  ending: flag("Ending", -11, 2),
  middle: flag("Middle", -6, 8),
  fresh: flag("Fresh", -1, 13),
};

async function page(options: Options = {}) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const html = document.documentElement;
  if (options.team) html.setAttribute("data-labs-team", "1");
  else html.removeAttribute("data-labs-team");
  html.setAttribute("data-labs", options.on ?? "");
  // The page's flags; the real table (labs.generated.ts) when a test does not set its own.
  if (options.flags) scope.cmuxLabsFixture = options.flags;
  else delete scope.cmuxLabsFixture;
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        now={NOW}
        cwd="/Users/you/src/app"
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onSetLab={options.onSetLab ?? noop}
        onShowLabs={options.onShowLabs ?? noop}
      />,
    ),
  );
}

const opener = () => host.querySelector<HTMLButtonElement>("[data-labs-open]")!;
const rows = () => [...host.querySelectorAll<HTMLElement>("[data-lab]")];
const order = () => rows().map((row) => row.dataset.lab);
const toggle = (name: string) =>
  host.querySelector<HTMLInputElement>(`[data-lab="${name}"] input[type=checkbox]`)!;
const open = () => act(async () => opener().click());

test("outside a team build the page has no Labs section", async () => {
  await page({ team: false, flags: FLAGS });
  expect(opener()).toBeNull();
  expect(rows()).toEqual([]);
});

test("closed, Labs is one quiet line that says how many flags are on", async () => {
  localStorage.clear();
  await page({ team: true, flags: FLAGS, on: "middle fresh" });
  expect(opener().textContent).toContain("Labs (2 on)");
  expect(opener().getAttribute("aria-expanded")).toBe("false");
  expect(rows()).toEqual([]);

  // The count follows the app's answer.
  await act(async () => document.documentElement.setAttribute("data-labs", "fresh"));
  expect(opener().textContent).toContain("Labs (1 on)");
});

test("open, each flag is a row with its name, its intent and a toggle the app saves", async () => {
  const set: [string, boolean][] = [];
  let shown = 0;
  await page({
    team: true,
    flags: FLAGS,
    onSetLab: (name, on) => set.push([name, on]),
    onShowLabs: () => shown++,
  });
  await open();
  expect(opener().getAttribute("aria-expanded")).toBe("true");
  for (const [name, value] of Object.entries(FLAGS)) {
    const row = host.querySelector(`[data-lab="${name}"]`)!;
    expect(row.textContent).toContain(value.title);
    expect(row.textContent).toContain(value.intent);
    expect(toggle(name).checked).toBe(false);
  }
  await act(async () => toggle("middle").click());
  expect(set).toEqual([["middle", true]]);

  // The app's answer is the new `data-labs`; the row follows it.
  await act(async () => document.documentElement.setAttribute("data-labs", "middle"));
  expect(toggle("middle").checked).toBe(true);
  await act(async () => toggle("middle").click());
  expect(set.at(-1)).toEqual(["middle", false]);

  await act(async () => host.querySelector<HTMLButtonElement>("[data-show-labs]")!.click());
  expect(shown).toBe(1);

  // Opening the line again closes it.
  await open();
  expect(rows()).toEqual([]);
});

test("a flag made in the last three days says New, one ending within three days says Expires soon", async () => {
  await page({ team: true, flags: FLAGS });
  await open();
  const hint = (name: string) =>
    host.querySelector(`[data-lab="${name}"] [data-lab-hint]`)?.textContent ?? "";
  expect(hint("fresh")).toBe("New");
  expect(hint("ending")).toBe("Expires soon");
  expect(hint("middle")).toBe("");
  expect(hint("oldest")).toBe("");
});

test("the flags this viewer toggled last come first, then the newest; a toggle does not move rows", async () => {
  localStorage.clear();
  await page({ team: true, flags: FLAGS });
  await open();
  expect(order()).toEqual(["fresh", "middle", "ending", "oldest"]);

  await act(async () => toggle("oldest").click());
  await act(async () => toggle("ending").click());
  // The rows stay where they were while the list is open, under the pointer.
  expect(order()).toEqual(["fresh", "middle", "ending", "oldest"]);

  // The next time the page opens (open, as this viewer left it), the last toggled come first.
  await page({ team: true, flags: FLAGS });
  expect(order()).toEqual(["ending", "oldest", "fresh", "middle"]);
});

test("without readable storage the order is the newest first", async () => {
  const real = Object.getOwnPropertyDescriptor(scope, "localStorage");
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    get() {
      throw new Error("blocked");
    },
  });
  try {
    await page({ team: true, flags: FLAGS });
    await open();
    expect(order()).toEqual(["fresh", "middle", "ending", "oldest"]);
    await act(async () => toggle("oldest").click());
    expect(toggle("oldest")).not.toBeNull();
  } finally {
    if (real) Object.defineProperty(scope, "localStorage", real);
  }
});

const rightClick = (element: Element) =>
  act(async () =>
    element.dispatchEvent(
      new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 }),
    ),
  );
const menuItem = (label: string) =>
  [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (entry) => entry.textContent === label,
  );

test("with no flag on, the line says plain Labs", async () => {
  localStorage.clear();
  await page({ team: true, flags: FLAGS, on: "" });
  expect(opener().textContent).toBe("Labs");
  await act(async () => document.documentElement.setAttribute("data-labs", "oldest"));
  expect(opener().textContent).toBe("Labs (1 on)");
});

test("the line stays open or closed for this viewer, and starts closed", async () => {
  localStorage.clear();
  await page({ team: true, flags: FLAGS });
  expect(rows()).toEqual([]);
  await open();
  // The next New Tab page opens with the rows showing.
  await page({ team: true, flags: FLAGS });
  expect(opener().getAttribute("aria-expanded")).toBe("true");
  expect(order()).toEqual(["fresh", "middle", "ending", "oldest"]);
  await open();
  await page({ team: true, flags: FLAGS });
  expect(rows()).toEqual([]);
});

test("a row's right-click menu turns its flag on or off and opens All Labs…", async () => {
  localStorage.clear();
  const set: [string, boolean][] = [];
  let shown = 0;
  await page({
    team: true,
    flags: FLAGS,
    on: "middle",
    onSetLab: (name, on) => set.push([name, on]),
    onShowLabs: () => shown++,
  });
  await open();
  await rightClick(host.querySelector('[data-lab="fresh"]')!);
  expect(menuItem("Turn Off")).toBeUndefined();
  await act(async () => menuItem("Turn On")!.click());
  expect(set).toEqual([["fresh", true]]);

  await rightClick(host.querySelector('[data-lab="middle"]')!);
  expect(menuItem("Turn On")).toBeUndefined();
  await act(async () => menuItem("Turn Off")!.click());
  expect(set.at(-1)).toEqual(["middle", false]);

  await rightClick(host.querySelector('[data-lab="oldest"]')!);
  await act(async () => menuItem("All Labs…")!.click());
  expect(shown).toBe(1);
});
