// l10n-allow-file: synthetic agent names and messages.
// Messages other agents sent that wait for the agent, inbox notices among them, draw as ONE flat run
// of received lines in the one waiting group: each line the sender and that message's own first
// line, no harness text for the agent, no group inside the group, no sender heads, and nothing twice
// (Leo, 2026-11-01, on "7 messages from 2 sessions" holding "13 inbox threads" holding an "inbox"
// row per delivery whose text was acpmux's instructions: "WTF IS THIS FUCKING RENDERING").
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

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
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;
const { createRoot } = await import("react-dom/client");
const { queuedMessage } = await import("../src/agent-session/acpmux/direct");
const { queuedMessageRows } = await import("../src/agent-session/acpmux/conversation/queuedMessages");
const { pendingMessagesRow } = await import("../src/agent-session/acpmux/conversation/pendingMessages");
const { PendingMessagesCard } = await import("../src/agent-session/acpmux/conversation/PendingMessagesCard");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { InboxNoticeCard } = await import("../src/agent-session/acpmux/conversation/InboxNoticeCard");
const { PromptMarksSession } = await import("../src/agent-session/acpmux/threadMinimap/promptMarks");
const { TranscriptDisclosureProvider } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
const { LANE_NOTICE_BATCH } = await import("../src/agent-session/acpmux/model");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

// The text acpmux gave the agent, which must never show.
const HARNESS =
  "[inbox] New messages from other agents in 1 thread. They need no turn of your own: read a thread whole with the inbox_read tool (its thread id), answer in it with inbox_reply, or leave it for later.";

/// A queued inbox notice as acpmux records it: from `inbox`, its threads in its provenance.
const notice = (sender: string, pr: number, line: string, promptId: string) => ({
  text: `${HARNESS}\n- 1 new in #${pr} from ${sender}: ${line} (thread from:${sender}/pr:${pr})`,
  fromAgent: "inbox",
  _meta: {
    provenance: {
      kind: "inbox_notice",
      threads: [
        {
          threadId: `from:${sender}/pr:${pr}`,
          label: `#${pr}`,
          new: 1,
          from: [sender],
          promptIds: [promptId],
          preview: line,
        },
      ],
    },
  },
});
/// A queued inbox notice read back from acpmux's list, which keeps only its text (no provenance).
const listedNotice = (sender: string, pr: number, line: string) => ({
  text: `${HARNESS}\n- 1 new in #${pr} from ${sender}: ${line} (thread from:${sender}/pr:${pr})`,
  fromAgent: "inbox",
});
const message = (sender: string, text: string) => ({ text, fromAgent: sender });

function queue(records: { id: string; record: Record<string, unknown> }[]): AcpmuxSnapshot["queue"] {
  return records.map(({ id, record }) => ({
    id,
    prompt: String(record.text),
    message: queuedMessage(record)!,
  }));
}

let sessionNumber = 0;
async function mount(group: AcpmuxRow) {
  root = createRoot(host);
  // As App.tsx's PendingMessagesRow draws a member: a message's received line, a notice's threads.
  const renderMessage = (row: AcpmuxRow) =>
    row.incoming?.kind === "inbox" ? (
      <InboxNoticeCard rowId={row.id} notice={row.incoming.notice} onOpen={() => undefined} />
    ) : row.incoming?.kind === "message" ? (
      <IncomingMessageLine id={row.id} message={row.incoming.message} onOpen={() => undefined} />
    ) : null;
  await act(async () =>
    root!.render(
      <PromptMarksSession.Provider value={`inbox-flat-${++sessionNumber}`}>
        <TranscriptDisclosureProvider sessionId={`inbox-flat-${sessionNumber}`}>
          <PendingMessagesCard row={group} renderMessage={renderMessage} />
        </TranscriptDisclosureProvider>
      </PromptMarksSession.Provider>,
    ),
  );
  const toggle = host.querySelector<HTMLButtonElement>(".cv-pending__toggle")!;
  await act(async () => toggle.click());
}

/// Each received line as drawn: its sender and its first line.
const lines = () =>
  [...host.querySelectorAll<HTMLElement>(".cv-received")].map((line) => [
    line.querySelector(".cv-received__from")?.textContent ?? "",
    line.querySelector(".cv-received__preview")?.textContent ?? "",
  ]);

test("waiting messages and inbox notices are one flat run of sender lines, nothing twice", async () => {
  const rows = queuedMessageRows(
    queue([
      { id: "m1", record: message("origin-assist", "Rebased #29001 on the new base.\nDetails follow.") },
      { id: "n1", record: notice("pane-tools", 300, "Ready for review.", "p300") },
      { id: "n2", record: notice("layout-review", 301, "SHIP at 1234abcd.", "p301") },
      { id: "m2", record: message("origin-assist", "Merged #29001.") },
      // The same thread's next message, from acpmux's list: the thread's one line, its newest message.
      { id: "n3", record: listedNotice("pane-tools", 300, "Pushed the fix.") },
      // A notice whose message already waits as its own line: not drawn again.
      {
        id: "n4",
        record: notice("origin-assist", 29001, "Merged #29001.", "m2"),
      },
      { id: "n5", record: listedNotice("message-rows", 302, "Fixed the caret jump after paste.") },
    ]),
  );
  const group = pendingMessagesRow([], rows)!;
  const shown = group.pendingMessages!.displayRows!;
  // No fold inside the group.
  expect(shown.some((row) => row.kind === LANE_NOTICE_BATCH)).toBe(false);
  await mount(group);
  expect(host.querySelectorAll(".cv-pending")).toHaveLength(1);
  expect(host.querySelector(".cv-lane-batch")).toBeNull();
  expect(host.querySelector(".cv-pending__sender-head")).toBeNull();
  // Nothing acpmux wrote for the agent.
  const text = host.textContent ?? "";
  for (const harness of ["New messages from other agents", "inbox_read", "They need no turn", "(thread "])
    expect(text).not.toContain(harness);
  expect(lines()).toEqual([
    ["origin-assist", "Rebased #29001 on the new base."],
    ["pane-tools", "Pushed the fix."],
    ["layout-review", "SHIP at 1234abcd."],
    ["message-rows", "Fixed the caret jump after paste."],
    ["origin-assist", "Merged #29001."],
  ]);
  // The group's line counts what it draws: six messages from four sessions.
  expect(host.querySelector(".cv-pending__count")?.textContent).toBe("6 messages from 4 sessions");
  expect(host.querySelector(".cv-pending__senders")?.textContent).toBe(
    "origin-assist, pane-tools, layout-review, message-rows",
  );
});

