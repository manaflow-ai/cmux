// l10n-allow-file: test fixtures (messages between agents).
// Another agent's inbox thread reads in place (conversation/InboxNoticeCard.tsx): shut, the newest
// message whole under the line; "+N more" (or the line) opens every message of the thread in the
// same card, each under its sender and age, newest last; nothing is read through a shell. Leo,
// 2026-11-09, after his coordinator ran `acpmux session inbox "$ACPMUX_SESSION_ID" --thread '...'
// --mark-read` to read a thread: "if cmux-next could be the bridge between claude desktop and
// codex desktop, that'd be super cool. we should keep going further into the whole messaging system
// type situation".
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { InboxNoticeCard } from "../src/agent-session/acpmux/conversation/InboxNoticeCard";
import {
  inboxThreadKey,
  type InboxMessage,
  type InboxNotice,
} from "../src/agent-session/acpmux/conversation/inboxNotice";
import { setMessageOpened } from "../src/agent-session/acpmux/conversation/incomingOpened";
import { configureInboxThreadLook } from "../src/agent-session/acpmux/conversation/inboxThreadLook";
import { configureReceivedLook } from "../src/agent-session/acpmux/conversation/receivedLook";
import {
  newestWholeKey,
  readForIds,
  setThreadRead,
  THREAD_PAGE,
} from "../src/agent-session/acpmux/conversation/inboxThreadRead";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { clockTime } from "../src/agent-session/acpmux/clock";
import { settleReact } from "./support/domTeardown";

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
    "MouseEvent",
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
    MouseEvent: dom.window.MouseEvent,
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
  configureInboxThreadLook(undefined);
  configureReceivedLook(undefined);
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

async function click(element: Element | null | undefined): Promise<void> {
  expect(element).toBeTruthy();
  await act(async () => (element as HTMLElement).click());
}

const MINUTE = 60_000;
/// The shared clock's minute (clock.ts), so each age reads whole minutes from the clock the heads read.
const BASE = clockTime();

/// A thread of `messages`, the notice's own copy (under acpmux's 4 KB).
const threadOf = (threadId: string, messages: InboxMessage[]): InboxNotice => ({
  threads: [
    {
      threadId,
      label: "#2231",
      from: [...new Set(messages.map((m) => m.from))],
      count: messages.length,
      preview: messages.at(-1)!.text.split("\n")[0]!,
      blocker: false,
      promptIds: messages.map((m) => m.promptId!),
      messages,
    },
  ],
});

const RAIL: InboxMessage[] = [
  {
    promptId: "r1",
    from: "picker-lane",
    at: BASE - 9 * MINUTE,
    text: "The rail's band now reaches the last tick.",
  },
  {
    promptId: "r2",
    from: "review-box",
    at: BASE - 5 * MINUTE,
    text: "Checked it in the gallery at both widths.",
  },
  {
    promptId: "r3",
    from: "picker-lane",
    at: BASE - 2 * MINUTE,
    text: "**Merged as #2231.**\n\n- the band ends on the tick\n- no pop-in after the fold",
  },
];

test("shut, a thread's line shows its newest message whole and rendered under it, no first line on it", async () => {
  const container = await render(
    <InboxNoticeCard rowId="row-shut" notice={threadOf("topic:rail", RAIL)} onOpen={() => undefined} />,
  );
  const newest = container.querySelector(".cv-agentmsg__card .cv-inbox__newest");
  expect(newest).not.toBeNull();
  // Markdown, as every received message's text draws: the bold and both list items, not one cut line.
  expect(newest!.querySelector("strong")?.textContent).toBe("Merged as #2231.");
  expect(newest!.querySelectorAll("li").length).toBe(2);
  // Only the newest: the earlier messages wait for the thread to open.
  expect(container.textContent).not.toContain("Checked it in the gallery");
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  // "+2 more" is a control that says it opens the thread.
  const more = container.querySelector<HTMLButtonElement>("button.cv-inbox__more");
  expect(more?.textContent).toBe("+2 more");
  expect(more?.getAttribute("aria-expanded")).toBe("false");
});

