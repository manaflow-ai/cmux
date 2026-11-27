// l10n-allow-file: fixture conversations, not shipped UI.
// The windowed Channels list keeps every route to a row working at 1,000 conversations, with the
// row near the end: Tab and Shift-Tab walk the rows in list order (each row is a button, a tab stop,
// as every row was when all were mounted), also from a row the list scrolled away from and into the
// list from the controls before and after it; and a selection made far from the window (a link to a
// conversation, the palette, Option-Up/Down, the host's next conversation, all of which set the
// list's `selected`) mounts the row, marks it active and scrolls it into view, also when the
// selection came before its conversation did. jsdom moves no focus on Tab, so `tab()` does what a
// browser does: the next tab stop in document order takes focus and scrolls into view.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { HomeConversation } from "../src/pages/home-channels/types";
import { settleReact } from "./support/domTeardown";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

const VIEW = 600;
const ROW = 44;
/** A 600 px list of 44 px rows (ledger.css), a 26 px Pinned label and a 13 px line after the pins. */
const channelsSizes = (element: HTMLElement) =>
  element.classList.contains("lg-list-rows")
    ? VIEW
    : element.classList.contains("lg-list-section-host")
      ? 26
      : element.classList.contains("lg-list-divider")
        ? 13
        : ROW;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/home-channels/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  scope.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  installVirtualSizes(dom.window, channelsSizes);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { useEffect, useState } = await import("react");
const { ConversationList } = await import("../src/pages/home-channels/ConversationList");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

const ME = "me";
const N = 1_000;
const START = Date.UTC(2026, 10, 18, 9);
const strings = createStrings(table, ["en"]);

/** Conversation `index`, newest first: `c0` on top, `c999` at the end. */
const conversation = (index: number): HomeConversation => ({
  id: `c${index}`,
  owner: "local",
  title: "",
  kind: "direct",
  participants: [
    { id: ME, kind: "human", name: "Me", chief: false },
    { id: `p${index}`, kind: "human", name: `Person ${index}`, chief: false },
  ],
  lastSeq: 1,
  rev: 1,
  updatedAt: START - index * 60_000,
  lastAt: START - index * 60_000,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
  lastText: `The last message in conversation ${index}`,
  lastAuthor: `p${index}`,
});
const all = (n: number) => new Map(Array.from({ length: n }, (_, index) => conversation(index)).map((c) => [c.id, c]));

interface Driver {
  select(id: string | undefined): void;
  load(n: number): void;
}

/** The list between a control before it (inside it: the search field) and one after it (the
 *  conversation pane's first control), as the page lays them out. */
