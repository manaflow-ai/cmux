// l10n-allow-file: test fixtures.
// acpmux's inbox notice (InboxNoticeCard.tsx): a thread's line reads its messages from acpmux when
// the notice held only a preview, and what it read never outlives the messages it was read for.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { InboxNoticeCard } from "./InboxNoticeCard";
import type { InboxMessage, InboxNotice } from "./inboxNotice";

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