test('"+N more" opens every message in place, oldest first, each with sender and age, and closes', async () => {
  const container = await render(
    <InboxNoticeCard rowId="row-more" notice={threadOf("topic:rail-more", RAIL)} onOpen={() => undefined} />,
  );
  await click(container.querySelector("button.cv-inbox__more"));
  expect(container.querySelector("button.cv-inbox__more")?.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".cv-inbox__newest")).toBeNull();
  const sections = [...container.querySelectorAll(".cv-agentmsg__card .cv-inbox__message")];
  expect(sections.length).toBe(3);
  const heads = sections.map((section) => section.querySelector(".cv-inbox__from")?.textContent);
  expect(heads).toEqual(["picker-lane · 9m", "review-box · 5m", "picker-lane · 2m"]);
  expect(sections[0]!.textContent).toContain("The rail's band now reaches the last tick.");
  expect(sections[2]!.querySelector("strong")?.textContent).toBe("Merged as #2231.");
  // The same control closes it back to the newest message.
  await click(container.querySelector("button.cv-inbox__more"));
  expect(container.querySelectorAll(".cv-inbox__message").length).toBe(0);
  expect(container.querySelector(".cv-inbox__newest")?.textContent).toContain("Merged as #2231.");
});

test("shut, a short one-line newest message reads on the line, with no card, and measures as one line", async () => {
  const { layoutConversation } = await import("../src/agent-session/acpmux/model");
  const notice = (newest: string): InboxNotice => ({
    threads: [
      {
        threadId: "pr:31",
        label: "#31",
        from: ["lane-a"],
        count: 1,
        preview: newest.split("\n")[0]!,
        newest,
        blocker: false,
        promptIds: ["s1"],
      },
    ],
  });
  const container = await render(
    <InboxNoticeCard rowId="row-short" notice={notice("Ready for review.")} onOpen={() => undefined} />,
  );
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toBe("Ready for review.");
  expect(container.querySelector(".cv-inbox__newest")).toBeNull();
  // Two lines, or Markdown, read in the card under the line.
  const longer = await render(
    <InboxNoticeCard rowId="row-two" notice={notice("Ready for review.\n\nSHIP at abc.")} onOpen={() => undefined} />,
  );
  expect(longer.querySelector(".cv-inbox__newest")?.textContent).toContain("SHIP at abc.");
  // The estimator measures the short one as a one-line row and the other with its card.
  const row = (id: string, newest: string): AcpmuxRow =>
    ({
      id,
      version: 1,
      at: 1,
      kind: "user",
      text: newest,
      untyped: true,
      incoming: { kind: "inbox", notice: notice(newest) },
    }) as AcpmuxRow;
  const height = (r: AcpmuxRow) => layoutConversation([r], 720, new Map()).heights[0]!;
  // A long newest acpmux sent whole is measured whole (cut to eight lines), never as its preview.
  const long = Array.from({ length: 12 }, (_, index) => `Line ${index + 1} of the landing report.`).join("\n");
  expect(height(row("est-long-newest", long))).toBeGreaterThan(
    height(row("est-two-lines", "Line 1.\n\nLine 2.")) + 3 * 18,
  );
  expect(height(row("est-one", "Ready for review."))).toBeLessThan(
    height(row("est-two", "Ready for review.\n\nSHIP at abc.")),
  );
});

test("a click on the line opens the whole thread too", async () => {
  const container = await render(
    <InboxNoticeCard rowId="row-line" notice={threadOf("topic:rail-line", RAIL)} onOpen={() => undefined} />,
  );
  await click(container.querySelector(".cv-agentmsg__toggle"));
  expect(container.querySelectorAll(".cv-agentmsg__card .cv-inbox__message").length).toBe(3);
});

test("a preview-only thread reads as it draws, shows the newest whole, and does not read again", async () => {
  const reads: string[] = [];
  const whole = "Broker refusal on #28564.\n\nThe review is SHIP at 3b01de6; can you land it from a host with a token?";
  const notice: InboxNotice = {
    threads: [
      {
        threadId: "from:ao-log-bloat/pr:28564",
        label: "#28564",
        from: ["ao-log-bloat"],
        count: 1,
        preview: "Broker refusal on #28564.",
        blocker: true,
        promptIds: ["b1"],
      },
    ],
  };
  const readThread = async (threadId: string) => {
    reads.push(threadId);
    return [{ promptId: "b1", from: "ao-log-bloat", text: whole }];
  };
  const card = <InboxNoticeCard rowId="row-read" notice={notice} onOpen={() => undefined} readThread={readThread} />;
  const container = await render(card);
  await act(async () => undefined);
  // Read with the thread id alone: `chat.inbox.thread` never marks it read for the agent.
  expect(reads).toEqual(["from:ao-log-bloat/pr:28564"]);
  expect(container.querySelector(".cv-inbox__newest")?.textContent).toContain("can you land it from a host");
  // Scrolled out of the virtualized transcript and back: drawn whole at once, from the page's read.
  await act(async () => root!.unmount());
  root = undefined;
  const again = await render(card);
  expect(again.querySelector(".cv-inbox__newest")?.textContent).toContain("can you land it from a host");
  expect(reads.length).toBe(1);
});

