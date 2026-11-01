// New Tab keeps its live DOM and local choices when the real direct client receives session/new refusal.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
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
    cmuxAcpmuxMockHarnesses: undefined,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia, cmuxAcpmuxMockHarnesses: undefined });
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

async function promptField() {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await tick();
  return field;
}

async function writePrompt(text: string) {
  const field = await promptField();
  const handle = field.acpmuxMarkdownField!;
  await act(async () => handle.writeText(text, text.length, text.length));
  return { field, editor: field.querySelector<HTMLElement>("[contenteditable]")! };
}

const promptValue = () => host.querySelector<MarkdownFieldElement>(".nt-field")?.acpmuxMarkdownField?.plainText() ?? "";
/// Waits for `check` to hold, a turn at a time; fails with `what` if it never does.
async function until(check: () => boolean, what: string, within = 10_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

const machineButton = () =>
  host.querySelector<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button');
/// Picks the SSH machine devbox. The machine chip's main list is This Mac and Cloud; every machine is
/// in Machines… on its right-click menu (#28999).
async function pickDevbox() {
  await until(() => machineButton() !== null, "the machine chip");
  await act(async () =>
    machineButton()!.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  const machinesItem = () =>
    [...dom.window.document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].find(
      (candidate) => candidate.textContent === t("composer.machinesList"),
    );
  await until(() => !!machinesItem(), "Machines… on the machine chip's right-click menu");
  await act(async () => machinesItem()!.click());
  await until(
    () => [...dom.window.document.querySelectorAll(".acpmux-menu-label")].some((node) => node.textContent === "devbox"),
    "devbox pick",
  );
  const remote = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-menu-item")].find(
    (node) => node.querySelector(".acpmux-menu-label")?.textContent === "devbox",
  )!;
  await act(async () => remote.click());
}

for (const [remoteStart, trust, reconnectStart, decline, promptTrust] of [
  [true, false, false],
  [false, false, false],
  [true, true, false],
  [false, true, false],
  [false, false, true, false],
  [true, true, false, true],
  [true, true, false, false, true],
])
  test(`a refused ${remoteStart ? "SSH" : "local"} session/new keeps the mounted New Tab draft and machine${promptTrust ? " with first-prompt Trust" : decline ? " after Not now" : trust ? " with Trust" : reconnectStart ? " across reconnect" : ""}`, async () => {
    const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
    type Answer = (method: string, params: Record<string, any>) => Promise<any>;
    const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
    const answer = proto.answer;
    restoreAnswer = () => (proto.answer = answer);
    const starts: Record<string, any>[] = [];
    const prompts: Record<string, any>[] = [];
    let trusted = false;
    proto.answer = async function (method, params) {
      if (method === "acp.trust.set") trusted = params.level === "trusted";
      if (method === "session/prompt") {
        // A daemon reply is a later event, after the session selection frame committed.
        if (promptTrust) await new Promise((done) => setTimeout(done, 0));
        if (promptTrust && !trusted)
          throw Object.assign(new Error("Trust the prompt folder"), {
            data: { reason: "trust.pending", cwd: "/tmp/start-recovery-prompt-trust" },
          });
        prompts.push(params);
        return { stopReason: "end_turn" };
      }
      if (method === "session/new") {
        starts.push(params);
        if (reconnectStart && starts.length === 1) return new Promise(() => {});
        if (reconnectStart || promptTrust || (trust && trusted))
          return answer.call(
            this,
            method,
            promptTrust ? { ...params, cwd: "/tmp/start-recovery-prompt-trust" } : params,
          );
        throw Object.assign(
          new Error("devbox refused session/new: agent unavailable"),
          trust
            ? {
                data: { reason: "trust.pending", cwd: "/tmp/start-recovery-trust" },
              }
            : {},
        );
      }
      const result = await answer.call(this, method, params);
      return method === "_acpmux/status"
        ? { ...result, peers: [{ name: "devbox", kind: "ssh", connected: true }] }
        : result;
    };
    const { createRoot } = await import("react-dom/client");
    const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
    Object.assign(dom.window, {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
              return Promise.resolve({
                ok: true,
                value:
                  message.method === "ready"
                    ? {
                        protocolVersion: 1,
                        transport: "mock",
                        newSession: true,
                        machineName: "Mac",
                        newTab: { template: "minimal", layout: "b", lastAgent: "claude", cwd: "/tmp/demo-project" },
                      }
                    : undefined,
              });
            },
          },
        },
      },
    });
    root = createRoot(host);
    await act(async () => root!.render(<AcpmuxApp />));
    await until(() => host.querySelector(".nt-field") !== null, "the New Tab field");
    await until(() => !!(dom.window as any).cmuxAcpmuxActions?.["chat.new"], "mock handshake");
    if (trust && !remoteStart) {
      // Force the direct no-project route; a named local harness has its own Trust queue.
      const actions = (dom.window as any).cmuxAcpmuxActions;
      const start = actions["chat.new"];
      actions["chat.new"] = (params: Record<string, unknown>) => start({ ...params, harness: "", noProject: true });
    }
    if (reconnectStart) {
      // Name the harness at the in-page start boundary: this case exercises the switch's
      // reconnect contract, independently of the native model-catalog fixture.
      const actions = (dom.window as any).cmuxAcpmuxActions;
      const start = actions["chat.new"];
      actions["chat.new"] = (params: Record<string, unknown>) => start({ ...params, harness: "claude" });
    }
    if (remoteStart) await pickDevbox();
    const { field, editor } = await writePrompt("inspect the failed build");
    await act(async () =>
      editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    await until(() => starts.length === 1, "session/new refused");
    if (reconnectStart) {
      expect(starts[0]._meta.acpmux.harness).toBe("claude");
      await act(async () => {
        const socket = MockAcpmuxSocket.live!;
        socket.close();
        socket.onclose?.();
      });
      await until(() => prompts.length === 1, "the switch resumes its queued prompt");
      await until(() => !host.querySelector(".nt-field"), "the resumed start leaves New Tab");
      await tick();
      expect(prompts).toHaveLength(1);
      expect(prompts[0].prompt[0].text).toBe("inspect the failed build");
      return;
    }
    await until(
      () =>
        trust
          ? !!host.querySelector(".acpmux-trust-ask-primary")
          : [...host.querySelectorAll('[role="alert"]')].some((node) =>
              node.textContent?.includes("agent unavailable"),
            ),
      "inline refusal",
    );
    expect(starts[0]._meta.acpmux.peer).toBe(remoteStart ? "devbox" : undefined);
    if (!remoteStart) {
      // A local start becomes its chat at once, with the prompt queued in it (Leo 2026-10-30: "I
      // SHOULD BE ALWAYS ABLE TO SATRT NEW FUCKGN CHATS"): the refusal shows in the chat, and the
      // prompt is never lost, back in the chat's composer.
      await until(() => !host.querySelector(".nt-field"), "the local start becomes its chat");
      if (!trust) {
        // The refusal says why in the chat, and the prompt is still on the page (its failed row or the
        // chat's composer): nothing typed is lost.
        await until(() => !!host.textContent?.includes("agent unavailable"), "the chat says why it did not start");
        const kept = () =>
          host.textContent?.includes("inspect the failed build") ||
          [...host.querySelectorAll<HTMLElement>("[contenteditable='true']")].some((node) =>
            node.textContent?.includes("inspect the failed build"),
          );
        await until(() => !!kept(), "the refused prompt is kept");
        expect(prompts).toHaveLength(0);
        return;
      }
      await until(() => !!host.querySelector(".acpmux-trust-ask-primary"), "Trust in the chat");
      await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-trust-ask-primary")!.click());
      await until(() => prompts.length === 1, "Trust sends the prompt exactly once");
      await tick();
      expect(prompts).toHaveLength(1);
      expect(prompts[0].prompt[0].text).toBe("inspect the failed build");
      return;
    }
    expect(host.querySelector(".nt-field")).toBe(field);
    expect(promptValue()).toBe("inspect the failed build");
    expect(machineButton()?.textContent).toContain("devbox");
    if (trust) {
      await until(() => !!host.querySelector(".acpmux-trust-ask-primary"), "Trust control on the retained New Tab");
      expect(host.querySelector(".nt-field")).toBe(field);
      if (decline) {
        const notNow = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask button")].find(
          (button) => button.textContent === t("trust.notNow"),
        )!;
        await act(async () => notNow.click());
        await until(() => !!host.querySelector('[role="alert"]'), "declined start settles with the draft retained");
        expect(host.querySelector(".nt-field")).toBe(field);
        expect(prompts).toHaveLength(0);
        const undo = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask-action")].find(
          (button) => button.textContent === t("trust.undo"),
        )!;
        await act(async () => undo.click());
        await until(() => !!host.querySelector(".acpmux-trust-ask-primary"), "Undo offers Trust again");
      }
      await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-trust-ask-primary")!.click());
      if (decline) {
        expect(prompts).toHaveLength(0);
        await act(async () =>
          editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
        );
      }
      await until(() => prompts.length === 1, "Trust resumes the retained request exactly once");
      await until(() => !host.querySelector(".nt-field"), "the trusted start leaves New Tab");
      await tick();
      expect(starts).toHaveLength(promptTrust ? 1 : 2);
      expect(starts.at(-1)!._meta.acpmux.peer).toBe(remoteStart ? "devbox" : undefined);
      expect(prompts).toHaveLength(1);
      expect(prompts[0].prompt[0].text).toBe("inspect the failed build");
      return;
    }
    await act(async () =>
      editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    await until(() => starts.length === 2, "retry on the same machine");
    expect(starts[1]._meta.acpmux.peer).toBe(remoteStart ? "devbox" : undefined);
    expect(promptValue()).toBe("inspect the failed build");
  }, 15_000);

