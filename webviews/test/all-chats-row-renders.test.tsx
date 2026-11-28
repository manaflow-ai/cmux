import { createRoot, rowRenders } from "./support/rowRenders";
// All chats (New Tab, History): a row renders only when its own chat changed. Selecting or opening
// one chat, a push that changes one chat, a scroll step, a pointer over a row, a minute of the
// clock, and a page render with the same chats render no other row. Each chat row is ChatRow; a
// live chat's is LiveChatRow. AgentMark (the agent's glyph inside every row) is counted too: before
// rows had their own boundary there was no ChatRow, and every event drew every mounted row's mark.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

const MINUTE = 60_000;
// A whole minute, as the shared clock reads it: ages are exact.
const T0 = Math.floor(Date.UTC(2026, 10, 18, 12, 0) / MINUTE) * MINUTE;
let clock = T0;
const realNow = Date.now;

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>"));
  // TanStack Virtual sizes the list from its scroller; JSDOM lays nothing out, so every element
  // reports an 800 px box: 27 rows of 30 px show, plus the overscan.
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
  Date.now = () => clock;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  clock = T0;
  const { resetSettledChatsForTests } = await import("../src/agent-session/acpmux/newtab/settledCache");
  const { resetDeviceChatsForTests } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  resetSettledChatsForTests();
  resetDeviceChatsForTests();
});

afterAll(async () => {
  Date.now = realNow;
  await teardownDom(saved, { scope });
});

type Chat = { key: string; harness: string; title?: string; cwd?: string; updatedAt: number };
/// `count` chats, newest first, an hour apart from 5 h ago (their ages hold for many minutes), but
/// chat-2, 2 minutes old: the one whose "2m" becomes "3m" at the next minute.
const chatsOf = (count: number): Chat[] =>
  Array.from({ length: count }, (_, i) => ({
    key: `claude-code:chat-${i}`,
    harness: "claude",
    title: `Chat ${i}`,
    cwd: `/Users/me/src/project-${i % 4}`,
    updatedAt: i === 2 ? T0 - 2 * MINUTE : T0 - (5 + i) * 60 * MINUTE,
  }));

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const rowButton = (title: string) =>
  [...host.querySelectorAll<HTMLElement>(".nt-all-row")].find(
    (button) => button.querySelector(".nt-all-title")?.textContent === title,
  )!;
const mounted = () => host.querySelectorAll(".nt-all-list .nt-all-item").length;
/// Rows drawn by the last event: ChatRow renders, and no row's glyph drawn without its row. A row's
/// glyph is two components named AgentMark (the New Tab one, and the shared one BrandMark draws), so
/// at most two per row drawn; `live` counts live chat rows drawn by the event too.
const expectRows = (changed: number, live = 0) => {
  if (process.env.ROWS_DEBUG) console.log(JSON.stringify(rowRenders.all()));
  expect(rowRenders.count("ChatRow")).toBe(changed);
  expect(rowRenders.count("AgentMark")).toBeLessThanOrEqual(2 * (changed + live));
};

async function mountList(
  chats: () => Chat[],
  props: Partial<
    React.ComponentProps<typeof import("../src/agent-session/acpmux/newtab/AllChatsList").AllChatsList>
  > = {},
) {
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const load = async () => ({ chats: chats(), ready: true });
  root = createRoot(host);
  const render = (extra: typeof props = {}) =>
    root!.render(<AllChatsList load={load} onOpen={() => new Promise(() => {})} {...props} {...extra} />);
  await act(async () => render());
  await settle();
  return { render: (extra: typeof props = {}) => act(async () => render(extra)) };
}

const click = (element: HTMLElement, init: MouseEventInit) =>
  act(async () => {
    element.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0, ...init }));
    element.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0, detail: 1, ...init }));
  });

