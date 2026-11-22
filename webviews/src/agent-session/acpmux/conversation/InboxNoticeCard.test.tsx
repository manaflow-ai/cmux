// l10n-allow-file: test fixtures.
// acpmux's inbox notice (InboxNoticeCard.tsx): a thread's line reads its messages from acpmux when
// the notice held only a preview, and what it read never outlives the messages it was read for.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { InboxNoticeCard } from "./InboxNoticeCard";
import { inboxThreadKey, type InboxMessage, type InboxNotice } from "./inboxNotice";
import { PendingMessagesCard } from "./PendingMessagesCard";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { pendingMessagesRow } from "./pendingMessages";
import type { AcpmuxRow } from "../model";
import { setDigestOpened, setMessageOpened } from "./incomingOpened";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function rerender(node: ReactNode): Promise<void> {
  await act(async () => root!.render(node));
}

/// A notice of one thread that held only its preview (over 4 KB, or an older acpmux).
const notice = (promptIds: string[], preview: string): InboxNotice => ({
  threads: [
    { threadId: "pr:9", label: "#9", from: ["lane-a"], count: promptIds.length, preview, blocker: false, promptIds },
  ],
});

const panel = (container: HTMLElement) => container.querySelector(".cv-received__text")?.textContent ?? "";

async function open(container: HTMLElement): Promise<void> {
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-agentmsg__toggle")!.click());
}

test("a thread's line reads its messages again once a later notice brings new ones", async () => {
  const reads: string[] = [];
  let thread: InboxMessage[] = [{ promptId: "a1", from: "lane-a", text: "first, whole" }];
  const readThread = async (threadId: string) => {
    reads.push(threadId);
    return thread;
  };
  const card = (n: InboxNotice) => (
    <InboxNoticeCard rowId="row-later" notice={n} onOpen={() => undefined} readThread={readThread} />
  );
  const container = await render(card(notice(["a1"], "first")));
  await open(container);
  expect(panel(container)).toBe("first, whole");
  thread = [...thread, { promptId: "a2", from: "lane-a", text: "second, whole" }];
  await rerender(card(notice(["a2"], "second")));
  expect(reads).toEqual(["pr:9", "pr:9"]);
  expect(panel(container)).toBe("second, whole");
});

test("a read that finds nothing keeps the preview and is not asked again", async () => {
  let reads = 0;
  const readThread = async () => {
    reads += 1;
    return [];
  };
  const card = (
    <InboxNoticeCard
      rowId="row-empty"
      notice={notice(["b1"], "the preview")}
      onOpen={() => undefined}
      readThread={readThread}
    />
  );
  const container = await render(card);
  await open(container);
  expect(panel(container)).toBe("the preview");
  await rerender(card);
  expect(reads).toBe(1);
});

test("thirteen flattened deliveries render as one-level sender rows without the harness wrapper", async () => {
  const lines = Array.from(
    { length: 13 },
    (_, index) =>
      `- 1 new in #${29626 + index} from lane-${index}: merged #${29626 + index} (thread from:lane-${index}/pr:${29626 + index})`,
  );
  const text = ["New messages from other agents in 13 threads.", ...lines].join("\n");
  const notice: AcpmuxRow = {
    id: "notice-13",
    version: 1,
    at: 1,
    kind: "queuedMessage",
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
    queuedMessage: { promptId: "notice-13" },
  };
  const direct: AcpmuxRow = {
    id: "direct-29626",
    version: 1,
    at: 2,
    kind: "queuedMessage",
    text: "merged #29626",
    incoming: { kind: "message", message: { name: "lane-0", text: "merged #29626", raw: "merged #29626" } },
    queuedMessage: { promptId: "direct-29626" },
  };
  const group = pendingMessagesRow([], [notice, direct])!;
  setMessageOpened(undefined, group.id, true);
  const container = await render(
    <PendingMessagesCard
      row={group}
      onOpen={() => undefined}
      renderMessage={(row) =>
        row.incoming?.kind === "message" ? (
          <div className="cv-incoming">
            <IncomingMessageLine id={row.id} message={row.incoming.message} onOpen={() => undefined} />
          </div>
        ) : null
      }
    />,
  );
  expect(container.querySelectorAll(".cv-pending")).toHaveLength(1);
  expect(container.querySelectorAll(".cv-received")).toHaveLength(13);
  expect(container.textContent).not.toContain("New messages from other agents");
  expect(container.textContent).not.toContain("thread from:");
  expect(container.textContent).toContain("lane-0");
  expect(container.textContent).toContain("merged #29638");
  setMessageOpened(undefined, group.id, false);
});

