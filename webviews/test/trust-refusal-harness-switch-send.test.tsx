// Review of cmux#24144 at 8ce2cf2c: a prompt sent while a harness switch starts its chat is held
// by the switch and goes once the new session opens. The switch selects that session before it
// sends, so a trust.pending refusal for the prompt must still belong to its send: the Trust card
// it shows sends the held prompt after Trust. Before, the send's owner was the selection from
// before the switch, the refusal was dropped, and Trust left the prompt unsent.
//
// The pane runs on its in-page mock daemon (transport "mock"); session/prompt refuses the folder
// until it is trusted, as acpmux's trust gate does (trust_gate.rs).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
const trustButton = () =>
  dom.window.document.querySelector<HTMLButtonElement>(".acpmux-trust-ask-primary") ?? undefined;

test("a prompt held by a harness switch and refused for the folder's trust is sent after Trust", async () => {
  const folder = "/tmp/switch-untrusted-project";
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  let trusted = false;
  let started!: () => void;
  const starting = new Promise<void>((done) => (started = done));
  const prompts: string[] = [];
  proto.answer = async function (this: unknown, method, params) {
    const meta = (params._meta as { acpmux?: { harness?: string } } | undefined)?.acpmux;
    // The switch's chat starts only once the prompt is held behind it.
    if (method === "session/new" && meta?.harness === "codex" && params.cwd === folder) await starting;
    if (method === "acp.trust.set" && params.cwd === folder) trusted = params.level === "trusted";
    if (method === "session/prompt") {
      const text = String((params.prompt as { text?: string }[])?.[0]?.text ?? "");
      if (text === "hello" && !trusted)
        throw Object.assign(new Error("Trust this folder first"), { data: { reason: "trust.pending", cwd: folder } });
      prompts.push(text);
    }
    return answer.call(this, method, params);
  };

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
                message.method === "ready" ? { protocolVersion: 1, transport: "mock", machineName: "Mac" } : undefined,
            }),
        },
      },
    },
  });
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => actions()?.["chat.new"] !== undefined, "the pane connected to the mock daemon");

  // Pick another harness: the switch draws the new chat and starts it behind the pane.
  let opened: Promise<unknown> | undefined;
  await act(
    async () => void (opened = actions()!["chat.new"]!({ harness: "codex", cwd: folder }).catch(() => undefined)),
  );
  // Send while the chat starts: the switch holds the prompt for the session it opens.
  let sent: Promise<unknown> | undefined;
  await act(async () => void (sent = actions()!["chat.send"]!({ text: "hello" }).catch(() => undefined)));
  await act(async () => started());
  await act(async () => void (await opened));

  // The session opened, the held prompt went and acpmux refused it for the folder's trust.
  await until(() => trustButton() !== undefined, "the trust question shows");
  await act(async () => void (await sent));
  expect(prompts).toEqual([]);

  await act(async () => trustButton()!.click());
  await until(() => prompts.includes("hello"), "the held prompt went after Trust");
  expect(prompts.filter((text) => text === "hello")).toEqual(["hello"]);
}, 60_000);
