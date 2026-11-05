// l10n-allow-file: synthetic senders and prompts, and the visible copy they read as.
// Messages from other chats next to each other share one tick on the prompt rail (Leo, 2026-11-03:
// "i've always been on the fence about messages from other chats showing up in that prompt jump
// scroll rail individual elements"; incoming.experiment.ts, default `folded-secondary`). The person's
// prompts keep a tick each; a run of other chats' messages is one tick, in the same column, whose card
// reads "Received N messages" from its senders, as the transcript's row for them does. The folded
// tick jumps to the run's first message, takes its place in the Tab and arrow order, and bookmarks
// that first message; a mark on any message of the run shows on it, and its toggle takes that off.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, ConversationLayout } from "../src/agent-session/acpmux/model";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  localStorage: dom.window.localStorage,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ThreadMinimap } = await import("../src/agent-session/acpmux/threadMinimap/ThreadMinimap");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
const { incomingPrompt } = await import("../src/agent-session/acpmux/conversation/incomingMessage");

afterAll(() => {
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: 1,
  ...fields,
});
const message = (seq: number, sender: string) => {
  const text = `Status ${seq}: the helper's branch is green.`;
  const incoming = incomingPrompt(text, {
    _meta: { provenance: { kind: "session_message", from: `${sender}-id`, fromName: sender, to: "me" } },
  });
  if (incoming?.kind !== "message") throw new Error("not a message");
  return row(`user-${seq}`, "user", { text: incoming.message.text, incoming, resend: text });
};
// The person's prompt (seq 1), three messages from ux-owner (4, 7, 10), the person's prompt (13) and
// one message from picker (16), each answered.
const heads = [
  row("user-1", "user", { text: "Plan the change" }),
  message(4, "lane-box-1/ux-owner"),
  message(7, "lane-box-1/ux-owner"),
  message(10, "lane-box-1/ux-owner"),
  row("user-13", "user", { text: "Land it" }),
  message(16, "lane-box-2/picker"),
];
const rows = heads.flatMap((head) => [head, row(`assistant-${head.id}`, "assistant", { text: "Done." })]);
const layout: ConversationLayout = {
  tops: Float64Array.from(rows.map((_, index) => index * 400)),
  heights: Float64Array.from(rows.map(() => 400)),
  totalHeight: rows.length * 400,
};

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

async function mount(marked: number[]) {
  const marks = new Set(marked);
  const calls: { seq: number; bookmarked: boolean }[] = [];
  setBookmarkTransport({
    get: async (sessionId) => ({ sessionId, bookmarks: [...marks] }),
    set: async (sessionId, seq, bookmarked) => {
      calls.push({ seq, bookmarked });
      if (bookmarked) marks.add(seq);
      else marks.delete(seq);
      return { sessionId, bookmarks: [...marks] };
    },
  });
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const scroller = dom.window.document.createElement("div");
  host.append(scroller);
  const root = createRoot(host.appendChild(dom.window.document.createElement("div")));
  await act(async () =>
    root.render(
      createElement(ThreadMinimap, {
        rows,
        sessionId: "chat-1",
        layout,
        scroller: { current: scroller },
        scrollTop: 0,
        viewportHeight: 600,
        scrolls: true,
        width: 1040,
      }),
    ),
  );
  await settle();
  const tick = (index: number) => host.querySelector<HTMLElement>(`[data-tick="${index}"]`)!;
  const focus = (index: number) => act(async () => tick(index).focus());
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { host, scroller, tick, focus, calls, unmount };
}

test("a run of other chats' messages is one tick whose card reads Received N messages", async () => {
  const rail = await mount([]);
  try {
    // Prompt, the ux-owner run, prompt, the single picker message: four ticks, not six.
    expect(rail.host.querySelectorAll("[data-tick]").length).toBe(4);
    expect(rail.tick(1).closest("li")!.getAttribute("aria-setsize")).toBe("4");
    expect(rail.tick(1).hasAttribute("data-incoming")).toBe(true);
    expect(rail.tick(2).hasAttribute("data-incoming")).toBe(false);
    // Other chats' ticks draw a step dimmer at rest.
    expect(rail.host.querySelector(".acpmux-minimap__rail")!.hasAttribute("data-incoming-dim")).toBe(true);

    await rail.focus(1);
    expect(rail.host.querySelector(".acpmux-minimap__from")!.textContent).toBe("From lane-box-1/ux-owner");
    expect(rail.host.querySelector(".acpmux-minimap__prompt")!.textContent).toBe("Received 3 messages");
    expect(rail.tick(1).getAttribute("aria-label")).toContain("Received 3 messages");
    // A single message keeps its own words.
    await rail.focus(3);
    expect(rail.host.querySelector(".acpmux-minimap__prompt")!.textContent).toContain("Status 16");

    // The arrow keys step over the run as one tick.
    await rail.focus(1);
    await act(async () =>
      rail.tick(1).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })),
    );
    expect((dom.window.document.activeElement as HTMLElement).dataset.tick).toBe("2");
  } finally {
    await rail.unmount();
  }
});

test("the folded tick jumps to the run's first message and bookmarks it", async () => {
  const rail = await mount([]);
  try {
    await act(async () => rail.tick(1).click());
    await settle();
    // Row 2 is the run's first message (user-4); its top is 800.
    const landed = rail.scroller.scrollTop;
    await act(async () => rail.tick(0).click());
    await settle();
    expect(landed).toBeGreaterThan(rail.scroller.scrollTop);
    expect(landed).toBeLessThan(1200);

    await rail.focus(1);
    await act(async () => rail.host.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!.click());
    await settle();
    expect(rail.calls).toEqual([{ seq: 4, bookmarked: true }]);
    expect(rail.tick(1).hasAttribute("data-bookmarked")).toBe(true);
  } finally {
    await rail.unmount();
  }
});

test("a mark on a later message of the run shows on the folded tick, and its toggle takes it off", async () => {
  const rail = await mount([10]);
  try {
    expect(rail.tick(1).hasAttribute("data-bookmarked")).toBe(true);
    await rail.focus(1);
    const bookmark = rail.host.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!;
    expect(bookmark.getAttribute("aria-pressed")).toBe("true");
    await act(async () => bookmark.click());
    await settle();
    expect(rail.calls).toEqual([{ seq: 10, bookmarked: false }]);
    expect(rail.tick(1).hasAttribute("data-bookmarked")).toBe(false);
  } finally {
    await rail.unmount();
  }
});