test("a click on the digest's own line shows every message's words, not only their lines (Leo, 2026-11-05)", async () => {
  const waiting = (id: string, name: string, sessionId: string, text: string): AcpmuxRow => ({
    id,
    version: 1,
    at: 1,
    kind: "queuedMessage",
    text,
    incoming: { kind: "message", message: { name, sessionId, text, raw: text } },
    queuedMessage: { promptId: id },
  });
  const group = pendingMessagesRow(
    [],
    [
      waiting("m1", "grid-lane", "s-13", "landing #2210 now"),
      waiting("m2", "grid-lane", "s-13", "landed #2210"),
      waiting("m3", "build-box/review-lane", "s-08", "review passed, no findings"),
    ],
  )!;
  const container = await render(
    <PendingMessagesCard
      row={group}
      onOpen={() => undefined}
      renderMessage={(row) =>
        row.incoming?.kind === "message" ? (
          <IncomingMessageLine id={row.id} message={row.incoming.message} onOpen={() => undefined} />
        ) : null
      }
    />,
  );
  const head = container.querySelector<HTMLButtonElement>(".cv-pending__toggle")!;
  expect(head.textContent).toContain("2");
  await act(async () => head.click());
  const words = [...container.querySelectorAll(".cv-received__text")].map((node) => node.textContent);
  expect(words).toEqual(["landing #2210 now", "landed #2210", "review passed, no findings"]);
  // Closed again from the same line, every message closes with it.
  await act(async () => head.click());
  expect(container.querySelectorAll(".cv-received")).toHaveLength(0);
  await act(async () => head.click());
  expect(container.querySelectorAll(".cv-received__text")).toHaveLength(3);
  await act(async () => head.click());
});

test("each message of an opened thread draws the sender chip its claim names", async () => {
  const sentFrom = {
    promptId: "c1",
    harness: "claude-code",
    label: "Claude desktop",
    confirmed: false,
  };
  const readThread = async () => [{ promptId: "c1", from: "Claude Code desktop on mac", text: "hi" }];
  const withClaim: InboxNotice = {
    threads: [{ ...notice(["c1"], "hi").threads[0]!, sentFrom: { c1: sentFrom } }],
  };
  const container = await render(
    <InboxNoticeCard rowId="row-claim" notice={withClaim} onOpen={() => undefined} readThread={readThread} />,
  );
  await open(container);
  const chip = container.querySelector(".cv-inbox__message .cv-user__sent-from");
  expect(chip?.textContent).toContain("Claude desktop");
  expect(container.querySelector(".cv-user__sent-from-note")).not.toBeNull();
});

