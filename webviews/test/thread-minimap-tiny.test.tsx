// cmux-web-test-timeout: 600
// The rail rendered in tiny panes (see thread-minimap-room.test.ts for the whole sweep): pane heights
// from the transcript's 96 px minimum, prompt counts from the rail's 4 up to 70, and offsets down the
// whole chat. Every lit tick draws whole inside the rail's list and clear of the list's own edge fades
// (they give way to the band in a short rail), and, where the pane has room, clear of the transcript's
// faded edges.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };
setDefaultTimeout(120_000);

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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
  // The panes are short, the window is not (the app's transcript sits under a title bar and over a
  // composer): the rail's 70%-of-the-window cap is taller than any pane here, as in the app.
  innerHeight: 900,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => viewport });
// Wide enough for the minimap's pane-edge rail in these layout tests.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
const offsets = new WeakMap<object, number>();
/// The rail's list clamps its offset as a browser does: rows are 10 px, a spacer for rows it does not
/// draw as tall as its style says (tickWindow.ts), the list as tall as the rail.
const listRoom = (node: HTMLElement) =>
  Math.max(
    0,
    [...node.children].reduce(
      (sum, child) =>
        sum + (child.querySelector("[data-tick]") ? 10 : Number.parseFloat((child as HTMLElement).style.height) || 0),
      0,
    ) - Number.parseFloat(node.parentElement?.style.height ?? "0"),
  );
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: HTMLElement, value: number) {
    offsets.set(
      this,
      this.classList.contains("acpmux-minimap__list") ? Math.max(0, Math.min(listRoom(this), value)) : value,
    );
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

/// The 2.5rem fade the list draws at an edge, unless the rail sets a shorter one.
const LIST_FADE = 40;

for (let height = 96; height <= 336; height += 16)
  test(`a ${height} px pane: every lit tick draws whole in the rail, at every offset`, async () => {
    const document = dom.window.document;
    viewport = height;
    const clipped: string[] = [];
    for (const count of [4, 5, 6, 8, 12, 20, 40, 70]) {
      const host = document.createElement("div");
      document.body.append(host);
      const root = createRoot(host);
      try {
        await act(async () =>
          root.render(
            <VirtualTranscript
              rows={turnView(chat(count), new Set())}
              sessionId={`tiny-${height}-${count}`}
              onToggleActivity={() => {}}
              expanded={new Set()}
            />,
          ),
        );
        const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
        const end = scroller.scrollTop;
        const stride = Math.max(7, Math.ceil(end / 120));
        const offsets = [
          ...Array.from({ length: Math.floor(end / stride) + 1 }, (_, step) => step * stride),
          end - 1,
          end,
        ];
        for (const at of offsets.filter((at) => at >= 0)) {
          scroller.scrollTop = at;
          await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
          const rail = host.querySelector<HTMLElement>(".acpmux-minimap__rail");
          if (!rail) {
            clipped.push(`${count} prompts at ${at} px: no rail`);
            break;
          }
          const list = host.querySelector<HTMLElement>(".acpmux-minimap__list")!;
          const railHeight = Number.parseFloat(rail.style.height);
          const railTop = Number.parseFloat(rail.style.top);
          const fade = Number.parseFloat(list.style.getPropertyValue("--acpmux-minimap-fade")) || LIST_FADE;
          const lit = [...list.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')].map((tick) =>
            Number(tick.dataset.tick),
          );
          // Prompts whose rows could not all be on screen together are not a band the rail can owe.
          if (lit.length * 10 > viewport) continue;
          const from = list.hasAttribute("data-fade-top") ? fade : 0;
          const to = railHeight - (list.hasAttribute("data-fade-bottom") ? fade : 0);
          // The transcript's faded edges, where the pane has room for the rail clear of them.
          const roomy = railHeight <= viewport - 18 - 18 - 8;
          const maskFrom = scroller.hasAttribute("data-fade-top") ? 18 : 0;
          const maskTo = viewport - (scroller.hasAttribute("data-fade-bottom") ? 18 : 0);
          for (const index of lit) {
            const y = index * 10 - list.scrollTop;
            if (y < from || y + 10 > to)
              clipped.push(
                `${count} prompts at ${at} px: tick ${index} at ${y}..${y + 10} of ${from}..${to} in ${railHeight} px`,
              );
            else if (roomy && (railTop + y < maskFrom || railTop + y + 10 > maskTo))
              clipped.push(
                `${count} prompts at ${at} px: tick ${index} at ${railTop + y} px, under the transcript's fade`,
              );
          }
          if (clipped.length > 10) break;
        }
      } finally {
        await act(async () => root.unmount());
        host.remove();
      }
      if (clipped.length > 10) break;
    }
    viewport = 600;
    expect(clipped).toEqual([]);
  });
