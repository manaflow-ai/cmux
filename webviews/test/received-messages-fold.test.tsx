// l10n-allow-file: synthetic inbox fixtures (lane names, messages) and their visible copy.
// Other agents' messages next to each other in a turn read as one row, "Received N messages" (Leo,
// 2026-11-02, on a turn of "3 inbox threads <session names…>", "Received 2 messages" and "2 inbox
// threads <session names…>" stacked: "can't we simply just display most of these as recieved x
// messages and all of them get revealed then we can expand the messages"). N counts messages, not
// threads; at rest the row lists no session names (the senders' short names are its hover); opened,
// every message is its own received line (sender and first line); each of those opens to the whole
// message.
//
// Before: inbox notices drew "N inbox threads" with every session name, and a Claude turn's
// received steers between them folded into their own "Received 2 messages" line, so one turn drew
// three rows for one thing. After: one "Received 7 messages" row.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

// Claude's in-place runs (claudeTurnFold.experiment.ts arm "runs"): these tests cover that arm. The
// default folds a Claude turn under "Worked for", as Codex does (turnFoldStyle.test.ts).
beforeAll(() => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = undefined;
});

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
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { LaneNoticeBatch } = await import("../src/agent-session/acpmux/conversation/LaneNoticeBatch");
const { projectInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { incomingPrompt } = await import("../src/agent-session/acpmux/conversation/incomingMessage");
const { inboxText } = await import("../src/agent-session/acpmux/conversation/inboxNotice");
const { messageRunSummary } = await import("../src/agent-session/acpmux/conversation/messageRuns");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { PromptMarksSession } = await import("../src/agent-session/acpmux/threadMinimap/promptMarks");
const { TranscriptDisclosureProvider } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});

/// An inbox notice as acpmux sends it (hub/inbox.rs `render`): one thread per sender, each with
/// `count` new messages.
function inbox(senders: string[], count = 1, fields: Partial<AcpmuxRow> = {}): AcpmuxRow {
  const at = (n += 1);
  const threads = senders.map((from, index) => ({
    threadId: `from:${from}-${at}`,
    label: "",
    new: count,
    from: [from],
    promptIds: Array.from({ length: count }, (_, k) => `p-${at}-${index}-${k}`),
    blocker: false,
    preview: `Status from ${from}`,
    messages: Array.from({ length: count }, (_, k) => ({
      from,
      promptId: `p-${at}-${index}-${k}`,
      text: `Status from ${from}${k ? ` (${k + 1})` : ""}\n\nThe whole report from ${from}.`,
    })),
  }));
  const text = [
    `[inbox] New messages from other agents in ${threads.length} threads.`,
    ...threads.map((t) => `- ${count} new from ${t.from[0]}: ${t.preview} (thread ${t.threadId})`),
  ].join("\n");
  const incoming = incomingPrompt(text, {
    client: "acpmux",
    _meta: { provenance: { kind: "inbox_notice", noticeId: `notice-${at}`, threads } },
  });
  if (incoming?.kind !== "inbox") throw new Error("the fixture is not an inbox notice");
  return row("user", { text: inboxText(incoming.notice), incoming, untyped: true, ...fields });
}
/// Another agent's message that came in while the turn ran (a steer into it).
const received = (name: string, text: string) =>
  row("user", {
    text: "",
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
  });

/// Leo's screenshot: a notice of three threads, two messages that came in during its turn, and a
/// notice of two threads, after a finished turn.
const screenshot = () => [
  row("user", { text: "Watch the nightly" }),
  row("assistant", { text: "Watching." }),
  row("turnSummary", { status: "completed" } as Partial<AcpmuxRow>),
  inbox(["build-box-11/nightly-rollback", "lane-box-1/opus-session-info", "lane-box-1/grid"]),
  received("lane-box-3/picker", "Picker polish is up for review."),
  received("lane-box-4/rail", "Rail pitch landed."),
  inbox(["build-box-02/base-red-watch-quiet", "lane-box-1/ux-owner"]),
];

const shown = (family: string) =>
  projectInboxRows(turnView(screenshot(), new Set(), { agentFamily: family })).filter((r) => r.kind !== "date");

for (const family of ["claude", "codex"])
  test(`a turn's notices and received lines next to each other are one row of every message (${family})`, () => {
    const rows = shown(family);
    const groups = rows.filter((r) => r.kind === "laneNoticeBatch");
    expect(rows.map((r) => r.kind)).toEqual(["user", "assistant", "turnSummary", "laneNoticeBatch"]);
    expect(groups).toHaveLength(1);
    // Every message is its own row under it: 3 + 2 + 2.
    expect(
      groups[0]!.laneNoticeBatch!.rows.map((r) => r.incoming?.kind === "message" && r.incoming.message.name),
    ).toEqual([
      "build-box-11/nightly-rollback",
      "lane-box-1/opus-session-info",
      "lane-box-1/grid",
      "lane-box-3/picker",
      "lane-box-4/rail",
      "build-box-02/base-red-watch-quiet",
      "lane-box-1/ux-owner",
    ]);
  });

