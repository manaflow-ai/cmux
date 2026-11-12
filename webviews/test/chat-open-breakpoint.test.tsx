// l10n-allow-file: test fixture messages, not shipped UI.
// Opening a chat puts a breakpoint at that tick: what the chat held before it loads steady and
// never plays an animation, and what this page already drew never plays one again (Leo,
// 2026-11-12, ask-6194619454: "You put a breakpoint right at the moment that tick when you click
// into it, and then afterwards, that subsequent bit, then you can start playing animations ... you
// don't bother trying to replay the animations").
//
// Before: a reconnect's replay redrew the rows on screen under new frames and they took the live
// entrance; a cold open that cleared and refilled faded the whole transcript in a second time; and
// the read behind a cold open's first slice entered row by row as if it were live.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  Range: dom.window.Range,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
/// Every Web Animation the transcript starts (the cold open's fade is one).
const fades: Element[] = [];
(dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function (this: Element) {
  fades.push(this);
  return { cancel() {}, finish() {}, onfinish: null, playState: "running" };
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { defaultRegistry } = await import("../src/agent-session/acpmux/rows/registry");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

/// An hour before the test opens any chat: history.
const past = Date.now() - 3_600_000;
const row = (id: string, kind: string, text: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: past,
  kind,
  text,
  ...fields,
});
const ANIMATED = ".acpmux-row--enter, .acpmux-row--message-enter, .cmux-load-fade";
const animatedIds = (host: HTMLElement) =>
  [...host.querySelectorAll<HTMLElement>(ANIMATED)].map((node) =>
    node.closest("[data-row-id]")?.getAttribute("data-row-id"),
  );

function mount(session: string) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const render = (rows: AcpmuxRow[], props: { coldOpen?: number; loading?: boolean } = {}) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={defaultRegistry}
          sessionId={session}
          onToggleActivity={() => {}}
          expanded={new Set()}
          {...props}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { host, render, unmount };
}

test("a reconnect's replay redraws the rows on screen in place: no row plays its entrance again", async () => {
  const { host, render, unmount } = mount("breakpoint-replay");
  try {
    const prompt = row("prompt", "user", "Look around");
    const reply = row("reply", "assistant", "Done looking around.");
    await render([prompt, reply].map((item) => ({ ...item, frame: `${item.id}@1` })));
    expect(animatedIds(host)).toEqual([]);
    // The connection drops and the replay brings the same rows under new frames.
    await render([prompt, reply].map((item) => ({ ...item, version: 2, frame: `${item.id}@2` })));
    expect(animatedIds(host)).toEqual([]);
    // A row that comes in live after the open still enters.
    await render([prompt, reply, row("next", "user", "And now?", { at: Date.now() })]);
    expect(animatedIds(host)).toEqual(["next"]);
  } finally {
    await unmount();
  }
});

test("a cold open that clears and refills fades in once, and the read behind its first slice draws in place", async () => {
  fades.length = 0;
  const { host, render, unmount } = mount("breakpoint-cold");
  try {
    const slice = [row("p1", "user", "First"), row("r1", "assistant", "First reply")];
    await render(slice, { coldOpen: 1 });
    expect(fades.length).toBe(1);
    // The read behind the first slice lands while the open is cold: history, so nothing enters.
    const read = [...slice, row("p2", "user", "Second"), row("r2", "assistant", "Second reply")];
    await render(read, { coldOpen: 1 });
    expect(animatedIds(host)).toEqual([]);
    // The pane clears and refills the chat as a new cold open: it shows at once, no second fade.
    await render([], { coldOpen: 2 });
    await render(read, { coldOpen: 2 });
    expect(fades.length).toBe(1);
    expect(animatedIds(host)).toEqual([]);
  } finally {
    await unmount();
  }
});

test("a transcript mounted again over a chat this page drew shows it at once", async () => {
  const rows = [row("p1", "user", "First"), row("r1", "assistant", "First reply")];
  const first = mount("breakpoint-remount");
  await first.render(rows);
  await first.unmount();
  fades.length = 0;
  const again = mount("breakpoint-remount");
  try {
    await again.render(rows, { coldOpen: 3 });
    expect(fades.length).toBe(0);
    expect(animatedIds(again.host)).toEqual([]);
  } finally {
    await again.unmount();
  }
});
