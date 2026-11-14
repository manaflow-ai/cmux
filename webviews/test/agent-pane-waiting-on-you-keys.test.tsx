// l10n-allow-file: test fixtures (sample asks), not shipped UI.
// Waiting on you is keyboard first (queue/QueueScreen.tsx): j/k move the cursor, `x` exports the
// audit trail, Return goes to the chat, and the app's permission shortcuts (the host counts them as
// the person's, then sends the page `cmux-acpmux-permissionAllowOnce` / `-permissionDeny`) answer the
// selected row. A plain letter answers nothing: a permission answer needs the person's own click or
// that shortcut. An answered row leaves as a transition (it stays, collapsed, until acpmux drops
// it), and an older acpmux gets words, not a failure.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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
// jsdom has no layout: scrolling a row into view is a no-op here.
dom.window.HTMLElement.prototype.scrollIntoView = () => {};
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { QueueScreen } = await import("../src/agent-session/acpmux/queue/QueueScreen");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { createQueueCache } = await import("../src/agent-session/acpmux/queue/useQueue");
const { createComments } = await import("../src/agent-session/acpmux/queue/comments");
type Comments = import("../src/agent-session/acpmux/queue/comments").Comments;
type QueueCache = import("../src/agent-session/acpmux/queue/useQueue").QueueCache;

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

const allowDeny = [
  { optionId: "allow", name: "Allow", kind: "allow_once" },
  { optionId: "deny", name: "Deny", kind: "reject_once" },
];
const items = [
  {
    id: "acpmux:p1",
    kind: "approval",
    sessionId: "s1",
    title: "Upload test",
    ask: "Run tests",
    at: 1,
    score: 9,
    permissionId: "p1",
    options: allowDeny,
  },
  {
    id: "acpmux:p2",
    kind: "question",
    sessionId: "s2",
    title: "Startup",
    ask: "Which build?",
    at: 2,
    score: 5,
    permissionId: "p2",
    options: [
      { optionId: "nightly", name: "Nightly" },
      { optionId: "dev", name: "Dev build" },
    ],
  },
  {
    id: "pr:u",
    kind: "pr",
    sessionId: "s3",
    title: "Retry",
    ask: "Review #412",
    at: 3,
    score: 1,
    prUrl: "https://example.com/pull/412",
  },
];

type Calls = { answers: [string, string][]; verdicts: [string, string][]; opened: string[]; exports: number };

async function render(
  load: () => Promise<unknown> = async () => ({ items, now: 10 }),
  refuseVerdict = false,
  extra: { cache?: QueueCache; refreshKey?: string; comments?: Comments } = {},
) {
  const calls: Calls = { answers: [], verdicts: [], opened: [], exports: 0 };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueueScreen
        load={load}
        answer={async (item, choice) => {
          calls.answers.push([item.id, choice.id]);
          return "answered";
        }}
        verdict={async (item, verdict) => {
          calls.verdicts.push([item.id, verdict]);
          if (refuseVerdict) throw new Error("refused");
        }}
        open={(item) => calls.opened.push(item.sessionId)}
        exportAudit={async () => {
          calls.exports++;
          return 3;
        }}
        comments={extra.comments ?? createComments()}
        {...extra}
      />,
    ),
  );
  const list = host.querySelector<HTMLElement>(".wq-list")!;
  return { calls, list };
}

