// The Messages page's interaction cost stays constant as a conversation grows: a key typed in the
// message box, and a page render that changes nothing a row shows (a typing indicator, a Chief's
// working state, a presence change, the Set Up card's host), re-render no transcript row. Each
// bubble row builds its menu (bubbleMenu.ts `bubbleMenuItems`) once per render, so the count of
// those calls is the count of bubble rows React rendered.
import { afterEach, expect, mock, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const window = dom.window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const values = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
    Element: window.Element,
    Node: window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  } as Record<string, unknown>;
  for (const key of Object.keys(values)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, values);
  return window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

// Count the bubble rows rendered: the real menu builder, wrapped.
let bubbleRenders = 0;
const menu = await import("../src/pages/home-messages/transcript/bubbleMenu");
const realItems = menu.bubbleMenuItems;
void mock.module("../src/pages/home-messages/transcript/bubbleMenu", () => ({
  ...menu,
  bubbleMenuItems: (...args: Parameters<typeof realItems>) => {
    bubbleRenders += 1;
    return realItems(...args);
  },
}));

const { MessagesDetail } = await import("../src/pages/home-messages/detail/MessagesDetail");
const { MessagesNav } = await import("../src/pages/home-messages/nav");
const { noMessagesHost } = await import("../src/pages/home-messages/host");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { useSyncExternalStore } = await import("react");
type HomeSnapshot = import("../src/pages/home-channels/store").HomeSnapshot;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

/** A Chief chat of `count` messages. */
function client(count: number, setup: unknown = null) {
  const people = [
    { id: "me", kind: "human", name: "Me", chief: false },
    { id: "chief", kind: "agent", name: "Chief", chief: true },
  ];
  const chat = {
    id: "c1",
    owner: "local",
    title: "Chief",
    kind: "chief",
    participants: people,
    lastSeq: count,
    rev: 1,
    updatedAt: 1,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  const start = Date.now() - count * 60_000;
  const messages = Array.from({ length: count }, (_, index) => ({
    id: `m${index + 1}`,
    conversation: "c1",
    seq: index + 1,
    author: index % 2 ? "chief" : "me",
    createdAt: start + index * 60_000,
    parts: [{ type: "text", text: `message ${index + 1}` }],
    reactions: [],
  }));
  return {
    call: async (op: string) => {
      if (op === HomeOps.inbox) return { me: people[0], conversations: [chat], rev: 1 };
      if (op === HomeOps.page) return { conversation: chat, messages, hasOlder: false };
      if (op === "cmux.setup.state") return setup;
      return {};
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

let rerender: (patch: Partial<HomeSnapshot>) => void = () => {};

function Detail({
  store,
  nav,
  host,
}: {
  store: InstanceType<typeof HomeChannelsStore>;
  nav: InstanceType<typeof MessagesNav>;
  host: unknown;
}) {
  const live = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [patch, setPatch] = useState<Partial<HomeSnapshot>>({});
  rerender = (next) => setPatch(next);
  const snapshot: HomeSnapshot = { ...live, ...patch };
  const open = snapshot.selected ? snapshot.conversations.get(snapshot.selected) : undefined;
  return (
    <MessagesDetail
      store={store}
      snapshot={snapshot}
      conversation={open}
      me={snapshot.me}
      strings={strings}
      host={host as never}
      messages={noMessagesHost}
      chrome={{ windowControls: null }}
      nav={nav}
    />
  );
}

async function mount(count: number, setup: unknown = null) {
  const container = installDom();
  const host = client(count, setup);
  const store = new HomeChannelsStore(host as never);
  await store.reloadInbox();
  await store.select("c1");
  const nav = new MessagesNav();
  await act(async () => {
    root = createRoot(container);
    root.render(<Detail store={store} nav={nav} host={host} />);
  });
  await settle();
  const field = container.querySelector<MarkdownFieldElement>(".mt-field > div")!;
  await act(async () => field.acpmuxMarkdownField!.focus());
  return { container, field };
}

/** Bubble rows rendered by each key of `text` typed one at a time. */
async function rendersPerKey(field: MarkdownFieldElement, text: string): Promise<number> {
  bubbleRenders = 0;
  for (const key of text) await act(async () => field.acpmuxMarkdownField!.insertTyped(key));
  await settle();
  return bubbleRenders / text.length;
}

for (const count of [50, 500]) {
  test(`typing in a ${count}-message chat re-renders no transcript row`, async () => {
    const { container, field } = await mount(count);
    expect(container.querySelectorAll(".mt-bubble").length).toBeGreaterThan(0);
    const perKey = await rendersPerKey(field, "hello there");
    console.log(`row renders per keystroke (${count} messages): ${perKey}`);
    expect(perKey).toBe(0);
  });

  test(`a page render that changes no row's facts re-renders no transcript row (${count} messages)`, async () => {
    const { container } = await mount(count);
    const shown = container.querySelectorAll(".mt-bubble").length;
    expect(shown).toBeGreaterThan(0);
    bubbleRenders = 0;
    // Someone else's typing in another chat, a presence change: the page renders, the rows keep.
    const renders = [
      { viewing: ["chief"] },
      { activity: new Map([["c2", new Set(["x"])]]) },
      { activity: new Map([["c1", new Set(["chief"])]]) },
      { typing: ["chief"] },
      {},
    ];
    for (const patch of renders) await act(async () => rerender(patch));
    await settle();
    console.log(
      `row renders per unrelated page render (${count} messages): ${bubbleRenders / renders.length} of ${shown} shown`,
    );
    expect(bubbleRenders).toBe(0);
  });
}

const setupState = {
  agents: [{ id: "claude", name: "Claude Code", state: "missing" }],
  account: { signedIn: false },
  cli: "missing",
  classic: null,
};

test("a Chief chat's Set Up cmux card shows once, under the pinned section, and keeps the rows", async () => {
  const { container } = await mount(500, setupState);
  expect(container.querySelectorAll(".hm-setup__head").length).toBe(1);
  expect(container.querySelector(".mt-setup-slot .hm-setup__head")).not.toBeNull();
  expect(container.querySelector(".mt-pinned-section")).toBeNull();
  bubbleRenders = 0;
  await act(async () => rerender({ viewing: ["chief"] }));
  await act(async () => rerender({}));
  await settle();
  expect(bubbleRenders).toBe(0);
});
