// The classic New Tab page with no agent to name yet (acpmux listed none): Return starts the chat
// with a bare `chat.new` in the folder picked on the page, which stays up until that start settles.
// When acpmux refuses the start, the prompt is never lost with it: a trust refusal sends it once
// Trust is answered, once; any other refusal leaves it in the composer to send again, in the same
// folder.
//
// The pane runs on its in-page mock daemon (transport "mock"), whose session/new refuses the
// picked folder until it is trusted, as acpmux's trust gate does (trust_gate.rs).
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

/// The calls the page made to the mock daemon, and those still unanswered. A `session/prompt` is
/// unanswered until the mock's scripted turn for it ends (its last step and `turn_result`).
const daemon = { calls: 0, open: 0 };
/// Waits until the page has stopped talking to the daemon: every call answered, each prompt's turn
/// ended included, and then no new call for a run of turns. Whatever a refusal, a send or a turn's
/// end sets off has started by then, so a prompt sent twice is counted before the caller checks.
async function quiet(what: string) {
  let seen = -1;
  let still = 0;
  // A prompt's scripted turn takes ten 350 ms steps.
  await until(
    () => {
      if (daemon.open === 0 && daemon.calls === seen) still += 1;
      else [seen, still] = [daemon.calls, 0];
      return still >= 20;
    },
    what,
    20_000,
  );
}

type Answer = (method: string, params: Record<string, unknown>) => Promise<unknown>;
type Refusal = { message: string; data?: Record<string, unknown> };

