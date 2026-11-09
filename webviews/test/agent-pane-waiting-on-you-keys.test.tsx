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

async function render(load: () => Promise<unknown> = async () => ({ items, now: 10 }), refuseVerdict = false) {
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
    "wq-row-pr_u",
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
  expect(selected()).toBe("wq-row-pr_u");
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
  await shortcut("AllowOnce");
  expect(calls.answers).toEqual([]);
  expect(host.querySelector("#wq-row-acpmux_p2 .wq-button")).toBeNull();
  await press(list, "Enter");
  expect(calls.opened).toEqual(["s2"]);
  await press(list, "j");
  expect(selected()).toBe("wq-row-pr_u");
  // Deny is Request changes: it sends the verdict at once, with no box to type words acpmux drops.
  await shortcut("Deny");
  expect(host.querySelector("textarea")).toBeNull();
  expect(calls.verdicts).toEqual([["pr:u", "changes"]]);
});

test("another machine's pull request offers no verdict here and keeps its row", async () => {
  const peer = { ...items[2]!, id: "pr:peer", host: "studio" };
  const { calls } = await render(async () => ({ items: [peer], now: 10 }));
  expect(host.querySelector("#wq-row-pr_peer .wq-button")).toBeNull();
  expect(host.querySelector("#wq-row-pr_peer .wq-answers")?.textContent).toBe(
    translate("waiting.answerThere", { host: "studio" }),
  );
  await shortcut("AllowOnce");
  expect(calls.verdicts).toEqual([]);
  expect(host.querySelector("#wq-row-pr_peer")?.hasAttribute("data-leaving")).toBe(false);
});

test("a refused Request changes keeps its row and says so", async () => {
  const pr = items[2]!;
  await render(async () => ({ items: [pr], now: 10 }), true);
  await shortcut("Deny");
  expect(host.querySelector("textarea")).toBeNull();
  expect(host.querySelector(".wq-failure")?.textContent).toBe(translate("waiting.answerFailed"));
  expect(host.querySelector("#wq-row-pr_u")?.hasAttribute("data-leaving")).toBe(false);
});

test("an acpmux older than the queue says so in words", async () => {
  await render(async () => Promise.reject({ code: -32601, message: "Method not found" }));
  expect(host.querySelector(".wq-status")?.textContent).toBe(translate("waiting.older"));
  expect(host.querySelectorAll(".wq-row").length).toBe(0);
});
