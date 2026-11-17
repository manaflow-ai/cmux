// l10n-allow-file: test fixtures.
// cmux#37736 round 6, the list package: the native list's behaviours the React Messages list lacked.
// Teammate rows and the search's Teammates section (E), the Chief tags (H) and the Cloud note (G)
// from the app's `list` stream, the header's sizes at the sidebar's density and text size (B), the
// header band that moves the window (C), a row's swipe (D), the plain Chief avatar (I), the
// divider's lit band (J), the width kept per window by the app and saved only by a drag (K), a
// letter typed in the list going to the message box (A), and a gone Chief conversation's draft
// carried to the live Chief (P).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    pretendToBeVisual: true,
    url: "http://localhost/",
  });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  (dom.window.HTMLElement.prototype as unknown as { setPointerCapture(): void }).setPointerCapture = () => {};
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    WheelEvent: dom.window.WheelEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { MessagesApp } = await import("../src/pages/home-messages/App");
const { ConversationList } = await import("../src/pages/home-messages/list/ConversationList");
const { listModel } = await import("../src/pages/home-messages/list/model");
const { headerLayout, headerSizes, HEADER } = await import("../src/pages/home-messages/list/layout");
const { swipeActions, swipeBy, swipeEnd, SWIPE_BUTTON, SWIPE_END_MS } =
  await import("../src/pages/home-messages/list/swipe");
const { parseListFacts } = await import("../src/pages/home-messages/host");
const { MessagesNav } = await import("../src/pages/home-messages/nav");
const { followTyping, isTypedKey } = await import("../src/pages/home-messages/pageCommands");
const { MessagesSheetOps } = await import("../src/pages/home-messages/sheets/actions");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { createStrings } = await import("../src/pages/shared/i18n");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type ListFacts = import("../src/pages/home-messages/types").ListFacts;
type MessagesHost = import("../src/pages/home-messages/types").MessagesHost;
type Rect = import("../src/pages/home-messages/types").Rect;

const strings = createStrings({ en: {} }, ["en"]);
const settle = (ms = 0) => act(async () => new Promise((resolve) => setTimeout(resolve, ms)));
const NOW = Date.now();
const words = {
  untitled: "Conversation",
  yesterday: "Yesterday",
  channel: "Channel",
  mentioned: "Mentions you",
  unread: (n: number) => `${n} unread`,
};
const me = { id: "me", kind: "human" as const, name: "Me", chief: false };
const chiefPerson = { id: "chief-1", kind: "agent" as const, name: "Chief", chief: true };
const grace = { id: "grace", kind: "human" as const, name: "Grace Hopper", chief: false };

function conversation(id: string, patch: Partial<HomeConversation> = {}): HomeConversation {
  return {
    id,
    owner: "local",
    title: "",
    kind: "direct",
    participants: [me, grace],
    lastSeq: 5,
    rev: 1,
    updatedAt: NOW,
    lastAt: NOW - 60_000,
    lastText: "hello",
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    ...patch,
  };
}

const chief = conversation("c-chief", { kind: "chief", participants: [me, chiefPerson], title: "Chief" });
const dm = conversation("c-grace");

