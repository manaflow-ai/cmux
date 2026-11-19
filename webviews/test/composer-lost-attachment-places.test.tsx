// Leo 2026-11-11: six images pasted into a chat during a reconnect loop went to the agent as
// "￼130e68ee-c6bc-…￼￼4d224273-…￼ ok i guess we're back in teh reconnecting loop": the draft's
// text kept each image's place (U+FFFC, its id, U+FFFC) while the composer lost the chips, and
// the send wrote the bare ids. A failed read of the chat's chips took them away, and a send with
// places and no chips sent the ids as words.
import { afterAll, afterEach, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import {
  type ComposerAttachment,
  INLINE_ATTACHMENT_MARK,
  inlineToken,
  inlineTokenIds,
} from "../src/agent-session/acpmux/attachments";
import { KEPT_ATTACHMENTS_SETTLE_MS, type KeptAttachments } from "../src/agent-session/acpmux/composer/keptAttachments";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

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
  });
  host = window.document.getElementById("root")!;
});

// A chip rests KEPT_ATTACHMENTS_SETTLE_MS before the page writes it; the test moves the clock.
beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  closePage();
  jest.useRealTimers();
  // Each test opens its chats fresh: the composer's remount cache (composerDraft.ts) is page
  // storage, and a prompt one test left there (its inline chips' tokens) must not fill the next
  // test's composer. It once did, which hid a test's chip that went in outside act.
  localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

/// The host's kept chips (AgentPaneDraftAttachments.swift), whose reads can be made to fail.
class Host implements KeptAttachments {
  chats = new Map<string, ComposerAttachment[]>();
  failing = false;
  async read(sessionId: string) {
    if (this.failing) throw new Error("host busy");
    return (this.chats.get(sessionId) ?? []).map((chip) => ({ ...chip }));
  }
  async write(sessionId: string, attachments: ComposerAttachment[]) {
    const had = this.chats.get(sessionId) ?? [];
    const kept = attachments.flatMap((chip) => {
      if (chip.data) return [chip];
      const before = had.find((old) => old.id === chip.id);
      return before?.data ? [{ ...chip, data: before.data }] : [];
    });
    if (kept.length) this.chats.set(sessionId, kept);
    else this.chats.delete(sessionId);
    return { held: kept.map((chip) => chip.id) };
  }
}

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: "image.png",
  mimeType: "image/png",
  size: 700_000,
  data: btoa(`png-${id}`),
});
const ids = [
  "130e68ee-c6bc-4ecc-b4c7-79f7e5d2bc6f",
  "4d224273-5805-43a8-a4f0-5637bf41006f",
  "166e0660-8cd6-46b1-a48b-0b3418a0450c",
];

type Sent = { text: string; attachments: ComposerAttachment[] };

/// The chat's composer as App.tsx renders it; `sessionId` undefined is the moment a reconnect's
/// attach has not named the chat yet.
async function render(sessionId: string | undefined, store: KeptAttachments, sent: Sent[] = []) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId,
    summary: sessionId ? { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 } : undefined,
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
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

function closePage() {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
}

async function settle(ms = KEPT_ATTACHMENTS_SETTLE_MS + 20) {
  await act(async () => void jest.advanceTimersByTime(ms));
}

const shown = (handle: React.RefObject<ComposerHandle | null>) =>
  (handle.current?.wakeState().attachments ?? []).map((chip) => chip.id);

/// No bare id goes as words: every place in the sent text is one of the sent attachments.
function expectNoBareIds(sent: Sent) {
  const placed = inlineTokenIds(sent.text);
  const carried = new Set(sent.attachments.map((chip) => chip.id));
  for (const id of placed) expect(carried.has(id)).toBe(true);
  const words = sent.text.replaceAll(
    new RegExp(`${INLINE_ATTACHMENT_MARK}[^${INLINE_ATTACHMENT_MARK}]*${INLINE_ATTACHMENT_MARK}`, "g"),
    "",
  );
  for (const id of ids) expect(words.includes(id)).toBe(false);
}

test("a reconnect whose read of the chat's chips fails keeps the pasted images", async () => {
  const store = new Host();
  const page = await render("chat-a", store);
  act(() => {
    for (const id of ids) page.current!.attach(image(id));
  });
  await settle();
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(ids);

  // The connection drops: the chat goes away and comes back while the host does not answer.
  store.failing = true;
  await render(undefined, store);
  const back = await render("chat-a", store);
  for (let i = 0; i < 8; i++) await settle(1000);
  expect(shown(back)).toEqual(ids);
  // Nothing written over the host's copy meanwhile.
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual(ids);
});

