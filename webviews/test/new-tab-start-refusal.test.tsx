// New Tab keeps its live DOM and local choices when the real direct client receives session/new refusal.
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
/// Waits for `check` to hold, a turn at a time; fails with `what` if it never does.
async function until(check: () => boolean, what: string, within = 10_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
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
    const machine = () => host.querySelector<HTMLButtonElement>('.acpmux-location-picker[data-kind="computer"] button');
    const pickRemote = async () => {
      await act(async () => machine()!.click());
      await until(
        () =>
          [...dom.window.document.querySelectorAll(".acpmux-menu-label")].some((node) => node.textContent === "devbox"),
        "devbox pick",
      );
      const remote = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-menu-item")].find(
        (node) => node.querySelector(".acpmux-menu-label")?.textContent === "devbox",
      )!;
      await act(async () => remote.click());
    };
    if (remoteStart) await pickRemote();
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    await act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!.call(
        field,
        "inspect the failed build",
      );
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    await act(async () =>
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
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
    expect(host.querySelector(".nt-field")).toBe(field);
    expect(field.value).toBe("inspect the failed build");
    if (remoteStart) expect(machine()?.textContent).toContain("devbox");
    expect(starts[0]._meta.acpmux.peer).toBe(remoteStart ? "devbox" : undefined);
    if (trust) {
      await until(() => !!host.querySelector(".acpmux-trust-ask-primary"), "Trust control on the retained New Tab");
      expect(host.querySelector(".nt-field")).toBe(field);
      if (decline) {
        const notNow = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-trust-ask button")].find(
          (button) => button.textContent === "Not now",
        )!;
        await act(async () => notNow.click());
        await until(() => !!host.querySelector('[role="alert"]'), "declined start settles with the draft retained");
        expect(host.querySelector(".nt-field")).toBe(field);
        expect(prompts).toHaveLength(0);
        await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-trust-ask-action")!.click());
        await until(() => !!host.querySelector(".acpmux-trust-ask-primary"), "Undo offers Trust again");
      }
      await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-trust-ask-primary")!.click());
      if (decline) {
        expect(prompts).toHaveLength(0);
        await act(async () =>
          field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
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
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    await until(() => starts.length === 2, "retry on the same machine");
    expect(starts[1]._meta.acpmux.peer).toBe(remoteStart ? "devbox" : undefined);
    expect(field.value).toBe("inspect the failed build");
  }, 15_000);
