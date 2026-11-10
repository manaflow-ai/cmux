// Home's Set Up cmux card on the Messages page (cards/setup/setupHost.tsx), ported from the native
// Home's HomeHostView+SetupCard.swift and its placement in HomeNativeTranscriptView+PinnedSection.swift:
// a Chief chat draws it under the Needs you section while the app shows it; it keeps at least its title
// and a row on a short pane and scrolls; a focused button on it keeps Space and the arrows
// (HomeNeedsYouTests `theSetupCardFitsAShortPaneAndIsNeverHidden`, HomePrimaryInputHistoryTests
// `theSetupCardKeepsItsKeys`).
import { afterEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { pinnedLayout, SETUP_CARD_MIN_HEIGHT } = await import("../src/pages/home-messages/transcript/pinnedLayout");
const { MessagesTranscript } = await import("../src/pages/home-messages/transcript/MessagesTranscript");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { cardStrings } = await import("../src/pages/home-messages/cards/strings");
const { useSetupCard, SETUP_OPS, parseSetupState } = await import("../src/pages/home-messages/cards/setup/setupHost");
const { SetupCard } = await import("../src/pages/home-messages/cards/setup/SetupCard");
const { followTyping } = await import("../src/pages/home-messages/pageCommands");
const { recallFromOutside } = await import("../src/pages/home-messages/composerHandoff");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type SetupState = import("../src/pages/home-messages/cards/setup/setupModel").SetupState;
type PageClient = import("../src/pages/shared/pageClient").PageClient;

const fresh: SetupState = {
  agents: [
    { id: "claude", name: "Claude Code", state: "missing" },
    { id: "codex", name: "Codex", state: "missing" },
  ],
  account: { signedIn: false },
  cli: "missing",
  classic: null,
};

const chief: HomeConversation = {
  id: "c1",
  owner: "local",
  title: "Chief",
  kind: "chief",
  participants: [
    { id: "me", kind: "human", name: "Me", chief: false },
    { id: "chief", kind: "agent", name: "Chief", chief: true },
  ],
  lastSeq: 0,
  rev: 1,
  updatedAt: 0,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
} as HomeConversation;

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("the card fits a short pane: Needs you gives way, the card keeps its title and a row, then scrolls", () => {
  // Unsized, the card takes no room but stays mounted, so it measures (native: 1 pt, never hidden).
  expect(pinnedLayout(400, undefined, 0)).toEqual({ pinned: 0, card: 0 });
  // Short enough: both whole.
  expect(pinnedLayout(600, 100, 200)).toEqual({ pinned: 100, card: 200 });
  // Taller than the pane: the slot stops above the message box and the card scrolls inside it.
  const tall = pinnedLayout(300, undefined, 2000);
  expect(tall.card).toBeGreaterThan(0);
  expect(tall.card).toBeLessThan(300);
  // Needs you rows taller than the pane: the section gives way, and the card keeps a usable height.
  const both = pinnedLayout(420, 2000, 2000);
  expect(both.card).toBeGreaterThanOrEqual(SETUP_CARD_MIN_HEIGHT);
  expect(both.pinned + 8 + both.card).toBeLessThan(420);
  // A card shorter than the floor keeps its whole height, no more.
  expect(pinnedLayout(200, 2000, 60).card).toBe(60);
  // No card: Needs you alone stops above the message box.
  expect(pinnedLayout(300, 2000, undefined)).toEqual({ pinned: 292, card: 0 });
});

test("the transcript draws the card under the Needs you section, over the rows and above the message box", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessagesTranscript
        strings={createTranscriptStrings(["en"])}
        me="me"
        conversation={chief}
        messages={[]}
        connection="online"
        onSend={async () => true}
        onLoadOlder={() => {}}
        pinned={<div className="needs-you">Needs you</div>}
        setupCard={<div className="the-card">Set Up cmux</div>}
      />,
    );
  });
  const box = container.querySelector(".mt-pinned")!;
  const parts = [...box.children].map((child) => child.className);
  expect(parts).toEqual(["mt-pinned-section", "mt-setup-slot"]);
  expect(box.querySelector(".mt-setup-slot .the-card")).not.toBeNull();
  expect(box.querySelector(".mt-compose")).toBeNull();
  // Alone (no Needs you rows) the card still shows in the pinned place.
  await act(async () => {
    root!.render(
      <MessagesTranscript
        strings={createTranscriptStrings(["en"])}
        me="me"
        conversation={chief}
        messages={[]}
        connection="online"
        onSend={async () => true}
        onLoadOlder={() => {}}
        setupCard={<div className="the-card">Set Up cmux</div>}
      />,
    );
  });
  expect(container.querySelector(".mt-pinned .mt-setup-slot .the-card")).not.toBeNull();
});

