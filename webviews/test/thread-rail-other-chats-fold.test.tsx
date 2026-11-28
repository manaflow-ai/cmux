// l10n-allow-file: synthetic senders and prompts, and the visible copy they read as.
// Messages from other chats get no tick on the prompt rail: it ticks only the person's prompts (Leo,
// 2026-11-27: "honestly non-user messages shouldnt appear in the scroll rail anymore"). Before, a run of
// them folded into one "Received N messages" tick (Leo, 2026-11-03: "i've always been on the fence
// about messages from other chats showing up in that prompt jump scroll rail individual elements").
// The person's prompts keep a tick each, their order and their jumps; the right-click "received"
// choice still ticks the messages (thread-minimap-filter-fades.test.tsx).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, ConversationLayout } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";
import { railFrame } from "./support/railFrame";
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

afterAll(async () => {
  setBookmarkTransport(undefined);
  await teardownDom(saved, { window: dom.window, scope });
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
  await railFrame();
  await settle();
  const tick = (index: number) => host.querySelector<HTMLElement>(`[data-tick="${index}"]`)!;
  const focus = (index: number) => act(async () => tick(index).focus());
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { host, scroller, tick, focus, calls, unmount };
}

test("other chats' messages get no tick; the person's prompts keep one each, in order", async () => {
  const rail = await mount([]);
  try {
    // Prompt, three ux-owner messages, prompt, one picker message: two ticks, not six.
    expect(rail.host.querySelectorAll("[data-tick]").length).toBe(2);
    expect(rail.tick(0).closest("li")!.getAttribute("aria-setsize")).toBe("2");
    expect(rail.host.querySelector("[data-tick][data-incoming]")).toBeNull();
    await rail.focus(0);
    expect(rail.host.querySelector(".acpmux-minimap__prompt")!.textContent).toContain("Plan the change");
    await rail.focus(1);
    expect(rail.host.querySelector(".acpmux-minimap__prompt")!.textContent).toContain("Land it");
    expect(rail.host.querySelector(".acpmux-minimap__from")).toBeNull();

    // The arrow keys step from one of the person's prompts to the next.
    await rail.focus(0);
    await act(async () =>
      rail.tick(0).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })),
    );
    expect((dom.window.document.activeElement as HTMLElement).dataset.tick).toBe("1");
  } finally {
    await rail.unmount();
  }
});

test("a tick jumps to its own prompt, past the messages before it, and bookmarks it", async () => {
  const rail = await mount([]);
  try {
    await act(async () => rail.tick(1).click());
    await settle();
    // "Land it" (user-13) is row 8; its top is 3200.
    expect(rail.scroller.scrollTop).toBeGreaterThan(2400);
    await rail.focus(1);
    await act(async () => rail.host.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!.click());
    await settle();
    expect(rail.calls).toEqual([{ seq: 13, bookmarked: true }]);
    expect(rail.tick(1).hasAttribute("data-bookmarked")).toBe(true);
  } finally {
    await rail.unmount();
  }
});