test("an opened thread of hundreds draws its newest page, and earlier messages only when asked", async () => {
  const many: InboxMessage[] = Array.from({ length: THREAD_PAGE + 5 }, (_, index) => ({
    promptId: `m${index}`,
    from: index % 2 ? "grid-lane" : "review-box",
    text: `message ${index}`,
  }));
  setMessageOpened(undefined, inboxThreadKey("row-many", "pr:9000"), true);
  try {
    const container = await render(
      <InboxNoticeCard rowId="row-many" notice={threadOf("pr:9000", many)} onOpen={() => undefined} />,
    );
    const shown = () => [...container.querySelectorAll(".cv-inbox__message")].map((node) => node.textContent ?? "");
    expect(shown().length).toBe(THREAD_PAGE);
    // Newest last: the page ends on the newest message.
    expect(shown().at(-1)).toContain(`message ${THREAD_PAGE + 4}`);
    await click(container.querySelector(".cv-inbox__earlier"));
    expect(shown().length).toBe(THREAD_PAGE + 5);
    expect(shown()[0]).toContain("message 0");
    expect(container.querySelector(".cv-inbox__earlier")).toBeNull();
  } finally {
    setMessageOpened(undefined, inboxThreadKey("row-many", "pr:9000"), false);
  }
});

test("an unverified sender keeps its marker and no self-declared words in the opened thread", async () => {
  const notice = threadOf("from:vm/lane", [
    { promptId: "u1", from: "vm/lane", text: "first", unverified: true },
    { promptId: "u2", from: "vm/lane", text: "second", unverified: true },
  ]);
  const container = await render(<InboxNoticeCard rowId="row-unverified" notice={notice} onOpen={() => undefined} />);
  expect(container.querySelector(".cv-unverified")).not.toBeNull();
  await click(container.querySelector("button.cv-inbox__more"));
  expect(container.querySelector(".cv-unverified")).not.toBeNull();
  expect(container.innerHTML).not.toContain("self-declared");
});

test("the drill look opens the thread as rows, a row drills into its message, and back steps out", async () => {
  configureInboxThreadLook("drill");
  const container = await render(
    <InboxNoticeCard rowId="row-drill" notice={threadOf("topic:rail-drill", RAIL)} onOpen={() => undefined} />,
  );
  await click(container.querySelector("button.cv-inbox__more"));
  const rows = () => [...container.querySelectorAll<HTMLButtonElement>(".cv-inbox__row")];
  expect(rows().length).toBe(3);
  expect(rows()[1]!.textContent).toContain("review-box · 5m");
  expect(container.querySelector(".cv-inbox__drill-title")?.textContent).toBe("#2231");
  await click(rows()[1]);
  expect(rows().length).toBe(0);
  expect(container.querySelector(".cv-inbox__drill-title")?.textContent).toBe("review-box");
  expect(container.querySelector(".cv-inbox__drill .cv-inbox__message")?.textContent).toContain(
    "Checked it in the gallery at both widths.",
  );
  await click(container.querySelector(".cv-inbox__back"));
  expect(rows().length).toBe(3);
  await click(container.querySelector(".cv-inbox__back"));
  expect(container.querySelector(".cv-inbox__drill")).toBeNull();
  expect(container.querySelector(".cv-inbox__newest")?.textContent).toContain("Merged as #2231.");
});

test("the row estimator cuts a shut line's long newest message to eight lines, whole once shown", async () => {
  const { layoutConversation } = await import("../src/agent-session/acpmux/model");
  const long = Array.from({ length: 40 }, (_, index) => `Line ${index + 1} of the landing report.`).join("\n");
  const row = (id: string, text: string): AcpmuxRow => ({
    id,
    version: 1,
    at: 1,
    kind: "user",
    text,
    untyped: true,
    inboxDelivery: true,
    inboxThread: {
      threadId: "pr:77",
      sender: "lane-a",
      preview: text.split("\n")[0]!,
      count: 1,
      promptIds: [`${id}-p`],
    },
    incoming: { kind: "message", message: { name: "lane-a", text: text.split("\n")[0]!, raw: text.split("\n")[0]! } },
  });
  const height = (r: AcpmuxRow) => layoutConversation([r], 720, new Map()).heights[0]!;
  const short = row("est-short", "Line 1 of the landing report.");
  const longRow = row("est-long", long);
  // Before the line reads its message it measures the preview; after, the newest message it read.
  const before = height(longRow);
  expect(before).toBe(height(short));
  const key = inboxThreadKey(longRow.id, "pr:77");
  setThreadRead(undefined, key, readForIds(["est-long-p"]), [{ promptId: "est-long-p", from: "lane-a", text: long }]);
  const cut = height(longRow);
  // Eight more lines' worth at most and the Show more row, never the forty.
  expect(cut).toBeGreaterThan(before + 6 * 18);
  expect(cut).toBeLessThan(before + 8 * 24 + 24 + 1);
  setMessageOpened(undefined, newestWholeKey(key), true);
  try {
    expect(height(longRow)).toBeGreaterThan(cut + 20 * 18);
  } finally {
    setMessageOpened(undefined, newestWholeKey(key), false);
  }
});