test("selecting a chat, extending the selection and clearing it draw only the chats whose mark changed", async () => {
  await mountList(() => chatsOf(100), { onBring: () => undefined });
  expect(mounted()).toBeGreaterThan(30);

  rowRenders.reset();
  await click(rowButton("Chat 4"), { metaKey: true });
  expect(rowButton("Chat 4").dataset.selected).toBe("true");
  expectRows(1);

  rowRenders.reset();
  await click(rowButton("Chat 6"), { metaKey: true });
  expectRows(1);

  // Shift-click from Chat 6 to Chat 9: 6..9 selected, Chat 4 not; 7, 8, 9 and 4 changed.
  rowRenders.reset();
  await click(rowButton("Chat 9"), { shiftKey: true });
  expect([...host.querySelectorAll(".nt-all-row[data-selected]")].length).toBe(4);
  expectRows(4);

  rowRenders.reset();
  await act(async () =>
    window.document.body.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
  );
  expect(host.querySelectorAll(".nt-all-row[data-selected]").length).toBe(0);
  expectRows(4);
});

test("opening a chat draws its row alone (its busy mark)", async () => {
  await mountList(() => chatsOf(100));
  rowRenders.reset();
  await click(rowButton("Chat 5"), {});
  expect(rowButton("Chat 5").getAttribute("aria-busy")).toBe("true");
  expectRows(1);
});

test("a pointer over a row draws no row (hover is CSS)", async () => {
  await mountList(() => chatsOf(100));
  rowRenders.reset();
  await act(async () => {
    const button = rowButton("Chat 3");
    button.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
    button.dispatchEvent(new window.MouseEvent("mouseenter"));
  });
  expectRows(0);
});

test("a push that renames one chat draws that row alone, though every row comes back as a new object", async () => {
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  let chats = chatsOf(100);
  await mountList(() => chats.map((chat) => ({ ...chat })));
  chats = chats.map((chat) => (chat.key === "claude-code:chat-7" ? { ...chat, title: "Renamed" } : chat));
  rowRenders.reset();
  await act(async () => setDeviceChats([{ key: "claude-code:chat-7", harness: "claude", updatedAt: T0 }]));
  await settle();
  expect(rowButton("Renamed")).toBeTruthy();
  expectRows(1);
});

test("a minute of the clock draws no row; only the one age whose words change", async () => {
  await mountList(() => chatsOf(100));
  expect(rowButton("Chat 2").querySelector(".nt-all-meta")?.textContent).toBe("2m");
  rowRenders.reset();
  clock = T0 + MINUTE;
  // Showing the page runs every page clock's catch-up tick at once (ui/pageClock.ts), as a timer would.
  await act(async () => window.document.dispatchEvent(new window.Event("visibilitychange")));
  expect(rowButton("Chat 2").querySelector(".nt-all-meta")?.textContent).toBe("3m");
  expectRows(0);
  expect(rowRenders.count("ChatAge")).toBe(1);
});

test("a scroll step of one row draws the row that comes into view, no other", async () => {
  await mountList(() => chatsOf(100));
  const scroller = host.querySelector<HTMLElement>(".nt-all-list")!;
  let top = 0;
  Object.defineProperty(scroller, "scrollTop", { configurable: true, get: () => top, set: (v: number) => (top = v) });
  // Past the overscan first, so the next step both adds a row below and drops one above.
  await act(async () => {
    top = 20 * 30;
    scroller.dispatchEvent(new window.Event("scroll"));
  });
  await settle();
  const before = mounted();
  rowRenders.reset();
  await act(async () => {
    top = 21 * 30;
    scroller.dispatchEvent(new window.Event("scroll"));
  });
  await settle();
  expect(mounted()).toBe(before);
  expectRows(1);
});

