// The classic New Tab page with no agent to name yet (acpmux listed none): Return starts the chat
// with a bare `chat.new` in the folder picked on the page. When acpmux refuses that start for the
// folder's trust answer, the prompt must not be lost with it: it goes once Trust is answered, once.
//
// The pane runs on its in-page mock daemon (transport "mock"), whose session/new refuses the
// picked folder until it is trusted, as acpmux's trust gate does (trust_gate.rs).
import { afterAll, beforeAll, expect, test } from "bun:test";
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
    // acpmux lists no agent: the page has none to name, so its Return sends a bare chat.new.
    cmuxAcpmuxMockHarnesses: [],
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia, cmuxAcpmuxMockHarnesses: [] });
  host = dom.window.document.getElementById("root")!;
});

afterAll(async () => {
  await act(async () => root?.unmount());
  restoreAnswer?.();
  // The pane marked the page as the mock daemon's (App.tsx): later files see a plain page again.
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const folder = "/tmp/untrusted-project";
const settle = async (rounds = 20) => {
  for (let round = 0; round < rounds; round++)
    await act(async () => {
      await new Promise((done) => setTimeout(done, 5));
    });
};
async function until(check: () => boolean, what: string) {
  for (let round = 0; round < 200 && !check(); round++) await settle(1);
  expect(check(), what).toBe(true);
}

test("classic Return with no agent named: a start refused for the folder's trust sends its prompt once Trust is answered, once", async () => {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  let trusted = false;
  const prompts: string[] = [];
  let refusals = 0;
  const started: string[] = [];
  proto.answer = function (this: unknown, method, params) {
    if (method === "session/new") started.push(String(params.cwd ?? ""));
    if (method === "session/new" && params.cwd === folder && !trusted) {
      refusals++;
      return Promise.reject(
        Object.assign(new Error("Trust this folder first"), { data: { reason: "trust.pending", cwd: folder } }),
      );
    }
    if (method === "acp.trust.set" && params.cwd === folder) trusted = params.level === "trusted";
    if (method === "session/prompt") prompts.push(String((params.prompt as { text?: string }[])?.[0]?.text ?? ""));
    return answer.call(this, method, params);
  };

  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) =>
            Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      newTab: {
                        template: "classic",
                        cwd: "/tmp/classic-project",
                        projects: ["/tmp/classic-project", folder],
                      },
                    }
                  : message.method === "workspace.useFolder"
                    ? { status: "ok", cwd: message.params?.cwd }
                    : undefined,
            }),
        },
      },
    },
  });
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => host.querySelector(".acpmux-newtab-field") !== null, "the classic page draws");
  await until(
    () =>
      (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions?.["chat.new"] !==
      undefined,
    "the pane connected to the mock daemon",
  );

  // The folder picked on the page: the chat starts there.
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-project-button")!.click());
  const option = dom.window.document.querySelector<HTMLElement>(
    `.acpmux-project-menu [role="option"][aria-label$="${folder}"]`,
  );
  expect(option, "the picked folder's row").not.toBeNull();
  await act(async () => option!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  const field = host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, "hello");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );

  // acpmux refused the start: the folder's question shows, and nothing went yet.
  await until(() => refusals > 0, "the start was refused");
  const trust = () => dom.window.document.querySelector<HTMLButtonElement>(".acpmux-trust-ask-primary") ?? undefined;
  await until(() => trust() !== undefined, "the trust question shows");
  expect(prompts).toEqual([]);
  // The prompt waits in the chat composer meanwhile, not lost with the refused start.
  await until(
    () => host.querySelector(".acpmux-composer-prompt")?.textContent?.includes("hello") === true,
    "the composer holds the prompt",
  );

  await act(async () => trust()!.click());
  await until(() => prompts.length > 0, "the prompt went after Trust");
  await settle();
  expect(prompts).toEqual(["hello"]);
  // The refused start, then the one after Trust, both in the picked folder: the prompt went there.
  expect(started).toEqual([folder, folder]);
});
