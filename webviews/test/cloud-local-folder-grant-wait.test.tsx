// A folder of this Mac picked with Cloud picked goes to the Cloud start as itself (the host copies or projects
// it onto the machine): only once the host granted it (`workspace.useFolder`). A Return right after the pick,
// with the grant still out, started the Cloud chat with no folder at all (`home`), the pick dropped (cmux#53226).
// The send now waits for the grant: the prompt stays, and the Return after it starts in the picked folder.
//
// The pane runs its real client against the in-page mock daemon; the native host is a stub.
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
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let restoreAnswer: (() => void) | undefined;
/// The daemon methods the page sent, in order.
let daemonCalls: string[] = [];

const FOLDER = "/tmp/cloud-empty-chat";
const PROMPT = "Run the sidebar tests and fix what fails";

/// The project folder is trusted on the mock daemon, and every method it gets is recorded.
async function trustFolder() {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  proto.answer = function (this: unknown, method, params) {
    daemonCalls.push(method);
    if (method === "acp.trust.get" && params.cwd === FOLDER)
      return Promise.resolve({ cwd: FOLDER, level: "trusted", harnesses: { claude: "trusted", codex: "trusted" } });
    return answer.call(this, method, params);
  };
}

afterEach(async () => {
  restoreAnswer?.();
  restoreAnswer = undefined;
  daemonCalls = [];
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
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

type FieldElement = HTMLElement & { acpmuxMarkdownField?: { value(): string; type(text: string): unknown } };
const promptElement = () => host.querySelector<FieldElement>(".acpmux-composer-prompt");
const promptField = () => {
  const element = promptElement();
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};

type Debug = {
  runMode(mode?: string): { runMode?: string | null; error?: string };
  pickFolder(cwd: string): Record<string, unknown>;
};
const debug = () => (dom.window as unknown as { cmuxAcpmuxDebug?: Debug }).cmuxAcpmuxDebug!;
const actions = () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;

const PICKED = "/Users/you/src/app";

/// A new chat whose host offers Cloud; `workspace.useFolder` answers only when `grant()` runs.
async function mount() {
  if (!restoreAnswer) await trustFolder();
  const starts: Record<string, unknown>[] = [];
  const grants: (() => void)[] = [];
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            if (message.method === "cloud.startChat") {
              starts.push({ ...message.params });
              return new Promise(() => {});
            }
            if (message.method === "workspace.useFolder") {
              const cwd = message.params?.cwd;
              return new Promise((done) => grants.push(() => done({ ok: true, value: { status: "ok", cwd } })));
            }
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      sandboxState: true,
                      cwd: FOLDER,
                    }
                  : message.method === "sandbox.state"
                    ? {}
                    : message.method === "transport.gesture"
                      ? { ticket: "ticket-1" }
                      : undefined,
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
  await until(() => actions() !== undefined && promptField() !== undefined, "the new chat connects");
  return { starts, grants, grant: () => act(async () => grants.splice(0).forEach((run) => run())) };
}

async function pressSend() {
  const editable = promptElement()!.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await tick();
}

test("with Cloud picked, a Return before this Mac's picked folder is granted waits, then starts in that folder", async () => {
  const pane = await mount();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked");
  await act(async () => void debug().pickFolder(PICKED));
  await until(() => pane.grants.length === 1, "the pick asks the host for the folder");
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  await pressSend();
  for (let step = 0; step < 10; step += 1) await tick();
  // Before: a Cloud start with `home: true`, the picked folder dropped.
  expect(pane.starts).toEqual([]);
  expect(promptField()?.value()).toBe(PROMPT);
  await pane.grant();
  for (let step = 0; step < 5; step += 1) await tick();
  await pressSend();
  await until(() => pane.starts.length === 1, "the send after the grant starts the chat in Cloud");
  expect(pane.starts[0]!.cwd).toBe(PICKED);
  expect(pane.starts[0]!.home).toBeUndefined();
}, 60_000);

test("a folder grant the host never answers holds a Cloud send no longer than the grant wait", async () => {
  const pane = await mount();
  await until(() => debug().runMode("cloud").runMode === "cloud", "Cloud is picked");
  await act(async () => void debug().pickFolder(PICKED));
  await until(() => pane.grants.length === 1, "the pick asks the host for the folder");
  await act(async () => void promptField()!.type(PROMPT));
  await until(() => promptField()?.value() === PROMPT, "the composer takes the prompt");
  // Past CLOUD_FOLDER_GRANT_WAIT_MS (3 s) the composer sends again, as every grant wait ends.
  // fixed-wait: the bound is the behaviour under test; the real app timer must run out, nothing signals it.
  await act(async () => new Promise((done) => setTimeout(done, 3_300)));
  await pressSend();
  await until(() => pane.starts.length === 1, "the send starts the chat in Cloud once the wait is over");
}, 60_000);