async function press(list: HTMLElement, key: string) {
  await act(async () => {
    list.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

async function shortcut(kind: "AllowOnce" | "Deny") {
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-permission${kind}`));
  });
}

const selected = () => host.querySelector(".wq-row[data-selected]")?.id;

test("the queue is sorted by score and the first ask is selected", async () => {
  const { list } = await render();
  expect([...host.querySelectorAll(".wq-row")].map((row) => row.id)).toEqual([
    "wq-row-acpmux_p1",
    "wq-row-acpmux_p2",
    "wq-row-pr_u__s3",
  ]);
  expect(selected()).toBe("wq-row-acpmux_p1");
  expect(host.querySelector('.wq-row[aria-current="true"]')?.id).toBe("wq-row-acpmux_p1");
  expect(list.tabIndex).toBe(0);
});

test("j and k move; Return goes to the chat; x exports", async () => {
  const { list, calls } = await render();
  await press(list, "j");
  expect(selected()).toBe("wq-row-acpmux_p2");
  await press(list, "j");
  await press(list, "j");
  expect(selected()).toBe("wq-row-pr_u__s3");
  await press(list, "k");
  expect(selected()).toBe("wq-row-acpmux_p2");
  await press(list, "Enter");
  expect(calls.opened).toEqual(["s2"]);
  await press(list, "x");
  expect(calls.exports).toBe(1);
  expect(host.querySelector(".wq-notice")?.textContent).toBe(translate("waiting.exported", { n: 3 }));
});

test("the Allow Once shortcut allows the selected ask; its row leaves as a transition and the cursor moves on", async () => {
  const { list, calls } = await render();
  // A plain letter is a keystroke the page saw, never the person's answer.
  await press(list, "a");
  await press(list, "d");
  expect(calls.answers).toEqual([]);
  await shortcut("AllowOnce");
  expect(calls.answers).toEqual([["acpmux:p1", "allow"]]);
  const row = host.querySelector("#wq-row-acpmux_p1")!;
  // Still drawn, collapsing: no jump, no pop.
  expect(row.hasAttribute("data-leaving")).toBe(true);
  expect(row.getAttribute("aria-hidden")).toBe("true");
  expect(selected()).toBe("wq-row-acpmux_p2");
});

test("a question is answered in its chat; on a pull request Deny asks for the change and Allow accepts", async () => {
  const { list, calls } = await render();
  await press(list, "j");
  // The question offers no answer here: its card in the chat asks the whole of it.
  await press(list, "2");
  // Its shortcut answers nothing and opens the chat, where the card asks it.
  await shortcut("AllowOnce");
  expect(calls.answers).toEqual([]);
  expect(calls.opened).toEqual(["s2"]);
  expect(host.querySelector("#wq-row-acpmux_p2 .wq-button")).toBeNull();
  await press(list, "Enter");
  expect(calls.opened).toEqual(["s2", "s2"]);
  await press(list, "j");
  expect(selected()).toBe("wq-row-pr_u__s3");
  await shortcut("Deny");
  expect(host.querySelector(".wq-comment-field")).not.toBeNull();
  await shortcut("AllowOnce");
  expect(calls.verdicts).toEqual([["pr:u@/s3", "accept"]]);
});

test("another machine's pull request offers no verdict here and keeps its row", async () => {
  const peer = { ...items[2]!, id: "pr:peer", host: "studio" };
  const { calls } = await render(async () => ({ items: [peer], now: 10 }));
  expect(host.querySelector("#wq-row-pr_peer_studio_s3 .wq-button")).toBeNull();
  expect(host.querySelector("#wq-row-pr_peer_studio_s3 .wq-answers")?.textContent).toBe(
    translate("waiting.answerThere", { host: "studio" }),
  );
  await shortcut("AllowOnce");
  expect(calls.verdicts).toEqual([]);
  expect(host.querySelector("#wq-row-pr_peer_studio_s3")?.hasAttribute("data-leaving")).toBe(false);
});

test("a refused Request changes brings its box back with what was typed", async () => {
  const pr = items[2]!;
  await render(async () => ({ items: [pr], now: 10 }), true);
  await shortcut("Deny");
  const field = host.querySelector<HTMLTextAreaElement>(".wq-comment-field")!;
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
    set.call(field, "Split the commit");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  const send = host.querySelector<HTMLButtonElement>('.wq-comment-actions button[data-tone="allow"]')!;
  await act(async () => {
    send.click();
  });
  expect(host.querySelector<HTMLTextAreaElement>(".wq-comment-field")?.value).toBe("Split the commit");
  expect(host.querySelector(".wq-failure")?.textContent).toBe(translate("waiting.answerFailed"));
  expect(host.querySelector("#wq-row-pr_u__s3")?.hasAttribute("data-leaving")).toBe(false);
});

test("an acpmux older than the queue says so in words", async () => {
  await render(async () => Promise.reject({ code: -32601, message: "Method not found" }));
  expect(host.querySelector(".wq-status")?.textContent).toBe(translate("waiting.older"));
  expect(host.querySelectorAll(".wq-row").length).toBe(0);
});

test("a return to the tab paints what it showed without a read, and reads again once the asks changed", async () => {
  const cache = createQueueCache();
  let reads = 0;
  const load = async () => {
    reads++;
    return { items, now: 10 };
  };
  await render(load, false, { cache, refreshKey: "p1" });
  expect(reads).toBe(1);
  act(() => root?.unmount());
  // Back on the tab with the same asks: the rows are there at once and nothing is read.
  await render(load, false, { cache, refreshKey: "p1" });
  expect(reads).toBe(1);
  expect(host.querySelectorAll(".wq-row").length).toBe(3);
  act(() => root?.unmount());
  // The asks changed while another tab showed: the kept rows paint, and the queue reads again.
  await render(load, false, { cache, refreshKey: "p1,p9" });
  expect(reads).toBe(2);
});

test("a failed read keeps the rows it showed, says it failed and offers a retry", async () => {
  const cache = createQueueCache();
  await render(async () => ({ items, now: 10 }), false, { cache, refreshKey: "a" });
  act(() => root?.unmount());
  await render(async () => Promise.reject(new Error("offline")), false, { cache, refreshKey: "b" });
  expect(host.querySelectorAll(".wq-row").length).toBe(3);
  expect(host.querySelector(".wq-status")?.textContent).toContain(translate("waiting.failed"));
  expect(host.querySelector(".wq-status button")).not.toBeNull();
});

test("a failed read after an empty one says it failed, not that nothing waits", async () => {
  const cache = createQueueCache();
  await render(async () => ({ items: [], now: 10 }), false, { cache, refreshKey: "a" });
  expect(host.querySelector(".wq-status")?.textContent).toContain(translate("waiting.empty"));
  act(() => root?.unmount());
  await render(async () => Promise.reject(new Error("offline")), false, { cache, refreshKey: "b" });
  expect(host.querySelector(".wq-status")?.textContent).toContain(translate("waiting.failed"));
  expect(host.querySelector(".wq-status")?.textContent).not.toContain(translate("waiting.empty"));
});

test("a list cut at the read limit says how many there were", async () => {
  await render(async () => ({ items, now: 10, total: 250 }));
  expect(host.querySelector(".wq-status")?.textContent).toContain(translate("waiting.more", { shown: 3, total: 250 }));
  act(() => root?.unmount());
  root = undefined;
  // An acpmux that does not send `total` reads as the rows it sent.
  await render();
  expect(host.querySelector(".wq-status")?.textContent).not.toContain(
    translate("waiting.more", { shown: 3, total: 3 }),
  );
});

test("leaving the tab while an answer's refresh is under way reads again on the return", async () => {
  const cache = createQueueCache();
  let reads = 0;
  // The first read lands; every later one is still under way when the tab goes.
  const load = () => {
    reads++;
    return reads === 1 ? Promise.resolve({ items, now: 10 }) : new Promise(() => {});
  };
  await render(load, false, { cache, refreshKey: "k" });
  await shortcut("AllowOnce");
  expect(reads).toBe(2);
  act(() => root?.unmount());
  // The same asks, but the answer's read never landed: the answered row must not come back
  // from the kept copy without a read.
  await render(load, false, { cache, refreshKey: "k" });
  expect(reads).toBe(3);
});

test("a comment that reached neither the chat nor the clipboard stays on the page until dismissed", async () => {
  const pr = items[2]!;
  const cache = createQueueCache();
  const comments = createComments();
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueueScreen
        load={async () => ({ items: [pr], now: 10 })}
        answer={async () => "answered"}
        verdict={async () => ({ recorded: true, commentCopied: false })}
        open={() => {}}
        exportAudit={async () => 0}
        cache={cache}
        comments={comments}
      />,
    ),
  );
  await shortcut("Deny");
  const field = host.querySelector<HTMLTextAreaElement>(".wq-comment-field")!;
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
    set.call(field, "Split the commit");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    host.querySelector<HTMLButtonElement>('.wq-comment-actions button[data-tone="allow"]')!.click();
  });
  expect(host.querySelector(".wq-unsent")?.textContent).toContain(translate("waiting.commentNotCopied"));
  expect(host.querySelector(".wq-unsent .wq-notice-detail")?.textContent).toBe("Split the commit");
  // Another notice (an export) leaves it.
  await act(async () => {
    host.querySelector<HTMLButtonElement>('button[aria-keyshortcuts="x"]')!.click();
  });
  expect(host.querySelector(".wq-unsent .wq-notice-detail")?.textContent).toBe("Split the commit");
  // So does a tab switch: History's cache keeps it.
  act(() => root?.unmount());
  await render(async () => ({ items: [pr], now: 10 }), false, { cache, comments });
  expect(host.querySelector(".wq-unsent .wq-notice-detail")?.textContent).toBe("Split the commit");
  // Dismissed, it goes.
  await act(async () => {
    host.querySelector<HTMLButtonElement>(".wq-unsent button")!.click();
  });
  expect(host.querySelector(".wq-unsent")).toBeNull();
  expect(comments.get().unsent).toBeUndefined();
});

test("a verdict refused after the tab changed brings its comment back on the return", async () => {
  const pr = items[2]!;
  const cache = createQueueCache();
  const comments = createComments();
  let refuse: (error: Error) => void = () => {};
  const mount = () =>
    act(async () => {
      root = createRoot(host);
      root.render(
        <QueueScreen
          load={async () => ({ items: [pr], now: 10 })}
          answer={async () => "answered"}
          verdict={() =>
            new Promise((_, reject) => {
              refuse = reject;
            })
          }
          open={() => {}}
          exportAudit={async () => 0}
          cache={cache}
          comments={comments}
          refreshKey="k"
        />,
      );
    });
  await mount();
  await shortcut("Deny");
  const field = host.querySelector<HTMLTextAreaElement>(".wq-comment-field")!;
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
    set.call(field, "Split the commit");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    host.querySelector<HTMLButtonElement>('.wq-comment-actions button[data-tone="allow"]')!.click();
  });
  // Another tab while the verdict is under way; it is refused there.
  act(() => root?.unmount());
  await act(async () => refuse(new Error("refused")));
  await mount();
  expect(host.querySelector<HTMLTextAreaElement>(".wq-comment-field")?.value).toBe("Split the commit");
});

test("an answer that lands after the tab changed and came back reads the page shown now", async () => {
  const cache = createQueueCache();
  const comments = createComments();
  let reads = 0;
  let land: () => void = () => {};
  const mount = () =>
    act(async () => {
      root = createRoot(host);
      root.render(
        <QueueScreen
          load={async () => {
            reads++;
            return { items, now: 10 };
          }}
          answer={() =>
            new Promise((resolve) => {
              land = () => resolve("answered");
            })
          }
          verdict={async () => ({})}
          open={() => {}}
          exportAudit={async () => 0}
          cache={cache}
          comments={comments}
          refreshKey="k"
        />,
      );
    });
  await mount();
  expect(reads).toBe(1);
  await shortcut("AllowOnce");
  act(() => root?.unmount());
  await mount();
  const before = reads;
  await act(async () => land());
  expect(reads).toBe(before + 1);
});

test("a key that moved while another tab showed reads on the return, even once it came back", async () => {
  const cache = createQueueCache();
  let reads = 0;
  const load = async () => {
    reads++;
    return { items, now: 10 };
  };
  cache.note("a");
  await render(load, false, { cache, refreshKey: "a" });
  expect(reads).toBe(1);
  act(() => root?.unmount());
  // History saw the key move and come back while Costs showed.
  cache.note("b");
  cache.note("a");
  await render(load, false, { cache, refreshKey: "a" });
  expect(reads).toBe(2);
});