// Return twice while a chat start has not answered: the page's one-ask guard (NewTabScreen
// `requestChat`) holds the second, so one chat starts and the prompt goes once. Through the real App
// and its actions (#29011: the test before stood in for them with its own queue). An SSH start keeps
// the page until it starts; a local one becomes its chat on the first Return.
test("Return twice while a start has not answered asks once", async () => {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  type Answer = (method: string, params: Record<string, any>) => Promise<any>;
  const proto = MockAcpmuxSocket.prototype as unknown as { answer: Answer };
  const answer = proto.answer;
  restoreAnswer = () => (proto.answer = answer);
  const starts: Record<string, any>[] = [];
  const prompts: Record<string, any>[] = [];
  let release: () => void = () => {};
  const released = new Promise<void>((done) => (release = done));
  proto.answer = async function (method, params) {
    if (method === "session/prompt") prompts.push(params);
    if (method === "session/new") {
      starts.push(params);
      await released;
    }
    const result = await answer.call(this, method, params);
    return method === "_acpmux/status"
      ? { ...result, peers: [{ name: "devbox", kind: "ssh", connected: true }] }
      : result;
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
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "Mac",
                      newTab: { template: "minimal", layout: "b", lastAgent: "claude", cwd: "/tmp/demo-project" },
                    }
                  : undefined,
            }),
        },
      },
    },
  });
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => !!(dom.window as any).cmuxAcpmuxActions?.["chat.new"], "mock handshake");
  await pickDevbox();
  const { editor } = await writePrompt("fix the flaky upload test");
  for (let press = 0; press < 2; press++) {
    await act(async () =>
      editor.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
    );
    await until(() => starts.length >= 1, "the start is asked");
  }
  for (let turn = 0; turn < 10; turn++) await tick();
  expect(starts).toHaveLength(1);
  await act(async () => release());
  await until(() => prompts.length >= 1, "the prompt goes once the chat started");
  for (let turn = 0; turn < 10; turn++) await tick();
  expect(starts).toHaveLength(1);
  expect(prompts).toHaveLength(1);
  expect(prompts[0].prompt[0].text).toBe("fix the flaky upload test");
}, 15_000);
