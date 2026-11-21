// A failed start of a chat's first send says why in the pane (#44964).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;
let restoreAnswer: (() => void) | undefined;

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
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  restoreAnswer?.();
  restoreAnswer = undefined;
});

afterAll(async () => {
  // The pane marked the page as the mock daemon's (App.tsx): later files see a plain page again.
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  await settleReact();
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

/// One turn of the page's event loop: what is due now runs, and React renders it.
const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
/// Waits for `check` to hold, a turn at a time; fails with `what` if it never does.
async function until(check: () => boolean, what: string, within = 10_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
type Actions = Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Actions }).cmuxAcpmuxActions;

// A chat pane with no session yet starts one with its first send (direct.ts `ensureSession`), not
// through HarnessSwitch. When acpmux refused that start (here: agent launches turned off, as a build
// session does), the prompt went back into the composer and nothing said why (#44964, seen in the
// tagged build 44964-chat-start-real-error). The pane now says why, and the cause is in the log.
test("a sessionless chat whose first send's start acpmux refuses says why, and logs the cause", async () => {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  let starts = 0;
  proto.answer = async function (method, params) {
    if (method === "session/new") {
      starts += 1;
      // acpmux's launch_policy.rs refusal, as the daemon sends it.
      throw Object.assign(new Error("agent launch is disabled in this build session"), {
        data: { reason: "agent_launch_disabled", retryable: false },
      });
    }
    return answer.call(this, method, params);
  };
  const logged: string[] = [];
  const consoleError = console.error;
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(" "));
  try {
    const { createRoot } = await import("react-dom/client");
    const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
    Object.assign(dom.window, {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: (message: { method: string }) =>
              Promise.resolve({
                ok: true,
                value:
                  message.method === "ready"
                    ? { protocolVersion: 1, transport: "mock", machineName: "Mac", newSession: true }
                    : undefined,
              }),
          },
        },
      },
    });
    root = createRoot(host);
    await act(async () => root!.render(<AcpmuxApp />));
    await until(() => actions()?.["chat.send"] !== undefined, "the pane connected to the mock daemon");
    await act(async () => void (await actions()!["chat.send"]!({ text: "say hello" }).catch(() => undefined)));
    await until(() => starts > 0, "the send started the chat");
    // The notice is a plain row with no Details: the reason is in its one sentence (the tagged build
    // said only "The agent couldn’t start." while the reason went to the log).
    const notice = () => host.querySelector(".acpmux-notice")?.textContent?.trim() ?? "";
    await until(() => notice() !== "", "the pane says the start failed");
    expect(notice()).toBe("Couldn't start the agent: agent launch is disabled in this build session");
    expect(host.textContent).not.toContain("Something went wrong");
    const line = logged.find((entry) => entry.startsWith("agent pane: couldn't start"));
    expect(line).toContain("agent launch is disabled in this build session");
    expect(line).toContain("reason agent_launch_disabled");
  } finally {
    console.error = consoleError;
  }
}, 30_000);
