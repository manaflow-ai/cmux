// l10n-allow-file: fixture conversations, not shipped UI.
// The Channels conversation list draws what is visible (the visible-only rule): at 1,000 and 10,000
// conversations it mounts the same rows and DOM nodes, and a selection, a new message in one
// conversation, a one-row scroll and a parent render draw again only the rows whose text changed.
// Before, every conversation was a mounted row, and each of those events drew every row again: the
// rows were not memoized and took the page's people map, its row actions and new handlers.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { HomeConversation } from "../src/pages/home-channels/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
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

/** A 600 px list of 44 px rows (ledger.css), a 26 px Pinned label and a 13 px line after the pins. */
const channelsSizes = (element: HTMLElement) =>
  element.classList.contains("lg-list-rows")
    ? 600
    : element.classList.contains("lg-list-section-host")
      ? 26
      : element.classList.contains("lg-list-divider")
        ? 13
        : 44;

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
const { useEffect, useRef, useState, useSyncExternalStore } = await import("react");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { withChiefNames } = await import("../src/pages/home-channels/model");
const { ConversationList } = await import("../src/pages/home-channels/ConversationList");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

const ME = "me";
const START = Date.UTC(2026, 10, 18, 9);
const strings = createStrings(table, ["en"]);

/** Conversation `index`: a room every third, else a direct message; newest first; a few pinned. */
const conversation = (index: number, pinned: number): HomeConversation => ({
  id: `c${index}`,
  owner: "local",
  title: index % 3 ? "" : `channel-${index}`,
  kind: index % 3 ? "direct" : "group",
  participants: [
    { id: ME, kind: "human", name: "Me", chief: false },
    { id: `p${index}`, kind: "human", name: `Person ${index}`, chief: false },
  ],
  lastSeq: 1,
  rev: 1,
  updatedAt: START - index * 60_000,
  lastAt: START - index * 60_000,
  unread: index % 7 === 0 ? 2 : 0,
  mentions: 0,
  muted: false,
  pinned: index < pinned,
  ...(index < pinned ? { pinPosition: index } : {}),
  lastText: `The last message in conversation ${index}`,
  lastAuthor: `p${index}`,
});

interface Driver {
  select(id: string | undefined): void;
  change(id: string): void;
  render(): void;
}

/** The list as the page holds it: a new Map on each change, every other conversation the same
 *  object; and, as the page does, new channel and people collections and new actions each render. */
function Host({ n, pinned, onDriver }: { n: number; pinned: number; onDriver(driver: Driver): void }) {
  const [conversations, setConversations] = useState(
    () => new Map(Array.from({ length: n }, (_, index) => conversation(index, pinned)).map((c) => [c.id, c])),
  );
  const [selected, setSelected] = useState<string | undefined>(undefined);
  const [, setTick] = useState(0);
  // The test's handle on the state, a fresh object handed over once mounted (the setters are stable).
  useEffect(
    () =>
      onDriver({
        select: setSelected,
        change: (id) =>
          setConversations((old) => {
            const next = new Map(old);
            const before = old.get(id)!;
            next.set(id, { ...before, rev: before.rev + 1, lastText: `${before.lastText} (edited)` });
            return next;
          }),
        render: () => setTick((tick) => tick + 1),
      }),
    [onDriver],
  );
  const people = new Map([...conversations.values()].slice(0, 50).flatMap((c) => c.participants.map((p) => [p.id, p])));
  return (
    <ConversationList
      conversations={conversations}
      channels={new Set([...conversations.values()].filter((c) => c.kind === "group").map((c) => c.id))}
      people={people}
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
  );
}

async function mount(n: number, pinned = 0) {
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  let held: Driver | undefined;
  const onDriver = (next: Driver) => {
    held = next;
  };
  await act(async () => root!.render(<Host n={n} pinned={pinned} onDriver={onDriver} />));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  if (!held) throw new Error("the host did not hand over its driver");
  const driver: Driver = held;
  return { driver, list: host.querySelector<HTMLElement>(".lg-list-rows")! };
}

const ROWS = ".lg-list-group > li";
const rows = () => host.querySelectorAll(ROWS);
const ids = () => [...host.querySelectorAll<HTMLElement>("[data-list-row]")].map((row) => row.dataset.listRow!);
// The nearest component above each row's node: the memo row, or (before) the list itself.
const renders = mountedRowRenders(() => host.querySelectorAll(ROWS));
const nodes = (list: HTMLElement) => list.querySelectorAll("*").length;

