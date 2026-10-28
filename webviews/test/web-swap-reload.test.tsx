// Leo 2026-10-24: "where are the builds being able to, like, just swap in, like hot swap in and
// whatnot? ... It should be, like, quick." A web update now swaps in while cmux is in the front,
// once nobody has touched it for a while (WebUpdates+SafePoint.swift) and every page answers that a
// reload keeps what it holds (pages/shared/webSwap.ts). These tests are the page's half: the
// composer's draft and its chips survive the swap's reload, and anything a reload would lose (a
// prompt being sent, chips not kept yet, a selection, an open menu, a scrolled list, a focused
// field that does not come back) keeps the update waiting.
import { afterAll, afterEach, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, useState } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { useWebSwapHold } from "../src/pages/shared/useWebSwapHold";
import { KEPT_ATTACHMENTS_SETTLE_MS, type KeptAttachments } from "../src/agent-session/acpmux/composer/keptAttachments";
import {
  WEB_SWAP_FOCUS,
  WEB_SWAP_FOCUS_KEY,
  WEB_SWAP_KEPT_SCROLL,
  WEB_SWAP_KEPT_TEXT,
  installWebSwap,
  takeWebSwapFocus,
} from "../src/pages/shared/webSwap";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "sessionStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

type SwapWindow = Window & {
  cmuxWebSwap?: { hold(): string | null };
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
};

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    sessionStorage: window.sessionStorage,
  });
  host = window.document.getElementById("root")!;
  // The desktop layer installs it on every first-party page.
  installWebSwap(window.document);
});

beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  closePage();
  delete (window as SwapWindow).cmuxAcpmuxActions;
  document.body.querySelectorAll(".fixture").forEach((node) => node.remove());
  window.getSelection()?.removeAllRanges();
  window.sessionStorage.clear();
  jest.useRealTimers();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// What the host answers when it asks this page whether a web update may reload it now.
const hold = () => (window as SwapWindow).cmuxWebSwap!.hold();

function Chips() {
  return null;
}

/// The host's chip store (AgentPaneDraftAttachments.swift), as composer-kept-attachments.test.tsx keeps it.
class Host implements KeptAttachments {
  chats = new Map<string, ComposerAttachment[]>();
  async read(sessionId: string) {
    return (this.chats.get(sessionId) ?? []).map((chip) => ({ ...chip }));
  }
  async write(sessionId: string, attachments: ComposerAttachment[]) {
    const had = this.chats.get(sessionId) ?? [];
    const kept = attachments.flatMap((chip) => {
      if (chip.data || chip.kind === "text" || chip.kind === "link") return [chip];
      const before = had.find((old) => old.id === chip.id);
      return before?.data ? [{ ...chip, data: before.data }] : [];
    });
    if (kept.length) this.chats.set(sessionId, kept);
    else this.chats.delete(sessionId);
    return { held: kept.filter((chip) => chip.data).map((chip) => chip.id) };
  }
}

/// acpmux's draft store, behind the page's `chat.readDraft` / `chat.writeDraft` actions.
function connectDaemon() {
  const drafts = new Map<string, string>();
  (window as SwapWindow).cmuxAcpmuxActions = {
    "chat.readDraft": async ({ sessionId }) => ({ draft: drafts.get(String(sessionId)) }),
    "chat.writeDraft": async ({ sessionId, text }) => {
      if (String(text).trim()) drafts.set(String(sessionId), String(text));
      else drafts.delete(String(sessionId));
    },
  };
  return drafts;
}

const screenshot = (index: number): ComposerAttachment => ({
  id: `shot-${index}`,
  kind: "image",
  name: `Screenshot ${index}.png`,
  mimeType: "image/png",
  size: 1_500_000,
  data: btoa(`png-bytes-${index}`),
});
const notes: ComposerAttachment = {
  id: "link-notes",
  kind: "link",
  name: "notes",
  mimeType: "inode/directory",
  size: 0,
  path: "/tmp/notes",
};

/// One chat page: a composer for `sessionId` with the host's store, as App.tsx renders it.
async function openPage(sessionId: string, store: KeptAttachments, onSend: () => boolean | Promise<void> = () => true) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat(
    [],
    sessionId ? { sessionId, summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 } } : {},
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={onSend}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
        keptAttachments={store}
      />,
    ),
  );
  await settle();
  return handle;
}

/// The swap's reload: the page goes; its origin's storage, acpmux and the host stay.
function closePage() {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
}

async function settle() {
  await act(async () => void jest.advanceTimersByTime(KEPT_ATTACHMENTS_SETTLE_MS + 20));
}

