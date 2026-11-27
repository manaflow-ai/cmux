// l10n-allow-file: test fixture replies, not shipped UI.
// cmux#60478 (a brief forwarded as Leo's, unverified): the local agent connection reconnects on its
// own. The pane loses its client, the next ask is refused "The agent service stopped.", and the
// pane asks again by itself (the starting ask, `startOnAsk`) until it connects. At no point does it
// draw the host error line, its alert, or a Retry; the composer stays.
//
// Two hosts: one marks the refusal `details.reconnecting` (cmux#60429 makes a stopped daemon
// transient), and an older one that sends no details.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Event: dom.window.Event,
  KeyboardEvent: dom.window.KeyboardEvent,
  MouseEvent: dom.window.MouseEvent,
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
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
(dom.window as unknown as { matchMedia: unknown }).matchMedia = replacements.matchMedia;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");

afterAll(async () => {
  // The pane marked the page as the mock daemon's (App.tsx): later files see a plain page again.
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  await teardownDom(saved, { window: dom.window, scope });
});

const window_ = dom.window as unknown as { webkit: unknown; cmuxAcpmuxActions?: Record<string, unknown> };
const document_ = dom.window.document;

/// What the person would see go wrong: the host error line (its alert), a Retry, the stopped words.
function wrong(): string | undefined {
  if (document_.querySelector(".acpmux-host-line-group")) return "host error line";
  if (document_.querySelector('[role="alert"]')) return "alert";
  for (const button of document_.querySelectorAll("button"))
    if (/^\s*retry\s*$/i.test(button.textContent ?? "") || /retry/i.test(button.getAttribute("aria-label") ?? ""))
      return "Retry button";
  if (/agent service stopped/i.test(document_.body.textContent ?? "")) return "stopped words";
  return undefined;
}

for (const host of [
  // cmux#60429's host starts the stopped daemon on a reconnect ask, so the pane asks the same again.
  { name: "a host that marks the stop reconnecting", details: { reconnecting: true }, next: { reconnect: true } },
  // An older host only looks on a reconnect: after its definite refusal the pane's next ask starts it.
  { name: "an older host that sends no details", details: undefined, next: {} },
])
  test(`stopped -> automatic retry -> connected, no error line and no Retry (${host.name})`, async () => {
    const asks: Record<string, unknown>[] = [];
    // After the drop: the reconnect ask is refused as a stopped service; the next ask (the one
    // that starts it) connects.
    let refuseNext = false;
    window_.webkit = {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method?: string; params?: Record<string, unknown> }) => {
            if (message.method === "ready") {
              asks.push({ ...message.params });
              if (refuseNext) {
                refuseNext = false;
                return Promise.resolve({
                  ok: false,
                  error: {
                    code: "host_unavailable",
                    message: "The agent service stopped.",
                    ...(host.details ? { details: host.details } : {}),
                  },
                });
              }
              return Promise.resolve({
                ok: true,
                value: { protocolVersion: 1, transport: "mock", machineName: "Mac", newSession: true },
              });
            }
            return Promise.resolve({ ok: true, value: null });
          },
        },
      },
    };
    const seen = new Set<string>();
    const watch = new dom.window.MutationObserver(() => {
      const what = wrong();
      if (what) seen.add(what);
    });
    watch.observe(document_.body, { subtree: true, childList: true, characterData: true, attributes: true });
    const root = createRoot(document_.getElementById("root")!);
    const turn = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    // Bounded by turns, with a wall cap for the pane's own 250 ms retry timers.
    const until = async (done: () => boolean, what: string) => {
      const deadline = Date.now() + 20_000;
      while (!done()) {
        if (Date.now() > deadline) throw new Error(`never: ${what}`);
        // fixed-wait: a poll tick, bounded by the condition; the pane's retry runs on real 250 ms timers.
        await act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
      }
    };
    try {
      await act(async () => root.render(<AcpmuxApp />));
      await until(() => Boolean(MockAcpmuxSocket.live && window_.cmuxAcpmuxActions?.["chat.send"]), "first connect");
      const first = MockAcpmuxSocket.live!;
      expect(asks.length).toBe(1);
      // The daemon stops: the socket closes under the pane.
      refuseNext = true;
      await act(async () => {
        first.close();
        first.onclose?.();
      });
      await until(
        () => MockAcpmuxSocket.live !== first && Boolean(window_.cmuxAcpmuxActions?.["chat.send"]),
        "reconnect",
      );
      for (let pass = 0; pass < 10; pass += 1) await turn();
      // Asked again with no one pressing anything: the reconnect, refused; then the ask that starts it.
      expect(asks.length).toBe(3);
      expect(asks[1]).toEqual({ reconnect: true });
      expect(asks[2]).toEqual(host.next);
      expect([...seen]).toEqual([]);
      expect(wrong()).toBeUndefined();
      // The composer stayed.
      expect(document_.querySelector("textarea, [contenteditable='true']")).not.toBeNull();
    } finally {
      watch.disconnect();
      await act(async () => root.unmount());
      document_.getElementById("root")!.replaceChildren();
    }
    // Above the 20 s wall cap of `until`: on a loaded machine the first render alone passes bun's 5 s default.
  }, 30_000);
