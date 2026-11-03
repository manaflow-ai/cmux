// l10n-allow-file: synthetic inbox fixture (a lane name and its message).
// Every tick the prompt rail draws can be bookmarked the same way (Leo, 2026-11-03: "it's also
// sometimes a bit weird how there's no bookmarks available"). A message another chat sent through
// acpmux's inbox reaches the transcript as a notice prompt (`user_message`, seq N) that the display
// projection draws as its delivery (laneNoticeBatches.ts `inboxChildren`, row `user-N:inbox:...`).
// The rail draws that delivery's tick, and its card offered no bookmark: the mark was looked up by
// the row id, which only `user-<seq>` and `summary-<seq>` matched. It marks the notice's own seq,
// which acpmux accepts (hub/bookmarks.rs: any `user_message` record).
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
  if (/^(HTML|SVG|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement, createRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ThreadMinimap } = await import("../src/agent-session/acpmux/threadMinimap/ThreadMinimap");
const { setBookmarkTransport, markSeq } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
const { projectInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
const { incomingPrompt } = await import("../src/agent-session/acpmux/conversation/incomingMessage");
const { inboxText } = await import("../src/agent-session/acpmux/conversation/inboxNotice");

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

/// acpmux's inbox notice of one message from `from` (hub/inbox.rs `render`), logged at `seq`.
function inboxNotice(seq: number, from: string, text: string): AcpmuxRow {
  const threads = [
    {
      threadId: `from:${from}`,
      label: "",
      new: 1,
      from: [from],
      promptIds: [`p-${seq}`],
      blocker: false,
      preview: text,
      messages: [{ from, promptId: `p-${seq}`, text }],
    },
  ];
  const raw = [
    "[inbox] New messages from other agents in 1 thread.",
    `- 1 new from ${from}: ${text} (thread from:${from})`,
  ].join("\n");
  const incoming = incomingPrompt(raw, {
    client: "acpmux",
    _meta: { provenance: { kind: "inbox_notice", noticeId: `notice-${seq}`, threads } },
  });
  if (incoming?.kind !== "inbox") throw new Error("the fixture is not an inbox notice");
  return row(`user-${seq}`, "user", { text: inboxText(incoming.notice), incoming, untyped: true });
}

// The person's prompt (seq 3), then another chat's message through the inbox (seq 9), each answered.
const source = [
  row("user-3", "user", { text: "Watch the nightly" }),
  row("assistant-4", "assistant", { text: "Watching." }),
  inboxNotice(9, "lane-box-1/ux-owner", "Session Info is up for review."),
  row("assistant-10", "assistant", { text: "Reading it." }),
];
// What the transcript draws, and so what the rail reads (App.tsx `turnRowsShown`).
const rows = projectInboxRows(source);
const layout: ConversationLayout = {
  tops: Float64Array.from(rows.map((_, index) => index * 100)),
  heights: Float64Array.from(rows.map(() => 100)),
  totalHeight: rows.length * 100,
};

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("the inbox delivery's row keys its mark on the notice's seq", () => {
  const delivery = rows.find((r) => r.id.startsWith("user-9:"));
  expect(delivery?.kind).toBe("user");
  expect(markSeq(delivery!.id)).toBe(9);
  // Ids that name no logged record still carry no mark.
  expect(markSeq("local-abc")).toBeUndefined();
  expect(markSeq("received:user-9")).toBeUndefined();
  expect(markSeq("user-9x")).toBeUndefined();
});

test("another chat's message on the rail has the card's bookmark, as the person's prompt does", async () => {
  const calls: { seq: number; bookmarked: boolean }[] = [];
  setBookmarkTransport({
    get: async (sessionId) => ({ sessionId, bookmarks: [] }),
    set: async (sessionId, seq, bookmarked) => {
      calls.push({ seq, bookmarked });
      return { sessionId, bookmarks: bookmarked ? [seq] : [] };
    },
  });
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      createElement(ThreadMinimap, {
        rows,
        sessionId: "chat-1",
        layout,
        scroller: createRef<HTMLElement>(),
        scrollTop: 0,
        viewportHeight: 600,
        scrolls: true,
        width: 1040,
      }),
    ),
  );
  await settle();
  expect(host.querySelectorAll("[data-tick]").length).toBe(2);
  for (const index of [0, 1]) {
    await act(async () => host.querySelector<HTMLElement>(`[data-tick="${index}"]`)!.focus());
    expect(host.querySelector(".acpmux-minimap__bookmark")).not.toBeNull();
  }
  // Tick 1 is the inbox message: its card names the sender and bookmarks seq 9.
  expect(host.querySelector(".acpmux-minimap__from")?.textContent).toContain("ux-owner");
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!.click());
  await settle();
  expect(calls).toEqual([{ seq: 9, bookmarked: true }]);
  expect(host.querySelector('[data-tick="1"] .acpmux-minimap__dot')).not.toBeNull();
  await act(async () => root.unmount());
  host.remove();
});