test("a received line that ends a turn is not merged with the next turn's notice across its footer", () => {
  const rows = projectInboxRows(
    turnView(
      [
        row("user", { text: "go" }),
        received("lane-a", "one"),
        received("lane-b", "two"),
        row("assistant", { text: "done" }),
        row("turnSummary", { status: "completed" } as Partial<AcpmuxRow>),
        inbox(["lane-c", "lane-d"]),
      ],
      new Set(),
      { agentFamily: "claude" },
    ),
  ).filter((r) => r.kind !== "date");
  expect(rows.map((r) => r.kind)).toEqual(["user", "laneNoticeBatch", "assistant", "turnSummary", "laneNoticeBatch"]);
});

for (const family of ["claude", "codex"])
  test(`two received lines with no notice among them are one row too (${family})`, () => {
    const rows = projectInboxRows(
      turnView(
        [
          row("user", { text: "go" }),
          row("assistant", { text: "Asking the lanes." }),
          received("lane-a", "one"),
          received("lane-b", "two"),
        ],
        new Set(),
        { agentFamily: family },
      ),
    ).filter((r) => r.kind !== "date");
    expect(rows.map((r) => r.kind)).toEqual(["user", "assistant", "laneNoticeBatch"]);
    expect(rows[2]!.laneNoticeBatch!.rows).toHaveLength(2);
  });

test("a run with a lane report among its received lines still folds as a message run", () => {
  const report = row("user", {
    text: "",
    continues: true,
    incoming: {
      kind: "message",
      message: {
        name: "review-box",
        sessionId: "review-box",
        report: true,
        text: "lane report: turn 1 ended, idle.",
        raw: "lane report: turn 1 ended, idle.",
      },
    },
  });
  const rows = turnView(
    [
      row("user", { text: "go" }),
      row("assistant", { text: "Asking the lanes." }),
      received("lane-a", "one"),
      report,
      row("assistant", { text: "done" }),
      row("turnSummary", { status: "completed" } as Partial<AcpmuxRow>),
    ],
    new Set(),
    { agentFamily: "claude" },
  );
  const run = rows.find((r) => r.kind === "messageRun")?.messageRun;
  expect(run && messageRunSummary(translate, run)).toBe("Received 2 messages");
});

test("a message run counts an inbox notice's messages, not its threads", () => {
  const send: AcpmuxActivity = {
    kind: "tool",
    text: "SendMessage",
    tool: { id: "send-1", title: "SendMessage", kind: "other", status: "completed", inputSummary: '{"to":"lane-a"}' },
  };
  const rows = turnView(
    [
      row("user", { text: "go" }),
      row("activity", { items: [send], toolCount: 1 }),
      inbox(["lane-a"], 3, { continues: true }),
      row("assistant", { text: "done" }),
      row("turnSummary", { status: "completed" } as Partial<AcpmuxRow>),
    ],
    new Set(),
    { agentFamily: "claude" },
  );
  const run = rows.find((r) => r.kind === "messageRun")?.messageRun;
  expect(run && messageRunSummary(translate, run)).toBe("Sent a message, received 3 messages");
});

let sessionNumber = 0;
async function mount(batch: AcpmuxRow) {
  root = createRoot(host);
  const renderMessage = (member: AcpmuxRow) =>
    member.incoming?.kind === "message" ? (
      <IncomingMessageLine key={member.id} id={member.id} message={member.incoming.message} onOpen={() => {}} />
    ) : null;
  const session = `received-messages-fold-${++sessionNumber}`;
  await act(async () =>
    root!.render(
      <PromptMarksSession.Provider value={session}>
        <TranscriptDisclosureProvider sessionId={session}>
          <LaneNoticeBatch row={batch} renderMessage={renderMessage} />
        </TranscriptDisclosureProvider>
      </PromptMarksSession.Provider>,
    ),
  );
}
const click = async (selector: string) => {
  const button = host.querySelector<HTMLButtonElement>(selector);
  expect(button).not.toBeNull();
  await act(async () => button!.click());
};

test('the row reads "Received 7 messages" with no session names, and opens to each message, then its whole text', async () => {
  const batch = shown("claude").find((r) => r.kind === "laneNoticeBatch")!;
  await mount(batch);
  const head = host.querySelector<HTMLElement>(".cv-lane-batch__toggle")!;
  expect(head.textContent).toBe("Received 7 messages");
  expect(head.textContent).not.toContain("/");
  // Its hover lists the messages newest first (MessageGroupHover.tsx), not a title of names (Leo,
  // 2026-11-07: "the hover preview when you receive a lot of messages, this is not useful").
  expect(head.title).toBe("");
  expect(host.querySelector(".cv-received")).toBeNull();
  await click(".cv-lane-batch__toggle");
  const lines = [...host.querySelectorAll<HTMLElement>(".cv-received")];
  expect(lines).toHaveLength(7);
  // Each line: the sender, then the message's first line.
  expect(lines[3]!.querySelector(".cv-received__from")?.textContent).toContain("picker");
  expect(lines[3]!.textContent).toContain("Picker polish is up for review.");
  expect(lines[0]!.querySelector(".cv-received__text")).toBeNull();
  await click(".cv-received .cv-agentmsg__toggle");
  expect(host.querySelector(".cv-received .cv-received__text")?.textContent).toContain(
    "The whole report from build-box-11/nightly-rollback.",
  );
});