test("a page in the middle draws only the rows it adds; the last page tells every row the total once", async () => {
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const page = (from: number, more: boolean) => ({
    chats: Array.from({ length: 10 }, (_, index) => ({
      key: `claude-code:p${from + index}`,
      harness: "claude-code",
      title: `Paged ${from + index}`,
      cwd: "/tmp/cmux",
      updatedAt: 1_000_000 - (from + index),
    })),
    ready: true,
    ...(more ? { nextCursor: `c${from + 10}` } : {}),
  });
  // Each later page waits until the test lets it through; the third is the last.
  const gates = [0, 1].map(() => {
    let release: () => void = () => {};
    const open = new Promise<void>((resolve) => (release = resolve));
    return { open, release };
  });
  const load = async (params?: { cursor?: string }) => {
    if (!params?.cursor) return page(0, true);
    const from = Number(params.cursor.slice(1));
    await gates[from / 10 - 1]!.open;
    return page(from, from < 20);
  };
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => new Promise(() => {})} />));
  await settle();
  const keys = () =>
    new Set(
      [...host.querySelectorAll<HTMLElement>(".nt-all-item[role='listitem']")].map((row) => row.textContent ?? ""),
    );
  const before = keys();
  expect(before.size).toBe(10);
  rowRenders.reset();
  gates[0]!.release();
  await settle();
  await settle();
  const added = [...keys()].filter((key) => !before.has(key)).length;
  expect(added).toBe(10);
  // The ten new rows mount; the ten already shown do not draw again (their size stays "unknown").
  expectRows(added);
  expect(host.querySelector(".nt-all-item[role='listitem']")?.getAttribute("aria-setsize")).toBe("-1");
  // The last page: the total is known, so each mounted row draws once to say it.
  const shown = keys();
  rowRenders.reset();
  gates[1]!.release();
  await settle();
  await settle();
  const mounted = keys().size;
  expect(rowRenders.count("ChatRow")).toBe(mounted);
  expect(mounted).toBeGreaterThan(shown.size - 1);
  expect(host.querySelector(".nt-all-item[role='listitem']")?.getAttribute("aria-setsize")).toBe("30");
});

test("the page drawing again with the same chats, live chats and leaders draws no row", async () => {
  const live = () => [
    { id: "s1", title: "Working", harness: "claude", state: "running" as const, label: "Working" },
    { id: "s2", title: "Asking", harness: "codex", state: "input" as const, label: "Needs input" },
  ];
  const leads = () => [{ id: "s3", title: "Lead", state: "idle" as const, label: "2 reports" }];
  const list = await mountList(() => chatsOf(100), { active: live(), leads: leads(), onOpenActive: () => {} });
  expect(host.querySelectorAll(".nt-all-active .nt-all-row").length).toBe(3);
  rowRenders.reset();
  // The New Tab page builds new live chat objects and new callbacks on each of its renders.
  await list.render({ active: live(), leads: leads(), onOpenActive: () => {} });
  expectRows(0);
  expect(rowRenders.count("LiveChatRow")).toBe(0);

  // One live chat changes its state: its row alone.
  rowRenders.reset();
  const next = live();
  next[0] = { ...next[0]!, state: "input", label: "Needs input" };
  await list.render({ active: next, leads: leads(), onOpenActive: () => {} });
  expect(rowRenders.count("LiveChatRow")).toBe(1);
  expectRows(0, 1);
});

for (const n of [1_000, 10_000]) {
  test(`${n.toLocaleString("en")} chats mount only the rows near the viewport (jsdom count)`, async () => {
    await mountList(() => chatsOf(n));
    const list = host.querySelector(".nt-all-list")!;
    const rows = mounted();
    const nodes = list.querySelectorAll("*").length;
    console.log(`all-chats N=${n}: mounted rows ${rows}, DOM nodes in list ${nodes}`);
    expect(rows).toBeLessThan(60);
  });
}

test("an age's label clock wakes at exactly the first minute its words change", async () => {
  const { ageLabel, nextAgeLabel } = await import("../src/agent-session/acpmux/newTabModel");
  const t = ((key: string, vars?: Record<string, unknown>) => `${key}${JSON.stringify(vars ?? {})}`) as never;
  const end = T0 + 8 * 24 * 60 * MINUTE;
  for (const offset of [0, 1, 17_000, 29_999, 30_000, 30_001, 45_000, 59_999]) {
    const at = T0 + offset;
    for (let now = T0; now < end;) {
      const words = ageLabel(at, now, t);
      let change = now + MINUTE;
      while (change <= end && ageLabel(at, change, t) === words) change += MINUTE;
      const next = nextAgeLabel(at, now);
      expect(next).toBe(change > end ? Infinity : change);
      now = next === Infinity ? end : next;
    }
  }
});
