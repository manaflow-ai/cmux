// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// Ordering map O23 and O24 (design/chat-animation-ordering-map.md), under jsdom with the real
// VirtualTranscript. Leo, 2026-11-21: "some animations i think are still a bit... off. like, you finish
// some sort of tool call, things happen, things fold, stuff comes in at different times".
// - O23 a compaction row arriving while the stream runs enters as any line row does (`--enter`, never
//   the message presentation), once;
// - O24 a notice row after the live line (the line is no longer the last row, then is again) never
//   makes the line enter again: the same node, the same classes, no remount.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";
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
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, kind, text, version: 1, at: Date.now(), ...extra }) as AcpmuxRow;

const Row = ({ row: item }: { row: AcpmuxRow }) => <div>{item.text}</div>;
const registry = { user: Row, assistant: Row, thinking: Row, compaction: Row } as never;

function mount(sessionId: string) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const render = (rows: AcpmuxRow[]) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId={sessionId}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const node = (id: string) => host.querySelector<HTMLElement>(`[data-row-id="${id}"]`);
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { render, node, unmount };
}

const history = () => [row("prompt-1", "user", "Earlier prompt"), row("reply-1", "assistant", "Earlier reply")];

test("O23: a compaction row arriving mid-stream enters as a line row, once", async () => {
  const view = mount("order-o23");
  try {
    await view.render(history());
    const compaction = row("compaction-1", "compaction", "Compacted conversation");
    await view.render([...history(), compaction]);
    const node = view.node("compaction-1")!;
    expect(node).toBeTruthy();
    expect(node.classList.contains("acpmux-row--enter")).toBe(true);
    expect(node.classList.contains("acpmux-row--message-enter")).toBe(false);
    // A later version of the row (its tokens settle) is the same node and never enters again.
    await view.render([...history(), { ...compaction, version: 2, text: "Compacted conversation, 12k tokens" }]);
    expect(view.node("compaction-1")).toBe(node);
    expect(node.classList.contains("acpmux-row--enter")).toBe(true);
  } finally {
    await view.unmount();
  }
});

test("O24: a notice after the live line, and the line last again, never remounts or re-enters the line", async () => {
  const view = mount("order-o24");
  try {
    await view.render(history());
    const live = row(LIVE_THINKING, "thinking", "Thinking", { below: true });
    await view.render([...history(), live]);
    const line = view.node(LIVE_THINKING)!;
    expect(line).toBeTruthy();
    const motion = () => [...line.classList].filter((name) => /enter|older|fade/.test(name)).join(" ");
    const classes = motion();
    const notice = row("notice-1", "user", "Background task finished", {
      incoming: { kind: "notice" as const, text: "Background task finished" },
    });
    // The notice lands after the line: the line is no longer the chat's last row.
    await view.render([...history(), live, notice]);
    expect(view.node(LIVE_THINKING)).toBe(line);
    expect(motion()).toBe(classes);
    expect(view.node("notice-1")?.classList.contains("acpmux-row--enter")).toBe(true);
    // The line is last again (the view puts it back under the notice).
    await view.render([...history(), notice, { ...live, version: 2 }]);
    expect(view.node(LIVE_THINKING)).toBe(line);
    expect(motion()).toBe(classes);
  } finally {
    await view.unmount();
  }
});