test("a click on the digest's own line opens a preview-only inbox thread and reads its messages", async () => {
  // A notice that held only its threads' previews (over 4 KB, or an older acpmux): each thread is a
  // line that reads its messages from acpmux once it opens (MessageRow.tsx `inboxThread`).
  const thread = (threadId: string, label: string, from: string, preview: string, promptId: string) => ({
    threadId,
    label,
    from: [from],
    count: 1,
    preview,
    blocker: false,
    promptIds: [promptId],
  });
  const notice: AcpmuxRow = {
    id: "notice-preview",
    version: 1,
    at: 1,
    kind: "queuedMessage",
    text: "[inbox] New messages from other agents in 2 threads.",
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          thread("from:lane-a/pr:9", "#9", "lane-a", "landing #9", "a1"),
          thread("from:lane-b/pr:10", "#10", "lane-b", "review of #10", "b1"),
        ],
      },
    },
    queuedMessage: { promptId: "notice-preview" },
  };
  const group = pendingMessagesRow([], [notice])!;
  const reads: string[] = [];
  const readThread = async (threadId: string): Promise<InboxMessage[]> => {
    reads.push(threadId);
    return [{ promptId: threadId.includes("lane-a") ? "a1" : "b1", from: "lane", text: `${threadId}, whole` }];
  };
  expect(group.pendingMessages?.displayRows?.every((row) => row.inboxThread)).toBe(true);
  const container = await render(
    <PendingMessagesCard
      row={group}
      onOpen={() => undefined}
      renderMessage={(row) =>
        row.inboxThread ? (
          <InboxNoticeCard
            rowId={row.id}
            notice={{
              threads: [
                {
                  threadId: row.inboxThread.threadId,
                  label: row.inboxThread.label ?? "",
                  from: [row.inboxThread.sender],
                  count: row.inboxThread.count,
                  preview: row.inboxThread.preview,
                  blocker: false,
                  promptIds: [...row.inboxThread.promptIds],
                },
              ],
            }}
            onOpen={() => undefined}
            readThread={readThread}
          />
        ) : null
      }
    />,
  );
  expect(container.querySelectorAll(".cv-received__text")).toHaveLength(0);
  const head = container.querySelector<HTMLButtonElement>(".cv-pending__toggle")!;
  await act(async () => head.click());
  expect(reads.sort()).toEqual(["from:lane-a/pr:9", "from:lane-b/pr:10"]);
  const words = [...container.querySelectorAll(".cv-received__text")].map((node) => node.textContent).sort();
  expect(words).toEqual(["from:lane-a/pr:9, whole", "from:lane-b/pr:10, whole"]);
  // Closed from the same line, every thread closes with it.
  await act(async () => head.click());
  expect(container.querySelectorAll(".cv-received__text")).toHaveLength(0);
});

test("the row estimator gives a preview-only thread its newest message's height, shut or opened", async () => {
  const { layoutConversation } = await import("../model");
  // A preview long enough to wrap, so the card under the line is several lines taller than a short one's.
  const long = Array.from({ length: 12 }, (_, index) => `Step ${index + 1} of the landing report is done.`).join(" ");
  const thread = (threadId: string, from: string, promptId: string, preview: string) => ({
    threadId,
    label: "",
    from: [from],
    count: 1,
    preview,
    blocker: false,
    promptIds: [promptId],
  });
  const noticeOf = (id: string, preview: string): AcpmuxRow => ({
    id,
    version: 1,
    at: 1,
    kind: "queuedMessage",
    text: "[inbox] New messages from other agents in 2 threads.",
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          thread("from:lane-a/pr:9", "lane-a", "a1", preview),
          thread("from:lane-b/pr:10", "lane-b", "b1", preview),
        ],
      },
    },
    queuedMessage: { promptId: id },
  });
  const height = (group: AcpmuxRow) => layoutConversation([group], 720, new Map()).heights[0]!;
  const short = pendingMessagesRow([], [noticeOf("notice-short", "done")])!;
  const group = pendingMessagesRow([], [noticeOf("notice-estimate", long)])!;
  setMessageOpened(undefined, short.id, true);
  setMessageOpened(undefined, group.id, true);
  try {
    // Shut, each thread's card holds its newest message whole: two long ones are taller than two
    // one-line ones by their wrapped lines.
    const shut = height(group);
    expect(shut).toBeGreaterThan(height(short) + 2 * 40);
    // Opened (the digest's head opens every thread), a thread of one message adds nothing: its card
    // held the message already.
    setDigestOpened(
      undefined,
      group.id,
      (group.pendingMessages?.displayRows ?? []).map((row) => inboxThreadKey(row.id, row.inboxThread!.threadId)),
      true,
    );
    expect(height(group)).toBe(shut);
  } finally {
    setDigestOpened(
      undefined,
      group.id,
      (group.pendingMessages?.displayRows ?? []).map((row) => inboxThreadKey(row.id, row.inboxThread!.threadId)),
      false,
    );
    setMessageOpened(undefined, short.id, false);
  }
});
