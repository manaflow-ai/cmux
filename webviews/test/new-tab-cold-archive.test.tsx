// l10n-allow-file: test fixtures.
// Leo 2026-11-09: a TRUE "archive chat" that you can still preview a sliver of. A chat in acpmux's
// cold archive lists from its preview alone (`coldArchive`), badged Compressed; its card's menu
// archives it or brings it back through `_acpmux/cold_archive`.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translateNewTab } from "../src/agent-session/acpmux/newtab/strings";
import { recentChatCards, type ChatCard } from "../src/agent-session/acpmux/newtab/screenModel";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";
import { settleReact } from "./support/domTeardown";

const NOW = Date.UTC(2026, 10, 9, 12);
const cold = {
  archivedAt: NOW - 1_000,
  messages: 42,
  bytesBefore: 975_290,
  bytesAfter: 14_286,
  last: [
    { role: "user", text: "Can you check the build?", at: NOW - 90_000 },
    { role: "assistant", text: "The build passes on every target.", at: NOW - 60_000 },
  ],
};
const summary = (id: string, extra: Record<string, unknown> = {}) => ({
  sessionId: id,
  name: `Chat ${id}`,
  harness: "claude",
  status: "closed",
  updatedAt: NOW - 60_000,
  preview: "a reply from the live log",
  ...extra,
});

test("a summary's coldArchive is the card's preview, badged compressed", () => {
  const archived = sessionEntry(summary("old", { coldArchive: cold }));
  expect(archived.coldArchive).toEqual(cold);
  // A malformed one keeps only what it can read.
  expect(sessionEntry(summary("odd", { coldArchive: { last: [{ text: 3 }, { text: "kept" }] } })).coldArchive).toEqual({
    archivedAt: 0,
    messages: 0,
    bytesBefore: 0,
    bytesAfter: 0,
    last: [{ role: "assistant", text: "kept", at: 0 }],
  });
  const cards = recentChatCards([archived, sessionEntry(summary("live"))], NOW, undefined, [], 6, false);
  const byId = new Map(cards.map((card) => [card.sessionId, card]));
  expect(byId.get("old")).toMatchObject({ archived: true, message: "The build passes on every target." });
  expect(byId.get("live")?.archived).toBeUndefined();
  expect(byId.get("live")?.message).toBe("a reply from the live log");
});

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  for (const [key, { had, value }] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const cards: ChatCard[] = [
  { sessionId: "live", title: "Live chat", age: "1m", state: "idle", harness: "claude", message: "Ready." },
  {
    sessionId: "old",
    title: "Old chat",
    age: "40d",
    state: "idle",
    harness: "claude",
    message: "The build passes on every target.",
    archived: true,
  },
  { sessionId: "codex:dev", chatKey: "codex:dev", title: "Device chat", age: "2d", state: "idle" },
];

const card = (title: string) =>
  [...host.querySelectorAll<HTMLElement>(".nt-card")].find(
    (node) => node.querySelector(".nt-card-title")?.textContent === title,
  )!;
const menuItems = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].map((item) => item);

async function openMenu(title: string) {
  await act(async () =>
    card(title).dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  return menuItems();
}

async function closeMenu() {
  await act(async () =>
    dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
  );
}

test("an archived card shows its badge and preview, and its menu compresses or decompresses it", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatCards } = await import("../src/agent-session/acpmux/newtab/ChatCards");
  const calls: [string, boolean][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ChatCards
        cards={cards}
        onOpen={() => undefined}
        onColdArchive={(id, archived) => void calls.push([id, archived])}
      />,
    ),
  );
  const badge = translateNewTab("card.compressed");
  expect(card("Old chat").dataset.archived).toBe("");
  expect(card("Old chat").querySelector(".nt-card-badge")?.textContent).toBe(badge);
  expect(card("Old chat").querySelector(".nt-card-message")?.textContent).toBe("The build passes on every target.");
  expect(card("Live chat").dataset.archived).toBeUndefined();
  expect(card("Live chat").querySelector(".nt-card-badge")).toBeNull();

  const archive = (await openMenu("Live chat")).find(
    (item) => item.textContent === translateNewTab("card.compressChat"),
  );
  expect(archive).toBeDefined();
  await act(async () => archive!.click());
  const decompress = (await openMenu("Old chat")).find(
    (item) => item.textContent === translateNewTab("card.decompressChat"),
  );
  expect(decompress).toBeDefined();
  await act(async () => decompress!.click());
  expect(calls).toEqual([
    ["live", true],
    ["old", false],
  ]);
  // A device chat is not acpmux's session: its menu has no Compress Chat.
  const device = (await openMenu("Device chat")).map((item) => item.textContent);
  expect(device).not.toContain(translateNewTab("card.compressChat"));
  expect(device).not.toContain(translateNewTab("card.decompressChat"));
  await closeMenu();
});