/// The classic page on the in-page mock daemon, acpmux listing no agent. `refuse` answers each
/// `session/new` in `folder` (the attempts so far, counting this one): a refusal for the start, or
/// undefined to start it; it may wait before answering. `trusted`: acpmux reads the folder as
/// trusted. Records the starts and the prompts sent.
async function mountClassic(
  folder: string,
  refuse: (attempt: number) => Promise<Refusal | undefined>,
  options: { trusted?: boolean } = {},
) {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  const prompts: string[] = [];
  const started: string[] = [];
  let attempts = 0;
  daemon.calls = 0;
  daemon.open = 0;
  const answerCounted: Answer = async function (this: unknown, method, params) {
    if (method === "session/new") {
      started.push(String(params.cwd ?? ""));
      if (params.cwd === folder) {
        const refusal = await refuse(++attempts);
        if (refusal) throw Object.assign(new Error(refusal.message), refusal.data ? { data: refusal.data } : {});
      }
    }
    // A folder the person already trusted: the pane asks no question of its own for it.
    if (options.trusted && method === "acp.trust.get" && params.cwd === folder)
      return { cwd: folder, level: "trusted", harnesses: { claude: "trusted", codex: "trusted" } };
    if (method === "session/prompt") prompts.push(String((params.prompt as { text?: string }[])?.[0]?.text ?? ""));
    return answer.call(this, method, params);
  };
  proto.answer = function (this: unknown, method, params) {
    daemon.calls += 1;
    daemon.open += 1;
    return answerCounted.call(this, method, params).finally(() => (daemon.open -= 1));
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
  return { prompts, started };
}

/// Picks `folder` on the page, types `text` and presses Return.
async function askIn(folder: string, text: string) {
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-project-button")!.click());
  const option = dom.window.document.querySelector<HTMLElement>(
    `.acpmux-project-menu [role="option"][aria-label$="${folder}"]`,
  );
  expect(option, "the picked folder's row").not.toBeNull();
  await act(async () => option!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  const field = host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, text);
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
}

type FieldElement = HTMLElement & { acpmuxMarkdownField?: { type(markdown: string): unknown; value(): string } };
/// The chat composer's prompt field, once its editor is up.
const promptField = () => {
  const element = host.querySelector<FieldElement>(".acpmux-composer-prompt");
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};
const composerText = () => promptField()?.value() ?? "";
const trustButton = () =>
  dom.window.document.querySelector<HTMLButtonElement>(".acpmux-trust-ask-primary") ?? undefined;
const trustRefusal = (folder: string): Refusal => ({
  message: "Trust this folder first",
  data: { reason: "trust.pending", cwd: folder },
});

test("classic Return with no agent named: a start refused for the folder's trust sends its prompt once Trust is answered, once", async () => {
  const folder = "/Users/sample/untrusted-project";
  let trusted = false;
  const { prompts, started } = await mountClassic(folder, async () => (trusted ? undefined : trustRefusal(folder)));
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const recorded = proto.answer;
  proto.answer = function (this: unknown, method, params) {
    if (method === "acp.trust.set" && params.cwd === folder) trusted = params.level === "trusted";
    return recorded.call(this, method, params);
  };
  await askIn(folder, "hello");

  // acpmux refused the start: the folder's question shows, and nothing went yet.
  await until(() => trustButton() !== undefined, "the trust question shows");
  expect(prompts).toEqual([]);
  // The prompt waits in the chat composer meanwhile, not lost with the refused start.
  await until(() => composerText() === "hello", "the composer holds the prompt");

  await act(async () => trustButton()!.click());
  await until(() => prompts.length > 0, "the prompt went after Trust");
  await quiet("the page settles after the send");
  expect(prompts).toEqual(["hello"]);
  // The refused start, then the one after Trust, both in the picked folder: the prompt went there.
  expect(started).toEqual([folder, folder]);
}, 60_000);

// The New Tab page stays up until its start settles (#27009: leaving it first flashed the empty chat
// hero), so nothing can be typed in the chat composer while the start is out: the page holds the
// prompt until then, and a refusal after a while gives it back as a quick one does.
test("a start refused after a while keeps the New Tab page until then, and gives the prompt back with the trust question", async () => {
  const folder = "/Users/sample/slow-untrusted-project";
  let answer: (() => void) | undefined;
  const { prompts, started } = await mountClassic(folder, async (attempt) => {
    if (attempt > 1) return undefined;
    await new Promise<void>((done) => (answer = done));
    return trustRefusal(folder);
  });
  await askIn(folder, "hello");
  // The start is still out: the New Tab page stays, and no chat composer stands in for it yet.
  await until(() => answer !== undefined, "the start went");
  await tick();
  expect(host.querySelector(".acpmux-newtab-field"), "the New Tab page while the start is out").not.toBeNull();
  expect(promptField(), "no chat composer while the start is out").toBeUndefined();
  expect(prompts).toEqual([]);

  await act(async () => answer!());
  await until(() => trustButton() !== undefined, "the trust question shows");
  // Nothing is lost: the refused prompt is back in the chat composer, and nothing went yet.
  await until(() => composerText() === "hello", "the composer got the prompt back");
  expect(prompts).toEqual([]);

  await act(async () => trustButton()!.click());
  await until(() => prompts.length > 0, "the prompt went after Trust");
  await quiet("the page settles after the send");
  expect(prompts).toEqual(["hello"]);
  expect(started).toEqual([folder, folder]);
}, 60_000);

test("a start refused for another reason leaves the prompt in the composer, and sending it starts the chat in the folder", async () => {
  const folder = "/Users/sample/busy-project";
  const { prompts, started } = await mountClassic(
    folder,
    async (attempt) => (attempt === 1 ? { message: "acpmux could not start the agent" } : undefined),
    { trusted: true },
  );
  await askIn(folder, "hello");
  await until(() => started.length === 1, "the start went");
  await until(() => composerText() === "hello", "the composer holds the prompt");
  // No trust question for a refusal that is not about trust.
  await quiet("the page settles after the refusal");
  expect(trustButton()).toBeUndefined();
  expect(prompts).toEqual([]);

  // Send again from the composer: the chat starts in the folder picked on the page, and the prompt goes once.
  await act(async () =>
    host
      .querySelector("form.acpmux-composer")!
      .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
  await until(() => prompts.length > 0, "the prompt went");
  await quiet("the page settles after the send");
  expect(prompts).toEqual(["hello"]);
  expect(started).toEqual([folder, folder]);
}, 60_000);

test("App failed-row Retry cannot bypass a pending folder choice or duplicate the Trust retry", async () => {
  const folder = "/Users/sample/retry-pending-folder";
  const { prompts } = await mountClassic(folder, async () => undefined, { trusted: true });
  await askIn(folder, "Start this chat");
  await quiet("the initial turn ends");
  const actions = dom.window.cmuxAcpmuxActions!;
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const recorded = proto.answer;
  let trusted = false;
  let retries = 0;
  const payloads: unknown[] = [];
  proto.answer = function (this: unknown, method, params) {
    if (method === "acp.trust.get") return Promise.resolve({ cwd: folder, level: trusted ? "trusted" : "unknown" });
    if (method === "acp.trust.set") trusted = params.level === "trusted";
    if (method === "session/prompt") {
      retries++;
      payloads.push(params.prompt);
      if (!trusted)
        return Promise.reject(
          Object.assign(new Error("Trust this folder first"), { data: { reason: "trust.pending", cwd: folder } }),
        );
    }
    return recorded.call(this, method, params);
  };
  await act(async () => {
    await actions["chat.send"]!({ text: "Retry the attached plan", attachments: [] }).catch(() => undefined);
  });
  await until(() => trustButton() !== undefined, "trust refusal shows its question");
  await until(() => host.querySelector(".cv-user__status--failed") !== null, "refused prompt stays in its failed row");
  expect(retries).toBe(1);
  const native = (
    dom.window as unknown as {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: (message: { method: string; params?: Record<string, unknown> }) => Promise<unknown>;
          };
        };
      };
    }
  ).webkit.messageHandlers.agentSession;
  const post = native.postMessage;
  let finishFolder: (() => void) | undefined;
  native.postMessage = (message) => {
    if (message.method !== "workspace.useFolder") return post(message);
    if (!message.params?.confirm)
      return Promise.resolve({ ok: true, value: { status: "confirm", reason: "home", cwd: folder } });
    return new Promise((resolve) => {
      finishFolder = () => resolve({ ok: true, value: { status: "ok", cwd: folder } });
    });
  };
  // This check keeps the existing chat selected when the host accepts its current folder;
  // the App owns the real pending question, Trust button, failed-row Retry, and release effect.
  actions["chat.new"] = async () => undefined;
  await act(async () => {
    dom.window.cmuxAcpmuxDebug!.pickFolder(folder);
  });
  const useFolder = () =>
    [...host.querySelectorAll<HTMLButtonElement>("button")].find((button) =>
      button.textContent?.includes("Use Home Folder"),
    );
  await until(() => useFolder() !== undefined, "the actual folder question is pending");
  await act(async () => trustButton()!.click());
  await quiet("trust accepted while the folder question waits");
  expect(retries).toBe(1);
  const retry = [...host.querySelectorAll<HTMLButtonElement>(".cv-user__status--failed button")].find(
    (button) => button.textContent === "Retry",
  );
  expect(retry).toBeDefined();
  await act(async () => retry!.click());
  await quiet("actual App Retry settles behind the folder question");
  expect(retries).toBe(1);
  await act(async () => useFolder()!.click());
  await until(() => finishFolder !== undefined, "host received folder confirmation");
  await quiet("confirmation remains in flight");
  expect(retries).toBe(1);
  await act(async () => finishFolder!());
  await quiet("folder confirmation releases one retry and the turn settles");
  expect(retries).toBe(2);
  expect(payloads[1]).toEqual(payloads[0]);
  expect(prompts).toEqual(["Start this chat", "Retry the attached plan"]);
  expect(host.querySelector(".cv-user__status--failed")).toBeNull();
}, 60_000);