const prompt = () => host.querySelector('[role="combobox"]')?.textContent ?? "";
const chips = (handle: React.RefObject<ComposerHandle | null>) => handle.current?.wakeState().attachments ?? [];

test("a swap's reload keeps the composer's draft and its chips", async () => {
  const store = new Host();
  const drafts = connectDaemon();
  const page = await openPage("chat-a", store);
  act(() => {
    page.current!.restore("compare these cars", []);
    for (const index of [1, 2]) page.current!.attach(screenshot(index));
    page.current!.attach(notes);
  });
  // Typed and pasted a moment ago: acpmux or the host does not hold them yet, so the update waits.
  expect(hold()).toMatch(/^composer\.(draft|attachments)-unsaved$/);
  await settle();
  // Kept with the chat (acpmux has the text, the host the chips): the page may reload.
  expect(hold()).toBeNull();
  expect(drafts.get("chat-a")).toBe("compare these cars");

  closePage();
  const reloaded = await openPage("chat-a", store);
  expect(prompt()).toBe("compare these cars");
  expect(chips(reloaded).map((chip) => chip.id)).toEqual(["shot-1", "shot-2", "link-notes"]);
  expect(
    chips(reloaded)
      .slice(0, 2)
      .map((chip) => chip.data),
  ).toEqual([1, 2].map((index) => btoa(`png-bytes-${index}`)));
  expect(chips(reloaded).at(-1)?.path).toBe("/tmp/notes");
  expect(hold()).toBeNull();
});

test("a chip the host refused keeps the update waiting, and goes again when asked", async () => {
  const store = new Host();
  connectDaemon();
  let refuse = true;
  const flaky: KeptAttachments = {
    read: (id) => store.read(id),
    write: (id, chips) => (refuse ? Promise.reject(new Error("full")) : store.write(id, chips)),
  };
  const page = await openPage("chat-a", flaky);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  expect(hold()).toBe("composer.attachments-unsaved");
  // The host takes writes again: the next ask sends the chips, and the one after finds them kept.
  refuse = false;
  // The ask above already sent once more (refused); once it settles, the next ask sends again.
  await act(async () => {});
  await act(async () => void hold());
  await settle();
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(hold()).toBeNull();
});

test("a chip the host refused for the last chat still waits, and goes again, once another chat shows", async () => {
  const store = new Host();
  connectDaemon();
  let refuse = true;
  const flaky: KeptAttachments = {
    read: (id) => store.read(id),
    write: (id, chips) => (refuse ? Promise.reject(new Error("full")) : store.write(id, chips)),
  };
  const page = await openPage("chat-a", flaky);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  await openPage("chat-b", flaky);
  // Chat A's chip is still only in this page: the update waits, and asking sends it again.
  expect(hold()).toBe("composer.attachments-unsaved");
  refuse = false;
  await act(async () => {});
  await act(async () => void hold());
  await act(async () => {});
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(hold()).toBeNull();
});

