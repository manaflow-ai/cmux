// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// Sending a prompt moves the transcript to the latest row. Existing rows must keep their React
// identity while that move happens: remounting them makes their bubbles flicker.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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

const { act, useEffect } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: AcpmuxRow["kind"], text: string): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at: 1,
});

test("sending keeps existing transcript rows mounted and does not redraw them", async () => {
  const mounts = new Map<string, number>();
  const unmounts = new Map<string, number>();
  const renders = new Map<string, number>();
  const TrackingRow = ({ row: item }: { row: AcpmuxRow }) => {
    renders.set(item.id, (renders.get(item.id) ?? 0) + 1);
    useEffect(() => {
      mounts.set(item.id, (mounts.get(item.id) ?? 0) + 1);
      return () => {
        unmounts.set(item.id, (unmounts.get(item.id) ?? 0) + 1);
      };
    }, [item.id]);
    return <div data-testid={`tracking-${item.id}`}>{item.text}</div>;
  };
  const registry = { user: TrackingRow, assistant: TrackingRow } as never;
  const root = createRoot(dom.window.document.getElementById("root")!);
  const onToggleActivity = () => {};
  const existing = [row("prompt-1", "user", "Earlier prompt"), row("reply-1", "assistant", "Earlier reply")];
  const render = (rows: AcpmuxRow[], sends: number) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId="session-1"
          sends={sends}
          canLoadOlder
          onToggleActivity={onToggleActivity}
          expanded={new Set()}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  try {
    await render(existing, 0);
    await render(
      existing.map((item) => ({ ...item })),
      0,
    );
    const before = new Map(renders);
    const afterSend = [...existing.map((item) => ({ ...item })), row("prompt-2", "user", "New prompt")];
    await render(afterSend, 1);
    expect([...mounts.entries()]).toEqual([
      ["prompt-1", 1],
      ["reply-1", 1],
      ["prompt-2", 1],
    ]);
    expect([...unmounts.entries()].filter(([, count]) => count > 0)).toEqual([]);
    expect(renders.get("prompt-1")).toBe(before.get("prompt-1"));
    expect(renders.get("reply-1")).toBe(before.get("reply-1"));
  } finally {
    await act(async () => root.unmount());
  }
});
