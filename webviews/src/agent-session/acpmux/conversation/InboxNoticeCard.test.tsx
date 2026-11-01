// l10n-allow-file: test fixtures.
// acpmux's inbox notice (InboxNoticeCard.tsx): a thread's line reads its messages from acpmux when
// the notice held only a preview, and what it read never outlives the messages it was read for.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { InboxNoticeCard } from "./InboxNoticeCard";
import type { InboxMessage, InboxNotice } from "./inboxNotice";
import { PendingMessagesCard } from "./PendingMessagesCard";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { pendingMessagesRow } from "./pendingMessages";
import type { AcpmuxRow } from "../model";
import { setMessageOpened } from "./incomingOpened";

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
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!.click());
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
