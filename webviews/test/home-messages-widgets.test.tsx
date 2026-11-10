// Chat widgets on the Messages page (plans/cmux-next/chat-widgets-DESIGN.md section 4): the cases of
// the deleted native rows' tests (MessagesLabHomeTests HomeWidgetRowTests: one card per widget part
// keyed <message>#<part>, its fallback without a snapshot, height by rows, clicks to nodes only on
// rows and enabled buttons), the wire parse, the host bridge and the kept mounts.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

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

const { message: wireMessage } = await import("../src/pages/home-channels/daemonHome");
const { partText } = await import("../src/pages/home-channels/model");
const { transcriptRows, estimateRow } = await import("../src/pages/home-messages/transcript/rows");
const { TranscriptRowView, bubbleCopyText } = await import("../src/pages/home-messages/transcript/TranscriptRows");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { WidgetContext, hostWidgets, widgetKeys } =
  await import("../src/pages/home-messages/cards/widget/widgetService");
const { MessagesTranscript } = await import("../src/pages/home-messages/transcript/MessagesTranscript");
const model = await import("../src/pages/home-messages/cards/widget/widgetModel");
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;
type HomeWidgetPart = import("../src/pages/home-channels/types").HomeWidgetPart;
type Row = import("../src/pages/home-messages/transcript/rows").TranscriptRow;
type WidgetService = import("../src/pages/home-messages/cards/widget/widgetService").WidgetService;
type WidgetSnapshot = import("../src/pages/home-messages/cards/widget/widgetModel").WidgetSnapshot;
type PageClient = import("../src/pages/shared/pageClient").PageClient;

const WIDGET = {
  type: "widget",
  app: "cmux/pr-card",
  widget: "cmux.chat.widget/1",
  props: { repo: "o/r", number: 7 },
  fallback: "PR #7: Widgets in chat (1 check failed)",
  url: "https://github.com/o/r/pull/7",
};
/** The native tests' card (MessagesLabHomeTests HomeWidgetRowTests.card), as the host sends it. */
const CARD = {
  items: [
    { type: "text", text: "Widgets in chat", style: "headline", tint: "primary" },
    {
      type: "row",
      node: "pr",
      title: "o/r #7",
      subtitle: "Open · octo",
      symbol: "arrow.triangle.pull",
      tint: "success",
    },
    { type: "badge", text: "1 failed · 6 passed", tint: "danger" },
    { type: "divider" },
    { type: "row", node: "c7", title: "check-7", subtitle: "Failed", symbol: "xmark.circle", tint: "danger" },
    { type: "text", text: "Page 1 of 2", style: "caption", tint: "secondary" },
    {
      type: "buttons",
      buttons: [
        { node: "prev", title: "Previous", prominent: false, enabled: false },
        { node: "next", title: "Next", prominent: true, enabled: true },
      ],
    },
  ],
};

const chief = { id: "agent_mux", kind: "agent" as const, name: "Chief", chief: true };
const me = { id: "user_local", kind: "human" as const, name: "Me", chief: false };
const conversation: HomeConversation = {
  id: "c1",
  owner: "local",
  title: "",
  kind: "chief",
  participants: [me, chief],
  lastSeq: 7,
  rev: 1,
  updatedAt: 0,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
};
const wire = (parts: unknown[], id = "msg_1", seq = 7) =>
  wireMessage({
    id,
    conversation: "c1",
    seq,
    author: chief.id,
    created_at: "2026-11-07T10:00:00.000Z",
    client_msg_id: `k${seq}`,
    parts,
    reactions: [],
  });
const bubbles = (messages: HomeMessage[]) =>
  transcriptRows({ me: me.id, conversation, messages }, Date.parse("2026-11-07T12:00:00Z")).filter(
    (row): row is Extract<Row, { kind: "bubble" }> => row.kind === "bubble",
  );