/** A host that answers `state`, pushes `changed` on demand and records every call. */
function host(state: unknown) {
  const calls: [string, unknown][] = [];
  const streams: string[] = [];
  let push: ((next: unknown) => void) | null = null;
  const client: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push([op, params]);
      return (op === SETUP_OPS.state ? state : {}) as R;
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      streams.push(stream);
      push = (next) => onEvent(next as E, 0);
      return () => {};
    },
    handle: () => () => {},
  };
  return { client, calls, streams, push: (next: unknown) => act(async () => push?.(next)) };
}

function Slot({ client, active }: { client: PageClient; active: boolean }) {
  return <div className="slot">{useSetupCard(client, active, cardStrings(["en"]))}</div>;
}

test("a Chief chat shows the card while the app does; Hide and a row's button are one host call each", async () => {
  const container = installDom();
  const { client, calls, streams, push } = host(fresh);
  await act(async () => {
    root = createRoot(container);
    root.render(<Slot client={client} active />);
  });
  await settle();
  expect(streams).toEqual([SETUP_OPS.changed]);
  expect(container.textContent).toContain("Set Up cmux");
  expect(container.textContent).toContain("Install Claude Code");

  const install = [...container.querySelectorAll("button")].find((node) => node.textContent === "Install Claude Code")!;
  await act(async () => install.click());
  await act(async () => container.querySelector<HTMLButtonElement>(".hm-setup__hide")!.click());
  expect(calls.filter(([op]) => op !== SETUP_OPS.state)).toEqual([
    [SETUP_OPS.run, { action: { kind: "installAgent", id: "claude" } }],
    [SETUP_OPS.hide, {}],
  ]);
  // Back from a sign-in: the page's focus asks the host to read the sign-ins again.
  await act(async () => dom!.window.dispatchEvent(new dom!.window.Event("focus")));
  expect(calls.at(-1)).toEqual([SETUP_OPS.focused, {}]);
  // The app ended the card (Hide, or every row done): it goes.
  await push(null);
  expect(container.querySelector(".hm-setup")).toBeNull();
});

test("another conversation reads nothing and shows no card; an app that shows none draws nothing", async () => {
  const container = installDom();
  const other = host(fresh);
  await act(async () => {
    root = createRoot(container);
    root.render(<Slot client={other.client} active={false} />);
  });
  await settle();
  expect(other.streams).toEqual([]);
  expect(other.calls).toEqual([]);
  expect(container.querySelector(".hm-setup")).toBeNull();

  const none = host(null);
  await act(async () => root!.render(<Slot client={none.client} active />));
  await settle();
  expect(none.streams).toEqual([SETUP_OPS.changed]);
  expect(container.querySelector(".hm-setup")).toBeNull();
  expect(parseSetupState({ agents: "x" })).toBeNull();
});

test("a focused button on the card keeps Space and the arrows; the message box does not take them", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SetupCard strings={cardStrings(["en"])} state={fresh} look="rows" onAction={() => {}} onHide={() => {}} />,
    );
  });
  const button = container.querySelector<HTMLButtonElement>(".hm-setup button")!;
  button.focus();
  expect(dom!.window.document.activeElement).toBe(button);

  let focused = 0;
  const stop = followTyping(dom!.window, dom!.window.document, { focus: () => (focused++, true) });
  button.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
  expect(focused).toBe(0);
  stop();

  const recallHistory = mock(() => true);
  const composer = { recallHistory } as unknown as Parameters<typeof recallFromOutside>[1];
  const key = (target: Element, name: string) => {
    const event = new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true });
    Object.defineProperty(event, "target", { value: target });
    return event;
  };
  expect(recallFromOutside(key(button, "ArrowUp"), composer)).toBe(false);
  expect(recallFromOutside(key(button, "ArrowDown"), composer)).toBe(false);
  expect(recallHistory).not.toHaveBeenCalled();
  // Outside the card Up still recalls.
  expect(recallFromOutside(key(dom!.window.document.body, "ArrowUp"), composer)).toBe(true);
});