function storeClient(conversations: HomeConversation[]) {
  return {
    call: async (op: string, params?: { conversation?: string }) => {
      if (op === HomeOps.inbox) return { me, conversations, rev: 1 };
      if (op === HomeOps.page) {
        const found = conversations.find((c) => c.id === params?.conversation) ?? conversations[0];
        return { conversation: found, messages: [], hasOlder: false };
      }
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

/** A host bridge that hands the list its facts and records what the page tells it. */
function fakeMessages(facts: ListFacts, width: number | null) {
  const record = { bands: [] as { band: Rect; controls: readonly Rect[] }[], widths: [] as (number | null)[] };
  const messages: MessagesHost = {
    menu: async () => [],
    perform: async () => {},
    subscribeChrome: () => () => {},
    subscribeHidden: () => () => {},
    subscribeList: (listener) => {
      listener(facts);
      return () => {};
    },
    loadWidth: async () => width,
    saveWidth: (value) => record.widths.push(value),
    setDragBand: (band, controls) => record.bands.push({ band, controls }),
  };
  return { messages, record };
}

function fakeHost() {
  const calls: { op: string; params: unknown }[] = [];
  return {
    calls,
    client: {
      call: async (op: string, params: unknown) => {
        calls.push({ op, params });
        if (op === MessagesSheetOps.start) return { outcome: { kind: "opened", conversation: "c-grace" } };
        return {};
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    },
  };
}

const FACTS: ListFacts = parseListFacts({
  badges: { "c-chief": "Main · Cloud" },
  note: "Cloud conversations are not reachable",
  teammates: [{ id: "ada", name: "Ada Lovelace" }],
  people: [
    { id: "ada", name: "Ada Lovelace" },
    { id: "alan", name: "Alan Turing" },
  ],
  header: { side: 34, chipHeight: 28, chipGap: 8, chipPadding: 12, textStep: 1 },
});

async function mountApp(width: number | null = 240) {
  const element = installDom();
  const store = new HomeChannelsStore(storeClient([chief, dm]) as never);
  await store.reloadInbox();
  const { messages, record } = fakeMessages(FACTS, width);
  const host = fakeHost();
  await act(async () => {
    root = createRoot(element);
    root.render(
      <MessagesApp
        store={store}
        strings={strings}
        host={host.client as never}
        messages={messages}
        widthStorage={null}
      />,
    );
  });
  await settle();
  return { element, store, record, host };
}

test("E, H, G, B: the app's facts show: the Chief's tag, the Cloud note, a teammate row, the header's sizes", async () => {
  const { element } = await mountApp();
  const chiefRow = element.querySelector<HTMLElement>("[data-pinned-tile='c-chief'], [data-list-row='c-chief']")!;
  expect(chiefRow.getAttribute("aria-label")).toContain("Main · Cloud");
  expect(element.querySelector(".hm-note")?.textContent).toBe("Cloud conversations are not reachable");
  expect(element.querySelector("[data-teammate-row='ada']")?.textContent).toContain("Ada Lovelace");
  const filter = element.querySelector<HTMLElement>("button[aria-pressed]")!;
  expect(filter.style.height).toBe("34px");
});

test("E: a search lists the matching people under Teammates; choosing one starts the DM and opens it", async () => {
  const model = listModel(new Map([[dm.id, dm]]), {
    me: "me",
    now: NOW,
    language: "en-US",
    words,
    query: "alan",
    people: FACTS.people,
    teammates: FACTS.teammates,
  });
  expect(model.peopleSection).toBe(true);
  expect(model.people?.map((p) => p.person.id)).toEqual(["alan"]);
  // The Unread filter lists no teammates; no search lists the team's as rows, with no section.
  const filtered = listModel(new Map([[dm.id, dm]]), {
    now: NOW,
    language: "en-US",
    words,
    unreadOnly: true,
    ...FACTS,
  });
  expect(filtered.people).toBeUndefined();
  const plain = listModel(new Map([[dm.id, dm]]), { now: NOW, language: "en-US", words, ...FACTS });
  expect(plain.people?.map((p) => p.person.id)).toEqual(["ada"]);
  expect(plain.peopleSection).toBeUndefined();

  const { element, host, store } = await mountApp();
  const row = element.querySelector<HTMLElement>("[data-teammate-row='ada']")!;
  await act(async () => {
    row.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  await settle();
  const start = host.calls.find((call) => call.op === MessagesSheetOps.start);
  expect(start?.params).toEqual({ recipients: [{ contact: "ada" }], text: "" });
  expect(store.getSnapshot().selected).toBe("c-grace");
});

test("B: the header's circle, field and chip grow with the sidebar's density and text size", () => {
  const standard = headerLayout(320, false, null, true);
  const big = headerLayout(320, false, null, true, headerSizes(FACTS.header));
  expect(standard.filter.height).toBe(HEADER.side);
  expect(big.filter.height).toBe(34);
  expect(big.search.height).toBe(34);
  expect(big.filterChip.height).toBe(28);
  expect(big.listTop).toBe(HEADER.band + 28 + 8);
  expect(big.filter.y + big.filter.height).toBeLessThanOrEqual(HEADER.band);
});

test("K, C: the column opens at this window's width; the header band and its controls go to the drag strip", async () => {
  const { element, record } = await mountApp(240);
  const column = element.querySelector<HTMLElement>(".hm-column")!;
  expect(column.style.width).toBe("240px");
  expect(column.style.visibility).toBe("");
  const last = record.bands.at(-1)!;
  expect(last.band).toEqual({ x: 0, y: 0, width: 240, height: HEADER.band });
  // The search field and the Unread toggle take their own presses.
  expect(last.controls.length).toBeGreaterThanOrEqual(2);
  expect(last.controls.every((rect) => rect.x + rect.width <= 240 && rect.y + rect.height <= HEADER.band)).toBe(true);
  // Nothing was saved: only a drag keeps a width.
  expect(record.widths).toEqual([]);
});

test("K, J: a drag of the divider lights it, and keeps the width once on release; a squeeze keeps nothing", async () => {
  const { element, record } = await mountApp(null);
  const divider = element.querySelector<HTMLElement>(".hm-divider")!;
  const pointer = (type: string, clientX: number) =>
    act(async () => {
      divider.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, button: 0, clientX }));
    });
  await pointer("pointerdown", 320);
  expect(divider.className).toContain("dragging");
  await pointer("pointermove", 260);
  await pointer("pointermove", 250);
  expect(record.widths).toEqual([]);
  await pointer("pointerup", 250);
  expect(divider.className).not.toContain("dragging");
  expect(record.widths).toEqual([250]);
});

async function mountList(extra: Record<string, unknown> = {}) {
  const element = installDom();
  const calls: string[] = [];
  const model = listModel(new Map([[dm.id, dm]]), { me: "me", now: NOW, language: "en-US", words });
  await act(async () => {
    root = createRoot(element);
    root.render(
      <ConversationList
        model={model}
        width={320}
        query=""
        onQuery={(q) => calls.push(`query:${q}`)}
        unreadOnly={false}
        onUnreadOnly={() => {}}
        strings={strings}
        windowControls={null}
        canPin
        onSelect={(id) => calls.push(`select:${id}`)}
        onOpen={(id) => calls.push(`open:${id}`)}
        onSetPinned={() => {}}
        onArrangePinned={() => {}}
        onMarkRead={(id) => calls.push(`read:${id}`)}
        onMarkUnread={(id) => calls.push(`unread:${id}`)}
        onDelete={(id) => calls.push(`delete:${id}`)}
        {...extra}
      />,
    );
  });
  return { element, calls };
}

// fixed-wait: the gesture's end is the wheel's quiet time (SWIPE_END_MS), the behaviour under test.
const gestureEnd = () => settle(SWIPE_END_MS + 30);
const wheel = (target: Element, deltaX: number, deltaY = 0) =>
  act(async () => {
    target.dispatchEvent(new dom!.window.WheelEvent("wheel", { bubbles: true, deltaX, deltaY }));
  });

test("D: a left swipe on a row opens Delete; its click runs the menu's Delete Conversation…", async () => {
  const { element, calls } = await mountList();
  const row = element.querySelector<HTMLElement>("[data-list-row='c-grace']")!;
  await wheel(row, 30);
  await wheel(row, 30);
  expect(row.style.transform).toContain("translate(-60px");
  await gestureEnd();
  expect(row.style.transform).toContain(`translate(-${SWIPE_BUTTON}px`);
  const del = element.querySelector<HTMLElement>(".hm-swipe-action.delete")!;
  await act(async () => {
    del.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  expect(calls).toEqual(["delete:c-grace"]);
  expect(element.querySelector(".hm-swipe-strip")).toBeNull();
});

test("D: a full swipe runs Delete on release; a short one closes; a vertical scroll closes an open row", async () => {
  const { element, calls } = await mountList();
  const row = element.querySelector<HTMLElement>("[data-list-row='c-grace']")!;
  await wheel(row, 10);
  await gestureEnd();
  expect(row.style.transform).toContain("translate(0px");
  await wheel(row, 60);
  await gestureEnd();
  await wheel(row, 0, 40);
  expect(row.style.transform).toContain("translate(0px");
  await wheel(row, 250);
  await gestureEnd();
  expect(calls).toEqual(["delete:c-grace"]);
  // The pure rule: right shows Read/Unread, past 60 % runs the edge action.
  const actions = swipeActions(true, true, true);
  const state = swipeBy({ id: "x", offset: 0, open: false }, 200, 320, actions);
  expect(swipeEnd(state, 320, actions).run).toBe("read");
  expect(swipeBy({ id: "x", offset: 0, open: false }, 50, 320, swipeActions(false, false, true)).offset).toBe(0);
});

test("A: a letter typed in the list is no search; it goes to the message box, as the native Home routed it", async () => {
  const { element, calls } = await mountList();
  const list = element.querySelector<HTMLElement>("[role='listbox']")!;
  const event = new dom!.window.KeyboardEvent("keydown", { key: "t", bubbles: true, cancelable: true });
  await act(async () => {
    list.dispatchEvent(event);
  });
  expect(calls).toEqual([]);
  expect(event.defaultPrevented).toBe(false);

  let focused = 0;
  const stop = followTyping(dom!.window, dom!.window.document, { focus: () => (focused++, true) });
  const key = (target: EventTarget, init: KeyboardEventInit) =>
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, ...init }));
  list.focus();
  key(list, { key: "t" });
  expect(focused).toBe(1);
  key(list, { key: "ArrowDown" });
  key(list, { key: "a", metaKey: true });
  expect(focused).toBe(1);
  const search = element.querySelector<HTMLInputElement>("input")!;
  search.focus();
  key(search, { key: "t" });
  expect(focused).toBe(1);
  search.blur();
  key(dom!.window.document.body, { key: "Dead" });
  expect(focused).toBe(2);
  stop();
  expect([
    isTypedKey({ key: " ", metaKey: false, ctrlKey: false }),
    isTypedKey({ key: "Enter", metaKey: false, ctrlKey: false }),
  ]).toEqual([true, false]);
});

test("I: a working Chief's avatar is plain, with no state mark", async () => {
  const element = installDom();
  const model = listModel(new Map([[chief.id, chief]]), {
    me: "me",
    now: NOW,
    language: "en-US",
    words,
    activity: new Map([[chief.id, new Set([chiefPerson.id])]]),
  });
  await act(async () => {
    root = createRoot(element);
    root.render(
      <ConversationList
        model={model}
        width={320}
        query=""
        onQuery={() => {}}
        unreadOnly={false}
        onUnreadOnly={() => {}}
        strings={strings}
        windowControls={null}
        canPin
        onSelect={() => {}}
        onOpen={() => {}}
        onSetPinned={() => {}}
        onArrangePinned={() => {}}
        onMarkRead={() => {}}
        onMarkUnread={() => {}}
      />,
    );
  });
  expect(element.querySelector("[data-list-row='c-chief']")).not.toBeNull();
  expect(element.querySelector(".hm-state-mark")).toBeNull();
});

test("the avatar-only list's selection is a disc sized from the avatar", async () => {
  const { element } = await mountList({ width: 100, selected: "c-grace" });
  const row = element.querySelector<HTMLElement>("[data-list-row='c-grace']")!;
  expect(row.className).toContain("compact");
  expect(row.style.getPropertyValue("--hm-disc")).not.toBe("");
});

test("P: a gone Chief conversation's draft and files go to the live Chief after its own, and leave it", () => {
  const nav = new MessagesNav();
  nav.keepDraft("old", "carried text");
  nav.keepDraft("live", "own text");
  const part = (hash: string) => ({
    type: "attachment" as const,
    hash,
    name: hash,
    mimeType: "image/png",
    byteCount: 1,
  });
  const file = new File(["x"], "x.png");
  const drafts = nav.attachments as unknown as { trays: Map<string, unknown[]> };
  drafts.trays.set("old", [
    { id: "f1", file, part: part("a") },
    { id: "f2", file, part: part("b") },
  ]);
  drafts.trays.set("live", [{ id: "f3", file, part: part("a") }]);
  expect(nav.carry("old", "live")).toBe(true);
  expect(nav.draft("live")).toBe("own text\ncarried text");
  expect(nav.draft("old")).toBe("");
  expect(nav.attachments.files("live").map((item) => item.part?.hash)).toEqual(["a", "b"]);
  expect(nav.attachments.files("old")).toEqual([]);
  expect(nav.carry("old", "live")).toBe(false);
});

test("tours: a DEBUG fixture's team draws teammate rows, and the snapshot reads the Cloud note", async () => {
  const { pageDebug, fixtureContacts, snapshot } = await import("../src/pages/home-messages/debugCommands");
  pageDebug.set({ contacts: fixtureContacts(2) });
  try {
    const { element } = await mountApp();
    expect(element.querySelectorAll("[data-teammate-row^='user_fixture_team_']").length).toBe(2);
  } finally {
    pageDebug.set({ contacts: undefined });
  }
  const context = {
    store: { getSnapshot: () => ({ messages: [], pending: [] }) },
    nav: { getSnapshot: () => ({}) },
    model: listModel(new Map(), { now: NOW, language: "en-US", words }),
    note: "Cloud conversations are not reachable",
  };
  expect((snapshot(context as never, {}) as { note: unknown }).note).toBe("Cloud conversations are not reachable");
});