test("in the card look a direct message shows its words under its line, shut, no first line on it", async () => {
  configureReceivedLook("card");
  const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
  const text = "**Landed #2231.**\n\n- the band ends on the tick\n- no pop-in after the fold";
  const container = await render(
    <IncomingMessageLine
      id="direct-shut"
      message={{ name: "picker-lane", text, raw: text }}
      onOpen={() => undefined}
    />,
  );
  const card = container.querySelector(".cv-agentmsg__card .cv-received__text");
  expect(card?.querySelector("strong")?.textContent).toBe("Landed #2231.");
  expect(card?.querySelectorAll("li").length).toBe(2);
  expect(container.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  expect(container.querySelector(".cv-agentmsg[data-open]")).toBeNull();
});

test("in the card look the row estimator gives a shut direct message its words, cut to eight lines", async () => {
  const { layoutConversation } = await import("../src/agent-session/acpmux/model");
  const row = (id: string, text: string): AcpmuxRow => ({
    id,
    version: 1,
    at: 1,
    kind: "user",
    text,
    untyped: true,
    incoming: { kind: "message", message: { name: "lane-a", text, raw: text } },
  });
  const height = (r: AcpmuxRow) => layoutConversation([r], 720, new Map()).heights[0]!;
  // The shipped `line` look: shut, its line alone, however long.
  const lineOnly = height(row("direct-line", Array.from({ length: 10 }, (_, i) => `Line ${i + 1}.`).join("\n")));
  expect(lineOnly).toBe(height(row("direct-line-one", "Line 1.")));
  configureReceivedLook("card");
  const one = height(row("direct-one", "Line 1."));
  const ten = height(row("direct-ten", Array.from({ length: 10 }, (_, i) => `Line ${i + 1}.`).join("\n")));
  const forty = row("direct-forty", Array.from({ length: 40 }, (_, i) => `Line ${i + 1}.`).join("\n"));
  // Shut, more lines draw taller up to the cut, and forty lines no taller than ten: both are cut.
  expect(ten).toBeGreaterThan(one + 6 * 18);
  expect(height(forty)).toBe(ten);
  setMessageOpened(undefined, forty.id, true);
  try {
    expect(height(forty)).toBeGreaterThan(ten + 20 * 18);
  } finally {
    setMessageOpened(undefined, forty.id, false);
  }
});

test("a notice that held the newest message whole draws it at once and reads the thread only when opened", async () => {
  const { inboxNotice } = await import("../src/agent-session/acpmux/conversation/inboxNotice");
  const whole = "Broker refusal on #28564.\n\nCan you land it from a host with a token?";
  // acpmux past 4 KB (hub/inbox.rs `render`): previews, and the newest message whole under its bound.
  const notice = inboxNotice("[inbox] New messages from other agents in 1 thread.", {
    threads: [
      {
        threadId: "pr:28564",
        label: "#28564",
        from: ["ao-log-bloat"],
        new: 2,
        preview: "Broker refusal on #28564.",
        promptIds: ["n1", "n2"],
        newest: whole,
      },
    ],
  })!;
  expect(notice.threads[0]!.newest).toBe(whole);
  const reads: string[] = [];
  const readThread = async (threadId: string) => {
    reads.push(threadId);
    return [
      { promptId: "n1", from: "ao-log-bloat", text: "First, the rerun." },
      { promptId: "n2", from: "ao-log-bloat", text: whole },
    ];
  };
  const container = await render(
    <InboxNoticeCard rowId="row-newest" notice={notice} onOpen={() => undefined} readThread={readThread} />,
  );
  await act(async () => undefined);
  expect(container.querySelector(".cv-inbox__newest")?.textContent).toContain("Can you land it from a host");
  expect(reads).toEqual([]);
  await click(container.querySelector("button.cv-inbox__more"));
  await act(async () => undefined);
  expect(reads).toEqual(["pr:28564"]);
  expect(container.querySelectorAll(".cv-inbox__message").length).toBe(2);
});