function Host({ n, onDriver }: { n: number; onDriver(driver: Driver): void }) {
  const [conversations, setConversations] = useState(() => all(n));
  const [selected, setSelected] = useState<string | undefined>(undefined);
  // The test's handle on the state, a fresh object handed over once mounted (the setters are stable).
  useEffect(() => onDriver({ select: setSelected, load: (count) => setConversations(all(count)) }), [onDriver]);
  return (
    <>
      <ConversationList
        conversations={conversations}
        channels={new Set()}
        people={new Map()}
        activity={new Map()}
        me={ME}
        selected={selected}
        strings={strings}
        onSelect={(id) => setSelected(id)}
        onOpenPalette={() => undefined}
        actions={{
          canPin: true,
          onPin: () => undefined,
          onMarkUnread: () => undefined,
          onMarkRead: () => undefined,
          onCopyLink: () => undefined,
        }}
      />
      <button type="button" id="after">
        After
      </button>
    </>
  );
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

async function mount(n = N) {
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  let held: Driver | undefined;
  const onDriver = (next: Driver) => {
    held = next;
  };
  await act(async () => root!.render(<Host n={n} onDriver={onDriver} />));
  await settle();
  if (!held) throw new Error("the host did not hand over its driver");
  const driver: Driver = held;
  return { driver, list: host.querySelector<HTMLElement>(".lg-list-rows")! };
}

const rowEl = (id: string) => host.querySelector<HTMLElement>(`[data-list-row="${id}"]`);
const focusedId = () => (dom.window.document.activeElement as HTMLElement | null)?.dataset?.listRow;
/** A row's offset in the list (its item's translateY). */
const topOf = (row: HTMLElement) => Number(/translateY\((-?[\d.]+)px\)/.exec(row.closest("li")!.style.transform)![1]);
const inView = (list: HTMLElement, row: HTMLElement) =>
  topOf(row) >= list.scrollTop - 0.5 && topOf(row) + ROW <= list.scrollTop + VIEW + 0.5;

async function scrollTo(list: HTMLElement, top: number) {
  await act(async () => {
    list.scrollTop = top;
    list.dispatchEvent(new dom.window.Event("scroll"));
  });
  await settle();
}

const TABBABLE = "button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex='-1'])";

/** One Tab as a browser does it: the next tab stop in document order takes focus and scrolls into
 *  view in its scroller. */
async function tab(list: HTMLElement, shift = false) {
  const document = dom.window.document;
  const from = document.activeElement as HTMLElement;
  const stops = [...document.querySelectorAll<HTMLElement>(TABBABLE)];
  const next = stops[stops.indexOf(from) + (shift ? -1 : 1)];
  await act(async () => next?.focus());
  if (next && list.contains(next) && !inView(list, next)) {
    const top = topOf(next);
    await scrollTo(list, top < list.scrollTop ? top : top + ROW - VIEW);
  }
  await settle();
  await settle();
}

test("Tab walks the rows near the end one by one, then leaves the list", async () => {
  const { list } = await mount();
  await scrollTo(list, 960 * ROW);
  await act(async () => rowEl("c960")!.focus());
  for (let index = 961; index < N; index += 1) {
    await tab(list);
    expect(focusedId()).toBe(`c${index}`);
  }
  await tab(list);
  expect(dom.window.document.activeElement?.id).toBe("after");
});

test("Tab from a focused row the list scrolled away from goes to the next row", async () => {
  const { list } = await mount();
  await scrollTo(list, 975 * ROW);
  await act(async () => rowEl("c980")!.focus());
  // The wheel takes the list back to the top; the focused row stays mounted.
  await scrollTo(list, 0);
  expect(rowEl("c980")).not.toBeNull();
  await tab(list);
  expect(focusedId()).toBe("c981");
  expect(inView(list, rowEl("c981")!)).toBe(true);
});

test("Shift-Tab from a focused row the list scrolled away from goes to the row before it", async () => {
  const { list } = await mount();
  await scrollTo(list, 975 * ROW);
  await act(async () => rowEl("c980")!.focus());
  await scrollTo(list, 0);
  await tab(list, true);
  expect(focusedId()).toBe("c979");
  expect(inView(list, rowEl("c979")!)).toBe(true);
});

test("Shift-Tab from the control after the list enters it at the last conversation", async () => {
  const { list } = await mount();
  await act(async () => dom.window.document.getElementById("after")!.focus());
  await tab(list, true);
  expect(focusedId()).toBe(`c${N - 1}`);
  expect(inView(list, rowEl(`c${N - 1}`)!)).toBe(true);
});

test("Tab from the search field enters the list at the first conversation", async () => {
  const { list } = await mount();
  await scrollTo(list, 970 * ROW);
  await act(async () => host.querySelector<HTMLElement>(".lg-search")!.focus());
  await tab(list);
  expect(focusedId()).toBe("c0");
  expect(inView(list, rowEl("c0")!)).toBe(true);
});

test("a selection far down (link, palette, Option-Down, host move) marks the row and scrolls to it", async () => {
  const { driver, list } = await mount();
  await act(async () => driver.select("c990"));
  await settle();
  const active = host.querySelector<HTMLElement>("[data-list-row][aria-current]");
  expect(active?.dataset.listRow).toBe("c990");
  expect(inView(list, active!)).toBe(true);
  // Option-Down from there, after the wheel took the list back to the top.
  await scrollTo(list, 0);
  await act(async () => driver.select("c991"));
  await settle();
  expect(inView(list, rowEl("c991")!)).toBe(true);
});

test("a selection that comes before its conversation is revealed once the conversation does", async () => {
  // A reload opens the link's conversation before the inbox reply lists it.
  const { driver, list } = await mount(10);
  await act(async () => driver.select("c995"));
  await settle();
  await act(async () => driver.load(N));
  await settle();
  const active = host.querySelector<HTMLElement>("[data-list-row][aria-current]");
  expect(active?.dataset.listRow).toBe("c995");
  expect(inView(list, active!)).toBe(true);
});

test("the narrow page's Back finds the active row to focus however far the list scrolled", async () => {
  const { driver, list } = await mount();
  await act(async () => driver.select("c990"));
  await scrollTo(list, 0);
  // HomeChannelsPage's Back: focus `[data-list-row][aria-current]`.
  const target = dom.window.document.querySelector<HTMLElement>("[data-list-row][aria-current]");
  expect(target?.dataset.listRow).toBe("c990");
  await act(async () => target!.focus({ preventScroll: true }));
  expect(focusedId()).toBe("c990");
});
