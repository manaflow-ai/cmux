// l10n-allow-file: test fixture text, not shipped UI.
// cmux#63350: a chat page that idle hibernation released is built again when its tab shows. With
// acpmux stalled (a starved or stopped daemon), the page's handshake fails quietly: the host's status
// lookup runs out its deadline (AgentPaneHost `timedOut`, "acpmux status unanswered by the lookup's
// deadline"), which is a failure the pane retries on its own and says nothing of (hostRetry.ts
// `hostSelfRetrying`). The page drew its chat screen with no rows and nothing naming the chat, and the
// host's loading state gave up on it and showed it (AgentPaneView+Loading.swift): to the person,
// their chat was gone and an empty one stood in its place. These hold, while the handshake fails:
// - the page draws no empty chat: no composer, no chips, no new chat, only the loading mark;
// - once acpmux answers, the chat the tab names opens with its rows.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  dom.window.sessionStorage.clear();
  delete (dom.window as unknown as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext;
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  await settleReact();
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
async function until(check: () => boolean, what: string, within = 15_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}



/// The chat page the host builds again for a tab bound to `session` (its document names the chat,
/// AgentPaneChatSnapshots `__cmuxRestoredChat`, with no copy or tail kept of it), on a host whose
/// handshake fails as a stalled acpmux makes it fail until `answering()` is true.
async function mountRebuilt(answering: () => boolean) {
  const { WORKED_SESSION } = await import("../src/agent-session/acpmux/mockFixture");
  Object.assign(dom.window, { __cmuxRestoredChat: WORKED_SESSION, __cmuxChatSnapshot: null });
  const ready = { protocolVersion: 1, transport: "mock", sessionId: WORKED_SESSION, sessionMustExist: true, machineName: "Mac" };
  const stalled = {
    code: "host_unavailable",
    message: "The agent service did not answer in time.",
    details: { reconnecting: true },
  };
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string }) => {
            if (message.method === "ready" || message.method === "reconnect")
              return Promise.resolve(answering() ? { ok: true, value: ready } : { ok: false, error: stalled });
            return Promise.resolve({
              ok: true,
              value: message.method === "chat.scrollAnchor.get" ? null : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  return WORKED_SESSION;
}

const rows = () => host.querySelectorAll(TRANSCRIPT_ROW).length;
/// An empty chat: the chat view's composer or its stage, with no rows in it.
const drawsEmptyChat = () =>
  rows() === 0 &&
  (host.querySelector(".acpmux-composer-prompt") !== null ||
    host.querySelector(".acpmux-stage") !== null ||
    host.querySelector("[data-plain-new-chat]") !== null ||
    host.querySelector("[data-new-chat]") !== null);
const loadingMark = () =>
  host.querySelector(".acpmux-pane-loading") !== null || host.querySelector(".acpmux-transcript-loading") !== null;

test("a rebuilt chat page whose handshake acpmux stalls shows the loading mark, never an empty chat", async () => {
  let answering = false;
  await mountRebuilt(() => answering);
  // Seconds of quiet retries, as the daemon stays stalled: the page asks again and again.
  const deadline = Date.now() + 4_000;
  while (Date.now() < deadline) {
    await tick();
    expect(drawsEmptyChat(), "the page drew an empty chat while its handshake failed").toBe(false);
  }
  expect(loadingMark(), "the page shows it is loading the chat").toBe(true);
  // acpmux answers: the tab's chat opens with its rows.
  answering = true;
  await act(async () => dom.window.dispatchEvent(new dom.window.Event("online")));
  await until(() => rows() > 0, "the chat draws once acpmux answers", 30_000);
}, 60_000);