/** A widget host with fixed snapshots that records what the page asks (HomeWidgetRowTests FakeWidgets). */
class FakeWidgets implements WidgetService {
  snapshots = new Map<string, WidgetSnapshot>();
  asked: { key: string; part: HomeWidgetPart }[] = [];
  taps: [string, string][] = [];
  kept = new Map<object, readonly string[]>();
  listeners = new Set<(key: string, snapshot: WidgetSnapshot | undefined) => void>();
  snapshot(key: string, part: HomeWidgetPart) {
    this.asked.push({ key, part });
    return Promise.resolve(this.snapshots.get(key));
  }
  tap(key: string, node: string) {
    this.taps.push([key, node]);
  }
  keep(owner: object, keys: readonly string[]) {
    if (keys.length) this.kept.set(owner, keys);
    else this.kept.delete(owner);
  }
  subscribe(listener: (key: string, snapshot: WidgetSnapshot | undefined) => void) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  change(key: string, snapshot: WidgetSnapshot | undefined) {
    for (const listener of this.listeners) listener(key, snapshot);
  }
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

function render(row: Extract<Row, { kind: "bubble" }>, widgets?: WidgetService) {
  const host = installDom();
  const strings = createTranscriptStrings(["en"]);
  root = createRoot(host);
  act(() =>
    root!.render(
      <WidgetContext.Provider value={widgets}>
        <TranscriptRowView
          row={row}
          me={me.id}
          strings={strings}
          now={0}
          people={new Map([[chief.id, chief]])}
          actions={{}}
        />
      </WidgetContext.Provider>,
    ),
  );
  return host;
}

test("the daemon's widget part keeps its fields; one without an app or fallback reads as text", () => {
  const message = wire([{ type: "text", text: "Here is the PR.", runs: [] }, WIDGET]);
  expect(message.parts[1]).toEqual(WIDGET as HomeWidgetPart);
  // Plain text (copy, search, previews) is the fallback, as Swift `MessagePart.plainText`.
  expect(partText(message.parts[1]!)).toBe(WIDGET.fallback);
  const bare = wire([{ type: "widget", app: "cmux/pr-card", props: [], fallback: "Only text" }]).parts[0];
  expect(bare).toEqual({
    type: "widget",
    app: "cmux/pr-card",
    widget: "cmux.chat.widget/1",
    props: {},
    fallback: "Only text",
  });
  expect(wire([{ type: "widget", fallback: "No app" }]).parts[0]).toEqual({ type: "other", text: "No app" });
  expect(wire([{ type: "widget", app: "cmux/pr-card", url: "https://x.test/a" }]).parts[0]).toEqual({
    type: "other",
    text: "https://x.test/a",
  });
});

test("a widget part is its own card row keyed <message>#<part>, copying its fallback", () => {
  const rows = bubbles([wire([{ type: "text", text: "Here is the PR.", runs: [] }, WIDGET])]);
  expect(rows.map((row) => row.parts[0]?.type)).toEqual(["text", "widget"]);
  expect(rows[1]!.partIndex).toBe(1);
  expect(widgetKeys([rows[1]!.message])).toEqual(["msg_1#1"]);
  expect(bubbleCopyText(rows[1]!)).toBe(WIDGET.fallback);
  // A retracted message keeps no widget mounted.
  expect(widgetKeys([{ ...rows[1]!.message, retracted: true }])).toEqual([]);
});

test("without a host, and while the host has no snapshot, the card is the fallback text", async () => {
  const row = bubbles([wire([WIDGET])])[0]!;
  let host = render(row);
  expect(host.querySelector(".hm-widget--fallback")?.textContent).toBe(WIDGET.fallback);
  act(() => root!.unmount());
  root = undefined;
  const widgets = new FakeWidgets();
  host = render(row, widgets);
  await settle();
  expect(widgets.asked).toEqual([{ key: "msg_1#0", part: WIDGET as HomeWidgetPart }]);
  expect(host.querySelector(".hm-widget--fallback")?.textContent).toBe(WIDGET.fallback);
});

test("the host's snapshot draws as the card, and a change redraws it in place", async () => {
  const widgets = new FakeWidgets();
  widgets.snapshots.set("msg_1#0", model.parseWidgetSnapshot(CARD)!);
  const host = render(bubbles([wire([WIDGET])])[0]!, widgets);
  await settle();
  const card = host.querySelector(".hm-widget")!;
  expect(card.classList.contains("hm-widget--fallback")).toBe(false);
  expect(card.querySelector(".hm-widget__text[data-style=headline]")?.textContent).toBe("Widgets in chat");
  expect([...card.querySelectorAll(".hm-widget__row .hm-widget__title")].map((node) => node.textContent)).toEqual([
    "o/r #7",
    "check-7",
  ]);
  expect(card.querySelector(".hm-widget__pill")?.getAttribute("data-tint")).toBe("danger");
  expect(card.querySelectorAll(".hm-widget__divider").length).toBe(1);
  expect(card.querySelectorAll(".hm-widget__symbol svg").length).toBe(2);
  act(() =>
    widgets.change("msg_1#0", { items: [{ type: "text", text: "Page 2 of 2", style: "caption", tint: "secondary" }] }),
  );
  expect(host.querySelector(".hm-widget")?.textContent).toBe("Page 2 of 2");
  // Another widget's change is not this card's; a change to nothing draws the fallback again.
  act(() => widgets.change("msg_9#0", model.parseWidgetSnapshot(CARD)));
  expect(host.querySelector(".hm-widget")?.textContent).toBe("Page 2 of 2");
  act(() => widgets.change("msg_1#0", undefined));
  expect(host.querySelector(".hm-widget--fallback")?.textContent).toBe(WIDGET.fallback);
});

test("a click on a row or an enabled button goes to its node; a badge or a disabled button takes none", async () => {
  const widgets = new FakeWidgets();
  widgets.snapshots.set("msg_1#0", model.parseWidgetSnapshot(CARD)!);
  const host = render(bubbles([wire([WIDGET])])[0]!, widgets);
  await settle();
  const click = (selector: string) =>
    act(() => {
      host.querySelector<HTMLElement>(selector)!.click();
    });
  click("[data-node=pr]");
  click("[data-node=next]");
  click("[data-node=prev]");
  click(".hm-widget__pill");
  expect(widgets.taps).toEqual([
    ["msg_1#0", "pr"],
    ["msg_1#0", "next"],
  ]);
  expect(model.clickableNodes(model.parseWidgetSnapshot(CARD)!)).toEqual(["pr", "c7", "next"]);
});

test("a card is taller than its fallback and grows by a row and its spacing per row", () => {
  const card = model.parseWidgetSnapshot(CARD)!;
  const L = model.WIDGET_LAYOUT;
  expect(model.widgetHeight(card)).toBeGreaterThan(model.fallbackHeight(WIDGET.fallback));
  const longer = { items: [...card.items] };
  longer.items.splice(5, 0, {
    type: "row",
    node: "c1",
    title: "check-1",
    subtitle: "Passed",
    symbol: "checkmark.circle",
    tint: "success",
  });
  expect(model.widgetHeight(longer)).toBe(model.widgetHeight(card) + L.rowHeight + L.spacing);
  // Text wraps to at most 4 lines; the card draws at most 14 items.
  expect(model.textLines("x".repeat(1000))).toBe(L.maxTextLines);
  const many = { items: Array.from({ length: 30 }, () => ({ type: "divider" })) };
  expect(model.parseWidgetSnapshot(many)!.items.length).toBe(L.maxItems);
  // The row estimate is the fallback bubble's until the card measures.
  const row = bubbles([wire([WIDGET])])[0]!;
  expect(estimateRow(row)).toBe(row.gap + model.fallbackHeight(WIDGET.fallback));
});

test("the snapshot parse keeps what the card draws and skips what it does not know", () => {
  expect(model.parseWidgetSnapshot(null)).toBeUndefined();
  expect(model.parseWidgetSnapshot({ items: "no" })).toBeUndefined();
  expect(
    model.parseWidgetSnapshot({
      items: [
        { type: "text", text: "", style: "headline" },
        { type: "text", text: "Hi", style: "odd", tint: "odd" },
        { type: "image", url: "x" },
        { type: "row", title: "R", tint: "warning", badge: "" },
        {
          type: "buttons",
          buttons: [
            { node: "", title: "x" },
            { node: "n", title: "Go" },
          ],
        },
        { type: "buttons", buttons: [] },
        { type: "badge", text: "B" },
        { type: "empty", title: "None", message: "Nothing yet", symbol: "clock" },
      ],
    }),
  ).toEqual({
    items: [
      { type: "text", text: "Hi", style: "body", tint: "primary" },
      { type: "row", title: "R", tint: "warning" },
      { type: "buttons", buttons: [{ node: "n", title: "Go", prominent: false, enabled: true }] },
      { type: "badge", text: "B", tint: "secondary" },
      { type: "empty", title: "None", message: "Nothing yet", symbol: "clock" },
    ],
  });
  expect(model.parseWidgetChange({ key: "msg_1#0", snapshot: null })).toEqual({ key: "msg_1#0", snapshot: undefined });
  expect(model.parseWidgetChange({ snapshot: CARD })).toBeUndefined();
});

test("the host bridge sends the part, a tap and the merged keep, and shares one change stream", async () => {
  const calls: [string, unknown][] = [];
  const events: ((event: unknown) => void)[] = [];
  let unsubscribed = 0;
  const client = {
    call: (op: string, params: unknown) => {
      calls.push([op, params]);
      return Promise.resolve(op === model.WidgetOps.snapshot ? CARD : null);
    },
    subscribe: (stream: string, onEvent: (event: unknown) => void) => {
      expect(stream).toBe(model.WidgetOps.changes);
      events.push(onEvent);
      return Promise.resolve(() => void unsubscribed++);
    },
    handle: () => () => {},
  } as unknown as PageClient;
  const service = hostWidgets(client);
  const part = wire([WIDGET]).parts[0] as HomeWidgetPart;
  expect((await service.snapshot("msg_1#0", part))?.items.length).toBe(7);
  service.tap("msg_1#0", "next");
  const main = {};
  const thread = {};
  service.keep(main, ["a#0", "b#0"]);
  service.keep(thread, ["b#0", "c#1"]);
  service.keep(thread, ["c#1", "b#0"]);
  service.keep(main, []);
  expect(calls).toEqual([
    [
      model.WidgetOps.snapshot,
      {
        key: "msg_1#0",
        widget: {
          app: WIDGET.app,
          widget: WIDGET.widget,
          props: WIDGET.props,
          fallback: WIDGET.fallback,
          url: WIDGET.url,
        },
      },
    ],
    [model.WidgetOps.tap, { key: "msg_1#0", node: "next" }],
    [model.WidgetOps.keep, { keys: ["a#0", "b#0"] }],
    [model.WidgetOps.keep, { keys: ["a#0", "b#0", "c#1"] }],
    [model.WidgetOps.keep, { keys: ["b#0", "c#1"] }],
  ]);
  const seen: string[] = [];
  const stopA = service.subscribe((key) => seen.push(`a:${key}`));
  const stopB = service.subscribe((key) => seen.push(`b:${key}`));
  await Promise.resolve();
  expect(events.length).toBe(1);
  events[0]!({ key: "msg_1#0", snapshot: CARD });
  stopA();
  stopB();
  expect(seen).toEqual(["a:msg_1#0", "b:msg_1#0"]);
  expect(unsubscribed).toBe(1);
});

test("a transcript keeps its loaded messages' widgets mounted and releases them when it closes", async () => {
  const element = installDom();
  const widgets = new FakeWidgets();
  const strings = createTranscriptStrings(["en"]);
  const messages = [wire([WIDGET], "msg_1", 6), wire([{ type: "text", text: "hi", runs: [] }, WIDGET], "msg_2", 7)];
  root = createRoot(element);
  act(() =>
    root!.render(
      <WidgetContext.Provider value={widgets}>
        <MessagesTranscript
          strings={strings}
          me={me.id}
          conversation={conversation}
          messages={messages}
          connection="online"
          onSend={async () => true}
          onLoadOlder={() => {}}
        />
      </WidgetContext.Provider>,
    ),
  );
  await settle();
  expect([...widgets.kept.values()]).toEqual([["msg_1#0", "msg_2#1"]]);
  act(() => root!.unmount());
  root = undefined;
  expect(widgets.kept.size).toBe(0);
});