test("going back to a chat whose chip the host refused shows it again and keeps waiting", async () => {
  const store = new Host();
  connectDaemon();
  let refuse = true;
  const flaky: KeptAttachments = {
    read: (id) => store.read(id),
    write: (id, chips) => (refuse ? Promise.reject(new Error("full")) : store.write(id, chips)),
  };
  const page = await openPage("chat-a", flaky);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  await openPage("chat-b", flaky);
  const back = await openPage("chat-a", flaky);
  // The host has nothing for chat A, but the page still shows the chip and waits for it.
  expect(chips(back).map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(hold()).toBe("composer.attachments-unsaved");
  refuse = false;
  await act(async () => {});
  await act(async () => void hold());
  await act(async () => {});
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(["shot-1"]);
  expect(hold()).toBeNull();
});

test("removing the last chip waits until the host forgot it", async () => {
  const store = new Host();
  connectDaemon();
  const page = await openPage("chat-a", store);
  act(() => page.current!.attach(screenshot(1)));
  await settle();
  expect(hold()).toBeNull();
  act(() => page.current!.detach(["shot-1"]));
  // The empty list still rests: a reload now would read the chip back from the host.
  expect(hold()).toBe("composer.attachments-unsaved");
  await settle();
  expect(store.chats.has("chat-a")).toBe(false);
  expect(hold()).toBeNull();
});

test("a prompt the host has not taken yet keeps the update waiting", async () => {
  const store = new Host();
  connectDaemon();
  let take: () => void = () => {};
  const page = await openPage("chat-a", store, () => new Promise<void>((resolve) => (take = resolve)));
  act(() => page.current!.restore("ship it", []));
  await settle();
  expect(hold()).toBeNull();
  act(() => {
    page.current!.send();
  });
  expect(hold()).toBe("composer.sending");
  await act(async () => take());
  await settle();
  expect(hold()).toBeNull();
});

test("a new chat's prompt, with no chat to keep it, keeps the update waiting", async () => {
  connectDaemon();
  const page = await openPage("", new Host());
  expect(hold()).toBeNull();
  act(() => page.current!.restore("a new idea", []));
  await settle();
  expect(hold()).toBe("composer.new-chat");
});

/// A plain element on the page, outside the composer.
function fixture(html: string): HTMLElement {
  const node = document.createElement("div");
  node.className = "fixture";
  node.innerHTML = html;
  document.body.append(node);
  return node;
}

test("a selection, an open menu, a scrolled list or a field that does not come back keeps it waiting", () => {
  expect(hold()).toBeNull();

  const text = fixture("<p>some words to select</p>");
  const range = document.createRange();
  range.selectNodeContents(text.querySelector("p")!);
  window.getSelection()!.addRange(range);
  expect(hold()).toBe("selection");
  window.getSelection()!.removeAllRanges();
  text.remove();

  const menu = fixture('<button aria-haspopup="menu" aria-expanded="true">More</button><div role="menu"></div>');
  expect(hold()).toBe("popup");
  menu.remove();

  const list = fixture('<div style="overflow:auto;height:10px"><div style="height:100px"></div></div>');
  const scroller = list.firstElementChild as HTMLElement;
  // jsdom lays nothing out: the scroller says where it sits.
  Object.defineProperty(scroller, "scrollTop", { configurable: true, value: 40 });
  expect(hold()).toBe("scroll");
  // A scroller that keeps its own place (the transcript) comes back where it was.
  scroller.setAttribute(WEB_SWAP_KEPT_SCROLL, "kept");
  expect(hold()).toBeNull();
  list.remove();

  const search = fixture('<input type="search" value="flaky">').querySelector("input")!;
  search.focus();
  expect(hold()).toBe("focus");
  search.blur();
  // Blurred, its text is still only in the page: a reload would lose it.
  expect(hold()).toBe("field");
  search.readOnly = true;
  expect(hold()).toBeNull();
  search.readOnly = false;
  search.parentElement!.setAttribute(WEB_SWAP_KEPT_TEXT, "");
  expect(hold()).toBeNull();
  search.parentElement!.remove();

  // A timeline that opens at its end holds only while it is scrolled up from there.
  const timeline = fixture(`<div ${WEB_SWAP_KEPT_SCROLL}="end"></div>`).firstElementChild as HTMLElement;
  Object.defineProperty(timeline, "scrollHeight", { configurable: true, value: 500 });
  Object.defineProperty(timeline, "clientHeight", { configurable: true, value: 100 });
  Object.defineProperty(timeline, "scrollTop", { configurable: true, value: 400 });
  expect(hold()).toBeNull();
  Object.defineProperty(timeline, "scrollTop", { configurable: true, value: 120 });
  expect(hold()).toBe("scroll");
  timeline.parentElement!.remove();

  document.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
  expect(hold()).toBe("ime");
  document.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
  expect(hold()).toBeNull();
});

test("a focused field that restores itself gives the keyboard back after the reload", () => {
  const owner = fixture(`<div ${WEB_SWAP_FOCUS}="composer" ${WEB_SWAP_KEPT_TEXT}><textarea>draft</textarea></div>`);
  const field = owner.querySelector("textarea")!;
  field.focus();
  // The caret before the end would move: a reload puts it after the text.
  field.setSelectionRange(2, 2);
  expect(hold()).toBe("caret");
  field.setSelectionRange(1, 3);
  expect(hold()).toBe("selection");
  field.setSelectionRange(5, 5);
  expect(hold()).toBeNull();
  expect(window.sessionStorage.getItem(WEB_SWAP_FOCUS_KEY)).toContain('"owner":"composer"');
  // The reloaded page: the composer takes the keyboard back, once.
  expect(takeWebSwapFocus("composer")).toBe(true);
  expect(takeWebSwapFocus("composer")).toBe(false);
});

test("a page's own hold (a New Tab's chips, a Home message on its way) keeps the update waiting", async () => {
  let setReason: (reason: string | null) => void = () => undefined;
  function Page() {
    const [reason, set] = useState<string | null>("newtab.attachments");
    setReason = set;
    useWebSwapHold(reason);
    return null;
  }
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () => root!.render(<Page />));
  expect(hold()).toBe("newtab.attachments");
  await act(async () => setReason("home.sending"));
  expect(hold()).toBe("home.sending");
  await act(async () => setReason(null));
  expect(hold()).toBeNull();
  await act(async () => setReason("home.send-failed"));
  await act(async () => root!.unmount());
  root = undefined;
  // Gone with its page.
  expect(hold()).toBeNull();
});
