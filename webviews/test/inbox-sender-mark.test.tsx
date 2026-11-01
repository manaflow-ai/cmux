// l10n-allow-file: test fixtures.
// An inbox line's sender mark (conversation/InboxNoticeCard.tsx through IncomingMessageCard.tsx
// SenderMark) is the sender's real harness: the listed chat's, else the one acpmux bound on the
// notice (`fromHarness`), else the neutral agent glyph. Never a mark guessed from the sender's name:
// a Codex lane called `claude-sr2-fleet-mesh-2` drew a mark from its name (cmux#30247). A folded
// group of one sender draws that sender's mark in the tool rows' icon slot; of several, the messages
// glyph. Leo, 2026-11-01: "i wanted this to be left aligned with the other tool calls".
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { InboxNotice, InboxThread } from "../src/agent-session/acpmux/conversation/inboxNotice";

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
  Range: dom.window.Range,
  localStorage: dom.window.localStorage,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { InboxNoticeCard } = await import("../src/agent-session/acpmux/conversation/InboxNoticeCard");
const { senderHarness } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { groupSender } = await import("../src/agent-session/acpmux/conversation/MessageGroupHead");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");

const entry = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }) =>
  ({ displayTitle: fields.name ?? "", pendingPermissions: 0, ...fields }) as AcpmuxSessionEntry;
const sessions = [
  entry({ sessionId: "s-claude", name: "grid-lane", harness: "claude" }),
  // A Codex chat whose name starts with another harness's.
  entry({ sessionId: "s-mesh", name: "claude-sr2-fleet-mesh-2", harness: "codex" }),
  // Two different chats with one name, on different harnesses (cmux#30821).
  entry({ sessionId: "s-rev-claude", name: "reviewer", harness: "claude" }),
  entry({ sessionId: "s-rev-codex", name: "reviewer", harness: "codex" }),
];

const thread = (from: string, fields: Partial<InboxThread> = {}): InboxThread => ({
  threadId: `from:${from}/pr:9`,
  label: "#9",
  from: [from],
  count: 1,
  preview: "Review passed; landing it now.",
  blocker: false,
  promptIds: [`p-${from}`],
  ...fields,
});

async function render(notice: InboxNotice) {
  const store = new SubsessionStore();
  store.set(sessions);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => undefined }}>
        <InboxNoticeCard rowId="row-1" notice={notice} onOpen={() => undefined} />
      </SubsessionContext.Provider>,
    ),
  );
}

/// The brand each line's mark draws (`data-agent` of AgentMark's svg), or "neutral" for the agent glyph.
const marks = (selector: string) =>
  [...host.querySelectorAll<HTMLElement>(selector)].map((slot) => {
    const brand = slot.querySelector<SVGElement>("svg.agent-mark");
    if (brand) return brand.getAttribute("data-agent");
    return slot.querySelector("svg") ? "neutral" : "none";
  });

test("a Claude sender draws the Claude mark", async () => {
  await render({ threads: [thread("grid-lane", { fromSession: "s-claude" })] });
  expect(marks(".cv-received__mark")).toEqual(["claude"]);
});

test("a Claude sender acpmux bound, listed nowhere here, draws the Claude mark", async () => {
  await render({ threads: [thread("far-lane", { fromHarness: "claude" })] });
  expect(marks(".cv-received__mark")).toEqual(["claude"]);
});

test("a Codex chat named claude-… draws its own harness's mark, not Claude's", async () => {
  await render({ threads: [thread("claude-sr2-fleet-mesh-2")] });
  expect(marks(".cv-received__mark")).toEqual(["openai"]);
});

test("an unknown sender named claude-… draws the neutral agent glyph, never a guessed vendor", async () => {
  await render({ threads: [thread("claude-x")] });
  expect(marks(".cv-received__mark")).toEqual(["neutral"]);
  expect(senderHarness(undefined, undefined)).toBeUndefined();
});

test("a folded group of one sender draws its mark in the tool rows' icon slot; of several, the messages glyph", async () => {
  await render({
    threads: [
      thread("grid-lane", { threadId: "pr:1", fromSession: "s-claude" }),
      thread("grid-lane", { threadId: "pr:2", fromSession: "s-claude" }),
    ],
  });
  expect(marks(".cv-inbox__head > .cv-tool__icon")).toEqual(["claude"]);
  act(() => root?.unmount());
  root = undefined;
  await render({
    threads: [thread("grid-lane", { fromSession: "s-claude" }), thread("claude-x", { threadId: "pr:3" })],
  });
  expect(marks(".cv-inbox__head > .cv-tool__icon")).toEqual(["neutral"]);
});

// cmux#30821: the head keys its sender by session, not by name, so two sessions that share a name
// are two senders and the head draws the messages glyph, never the last one's mark.
test("two sessions with one name are two senders: the group head draws the messages glyph", async () => {
  const message = (fields: { sessionId?: string; harness?: string }) => ({
    name: "reviewer",
    text: "",
    raw: "",
    ...fields,
  });
  expect(groupSender([message({ sessionId: "s-rev-claude" }), message({ sessionId: "s-rev-codex" })])).toBeUndefined();
  expect(groupSender([message({ harness: "claude" }), message({ harness: "codex" })])).toBeUndefined();
  expect(groupSender([message({ sessionId: "s-rev-claude" }), message({ sessionId: "s-rev-claude" })])?.sessionId).toBe(
    "s-rev-claude",
  );
  await render({
    threads: [
      thread("reviewer", { threadId: "pr:1", fromSession: "s-rev-claude" }),
      thread("reviewer", { threadId: "pr:2", fromSession: "s-rev-codex" }),
    ],
  });
  expect(marks(".cv-inbox__head > .cv-tool__icon")).toEqual(["neutral"]);
});