/** Mounted rows, DOM nodes and the row renders of one selection, one change, one-row scroll and parent render. */
async function measure(n: number) {
  const { driver, list } = await mount(n);
  const mounted = { rows: rows().length, nodes: nodes(list) };

  renders.mark();
  await act(async () => host.querySelectorAll<HTMLElement>("[data-list-row]")[2]!.click());
  const select = renders.since();

  renders.mark();
  await act(async () => driver.change("c4"));
  const change = renders.since();

  renders.mark();
  await act(async () => {
    list.scrollTop += 44;
    list.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = renders.since();

  renders.mark();
  await act(async () => driver.render());
  const parent = renders.since();
  return { n, mounted, select, change, scroll, parent };
}

test("1,000 and 10,000 conversations mount the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the viewport's rows (600 / 44) and about one viewport each side, not the list.
  for (const run of [small, large]) {
    expect(run.mounted.rows).toBeGreaterThan(13);
    expect(run.mounted.rows).toBeLessThanOrEqual(50);
  }
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: a selection draws the row it takes (none was selected).
    expect(run.select).toBeLessThanOrEqual(2);
    // A new message in one conversation draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
    // One row's scroll draws only the rows it brings in; the mounted ones keep their place.
    expect(run.scroll).toBeLessThanOrEqual(2);
    // A parent render (new collections, new actions) draws no row.
    expect(run.parent).toBe(0);
  }
});

test("the active row, the focused row and the Pinned label stay mounted far from the window", async () => {
  const { driver, list } = await mount(1_000, 3);
  // The Pinned label names its list; the pins come first, then the line, then the rest.
  expect(host.querySelector("#lg-list-pinned")?.textContent).toBeTruthy();
  expect(ids().slice(0, 4)).toEqual(["c0", "c1", "c2", "c3"]);
  const first = host.querySelector<HTMLElement>('[data-list-row="c5"]')!;
  await act(async () => first.focus());
  await act(async () => driver.select("c900"));
  await act(async () => {
    list.scrollTop = 20_000;
    list.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(first.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(first);
  expect(host.querySelector("#lg-list-pinned")).not.toBeNull();
  const active = host.querySelector<HTMLElement>("[data-list-row][aria-current]");
  expect(active?.dataset.listRow).toBe("c900");
  // Screen readers hear each row's place in its own list ("898 of 997" among the rest).
  expect(active?.closest("li")?.getAttribute("aria-posinset")).toBe("898");
  expect(active?.closest("li")?.getAttribute("aria-setsize")).toBe("997");
  // DOM order is list order, so a screen reader reads the mounted rows top to bottom.
  const shown = ids().map((id) => Number(id.slice(1)));
  expect(shown).toEqual([...shown].sort((a, b) => a - b));
  expect(rows().length).toBeLessThanOrEqual(50);
});

test("a full reload that changes one conversation draws that row alone, a renamed Chief's row too", async () => {
  // Conversation 1 is a Chief's direct message the Chief's record renames (withChiefNames).
  const reply = (edited: boolean) => ({
    me: { id: ME, kind: "human", name: "Me", chief: false },
    rev: 1,
    // Every reload sends every conversation as new objects, as the owner does.
    conversations: Array.from({ length: 1_000 }, (_, index) => {
      const c = conversation(index, 0);
      if (index === 1) c.participants[1] = { ...c.participants[1]!, kind: "agent", chief: true };
      return edited && index === 4 ? { ...c, rev: 2, lastText: "Edited" } : c;
    }),
  });
  let edited = false;
  const client = {
    call: async (op: string) => {
      if (op === HomeOps.inbox) return reply(edited);
      throw new Error(`not in this test: ${op}`);
    },
  };
  const store = new HomeChannelsStore(client as never);
  const chiefs = new Map([["p1", { name: "Renamed Chief" }]]);
  const none = new Set<string>();
  function Page() {
    const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
    const renamed = useRef(new Map());
    const conversations = withChiefNames(snap.conversations, none, ME, chiefs, renamed.current);
    return (
      <ConversationList
        conversations={conversations}
        channels={none}
        people={new Map()}
        activity={new Map()}
        me={ME}
        selected={undefined}
        strings={strings}
        onSelect={() => undefined}
        onOpenPalette={() => undefined}
        actions={{
          canPin: true,
          onPin: () => undefined,
          onMarkUnread: () => undefined,
          onMarkRead: () => undefined,
          onCopyLink: () => undefined,
        }}
      />
    );
  }
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(<Page />));
  await act(async () => store.reloadInbox());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(host.querySelector('[data-list-row="c1"]')?.getAttribute("data-name")).toBe("Renamed Chief");

  renders.mark();
  edited = true;
  await act(async () => store.reloadInbox());
  const reload = renders.since();
  console.log(JSON.stringify({ reload }));
  expect(host.querySelector('[data-list-row="c4"]')?.textContent).toContain("Edited");
  expect(reload).toBeLessThanOrEqual(1);
});