test("a queued inbox notice whose threads cannot be read draws nothing, never its text", async () => {
  const rows = queuedMessageRows(
    queue([
      { id: "m1", record: message("origin-assist", "Rebased.") },
      { id: "n1", record: { text: HARNESS.slice(0, 120), fromAgent: "inbox" } },
    ]),
  );
  await mount(pendingMessagesRow([], rows)!);
  expect(lines()).toEqual([["origin-assist", "Rebased."]]);
  expect(host.textContent).not.toContain("New messages from other agents");
});

// Follow-ups from the review at 2e5bf380 (#29830).
test("a notice acpmux lists with no fromAgent stays the notice after a list refresh, never the person's prompt", async () => {
  const { mergeQueue } = await import("../src/agent-session/acpmux/direct");
  const text = `${HARNESS}\n- 1 new in #300 from pane-tools: Ready for review. (thread from:pane-tools/pr:300)`;
  // acpmux's notice has no sender: its list entry names `fromAgent: null` (hub/composers.rs).
  const listed = [{ promptId: "n1", preview: text.slice(0, 400), fromAgent: null, client: "acpmux" }];
  const fromList = mergeQueue([], listed);
  expect(fromList[0]?.message?.inbox?.threads.map((thread) => thread.from)).toEqual([["pane-tools"]]);
  // A refresh keeps the notice the `queued` record named, provenance and all.
  const recorded = queue([{ id: "n1", record: notice("pane-tools", 300, "Ready for review.", "p300") }]);
  const refreshed = mergeQueue(recorded, listed);
  expect(refreshed[0]?.message?.inbox?.threads[0]?.promptIds).toEqual(["p300"]);
  // The person's own prompt listed the same way stays theirs.
  const own = mergeQueue([], [{ promptId: "p", preview: "Fix the caret", fromAgent: null, client: "cmux" }]);
  expect(own[0]?.message).toBeUndefined();
});

test("the merged notice keeps the first notice's id, a new version, and counts each message once", () => {
  const records = (extra: { id: string; record: Record<string, unknown> }[]) =>
    queuedMessageRows(
      queue([
        {
          id: "n1",
          record: {
            ...notice("pane-tools", 300, "second", "p2"),
            _meta: {
              provenance: {
                kind: "inbox_notice",
                threads: [
                  { threadId: "from:pane-tools/pr:300", new: 2, from: ["pane-tools"], promptIds: ["p1", "p2"] },
                ],
              },
            },
          },
        },
        ...extra,
      ]),
    );
  const alone = pendingMessagesRow([], records([]))!;
  const [merged] = alone.pendingMessages!.displayRows!;
  expect(merged!.id).toBe("queued-message-n1");
  expect(merged!.queuedMessage).toBeUndefined();
  // One of the thread's two messages also waits as its own line: the thread keeps the other.
  const both = pendingMessagesRow([], records([{ id: "p1", record: message("pane-tools", "first") }]))!;
  const shown = both.pendingMessages!.displayRows!;
  expect(shown[0]!.version).not.toBe(merged!.version);
  const thread = shown[0]!.incoming?.kind === "inbox" ? shown[0]!.incoming.notice.threads[0] : undefined;
  expect(thread).toMatchObject({ count: 1, promptIds: ["p2"] });
});

test("a notice's text reads paragraphs, spaced keys and quoted labels as acpmux wrote them", async () => {
  const { inboxNoticeFromText } = await import("../src/agent-session/acpmux/conversation/inboxNotice");
  const text = [
    "[inbox] New messages from other agents in 3 threads.",
    "- 1 new in #12 from lane-a (thread from:lane-a/pr:12):",
    "  > First paragraph.",
    "  >",
    "  > Second paragraph.",
    "- 2 new in #13 from lane-b, lane-c (thread pr:13):",
    "  > lane-b: one",
    "  >",
    "  > lane-c: two",
    '- 1 new in "notes from the field" from lane-d: hello (thread topic:notes from the field)',
  ].join("\n");
  const notice = inboxNoticeFromText(text)!;
  expect(notice.threads.map((thread) => thread.threadId)).toEqual([
    "from:lane-a/pr:12",
    "pr:13",
    "topic:notes from the field",
  ]);
  expect(notice.threads[0]!.messages).toEqual([{ from: "lane-a", text: "First paragraph.\n\nSecond paragraph." }]);
  expect(notice.threads[0]!.preview).toBe("First paragraph.");
  expect(notice.threads[1]!.messages).toEqual([
    { from: "lane-b", text: "one" },
    { from: "lane-c", text: "two" },
  ]);
  expect(notice.threads[2]).toMatchObject({ label: "notes from the field", from: ["lane-d"], preview: "hello" });
});