test("the same chat coming back keeps its own chips when the host's copy is behind", async () => {
  const store = new Host();
  const page = await render("chat-a", store);
  act(() => {
    for (const id of ids) page.current!.attach(image(id));
  });
  // The connection drops before the chips rest: the host holds none of them yet.
  await render(undefined, store);
  store.chats.delete("chat-a");
  const back = await render("chat-a", store);
  await settle();
  expect(shown(back)).toEqual(ids);
});

test("another chat's read that fails does not show this chat's chips there", async () => {
  const store = new Host();
  const page = await render("chat-a", store);
  act(() => page.current!.attach(image(ids[0]!)));
  await settle();
  store.failing = true;
  const other = await render("chat-b", store);
  expect(shown(other)).toEqual([]);
  store.failing = false;
  for (let i = 0; i < 4; i++) await settle(1000);
  expect(shown(other)).toEqual([]);
  expect(store.chats.get("chat-a")?.map((chip) => chip.id)).toEqual([ids[0]]);
});

test("a kept draft whose places lost their chips gets them back as chips, and the send carries the images", async () => {
  const store = new Host();
  store.chats.set("chat-a", ids.map(image));
  const sent: Sent[] = [];
  // The host's copy is not read while it is busy; the draft comes back with the places only.
  store.failing = true;
  const page = await render("chat-a", store, sent);
  for (let i = 0; i < 20; i++) await settle(1000);
  store.failing = false;
  act(() =>
    page.current!.restore(`${ids.map(inlineToken).join("")}ok i guess we're back in teh reconnecting loop`, []),
  );
  await settle(1000);
  expect(shown(page)).toEqual(ids);

  act(() => {
    page.current!.send();
  });
  await settle();
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((chip) => chip.id)).toEqual(ids);
  expect(sent[0]!.attachments.every((chip) => chip.data)).toBe(true);
  expectNoBareIds(sent[0]!);
  expect(sent[0]!.text).toContain("ok i guess we're back in teh reconnecting loop");
});

test("a send whose places have no chips anywhere never sends the bare ids", async () => {
  const store = new Host();
  const sent: Sent[] = [];
  const page = await render("chat-a", store, sent);
  act(() => page.current!.restore(`${ids.map(inlineToken).join("")}hello`, []));
  act(() => {
    page.current!.send();
  });
  await settle(1000);
  // Not sent: the places leave the text and the composer says so.
  expect(sent).toHaveLength(0);
  expect(host.textContent).toContain("no longer here");
  act(() => {
    page.current!.send();
  });
  await settle();
  expect(sent).toHaveLength(1);
  expectNoBareIds(sent[0]!);
  expect(sent[0]!.text.trim()).toBe("hello");
});

test("a send while the host does not answer keeps the places and the prompt, and goes once it does", async () => {
  const store = new Host();
  store.chats.set("chat-a", ids.map(image));
  store.failing = true;
  const sent: Sent[] = [];
  const page = await render("chat-a", store, sent);
  for (let i = 0; i < 20; i++) await settle(1000);
  act(() => page.current!.restore(`${ids.map(inlineToken).join("")}hello`, []));
  act(() => {
    page.current!.send();
  });
  for (let i = 0; i < 20; i++) await settle(1000);
  expect(sent).toHaveLength(0);
  // The places are still there: nothing was taken out for a read that failed.
  expect(inlineTokenIds(page.current!.draft().text)).toEqual(ids);
  store.failing = false;
  act(() => {
    page.current!.send();
  });
  for (let i = 0; i < 4; i++) await settle(1000);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((chip) => chip.id)).toEqual(ids);
  expectNoBareIds(sent[0]!);
});

test("two Enters while the chips come back send once, with the images", async () => {
  const store = new Host();
  store.chats.set("chat-a", ids.map(image));
  store.failing = true;
  const sent: Sent[] = [];
  const page = await render("chat-a", store, sent);
  for (let i = 0; i < 20; i++) await settle(1000);
  store.failing = false;
  act(() => page.current!.restore(`${ids.map(inlineToken).join("")}hello`, []));
  act(() => {
    page.current!.send();
    page.current!.send();
  });
  for (let i = 0; i < 4; i++) await settle(1000);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((chip) => chip.id)).toEqual(ids);
  expectNoBareIds(sent[0]!);
});

test("chips coming back for one chat never land in, or send with, the chat shown after it", async () => {
  const store = new Host();
  store.chats.set("chat-a", ids.map(image));
  store.failing = true;
  const sent: Sent[] = [];
  const page = await render("chat-a", store, sent);
  for (let i = 0; i < 20; i++) await settle(1000);
  act(() => page.current!.restore(`${ids.map(inlineToken).join("")}from a`, []));
  act(() => {
    page.current!.send();
  });
  // Another chat shows while chat A's read is still out; then the host answers.
  const other = await render("chat-b", store, sent);
  store.failing = false;
  for (let i = 0; i < 20; i++) await settle(1000);
  expect(shown(other)).toEqual([]);
  expect(sent).toHaveLength(0);
});
