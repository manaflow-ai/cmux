// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat shown again in the same page places its rows at the heights it laid them out at, and
// measures none of the rows that did not change while it was away (conversation/keptLayouts.ts; Leo,
// 2026-11-18: "faster truly settled agent transcripts showing up whether from loading in app or
// switching between workspaces ... Fundamentally").
//
// Before: a switch away dropped the chat's estimates (kept by row object, and a return builds new row
// objects from its kept tail) and its drawn heights, so the return measured every row again (A's 200
// rows measured twice) and the mounted rows then moved as they drew (cmuxterm-hq#13406).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { MeasurableRenderer, NativeRegistry, RowProps } from "../src/agent-session/acpmux/rows/rowProps";
import { KeptLayouts, keptHeightFor } from "../src/agent-session/acpmux/conversation/keptLayouts";
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 800 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { defaultRegistry } = await import("../src/agent-session/acpmux/rows/registry");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

/// The chat's rows, made new each call as a return's kept tail makes them: same ids, versions and text.
const chat = (name: string, count: number): AcpmuxRow[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `${name}-${index}`,
    version: 1,
    at: (index + 1) * 1000,
    kind: index % 2 ? "assistant" : "user",
    text: `${name} message ${index}: ${"words ".repeat(index % 7)}`,
  }));

test("a chat shown again measures only its rows that changed while it was away", async () => {
  const measured = new Map<string, number>();
  /// The kind's own renderer, measuring through a counter (40 px a row).
  const counting = (kind: string): MeasurableRenderer => {
    const Renderer = defaultRegistry[kind]!;
    const Counted: MeasurableRenderer = (props: RowProps) => <Renderer {...props} />;
    Counted.measure = (row: AcpmuxRow) => {
      measured.set(row.id, (measured.get(row.id) ?? 0) + 1);
      return 40;
    };
    return Counted;
  };
  const registry: NativeRegistry = { ...defaultRegistry, user: counting("user"), assistant: counting("assistant") };
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const expanded = new Set<string>();
  const render = (sessionId: string, rows: AcpmuxRow[]) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId={sessionId}
          onToggleActivity={() => {}}
          expanded={expanded}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const measuredOf = (name: string) => [...measured].filter(([id]) => id.startsWith(`${name}-`)).length;
  try {
    await render("chat-a", chat("a", 200));
    expect(measuredOf("a")).toBe(200);
    await render("chat-b", chat("b", 50));
    expect(measuredOf("b")).toBe(50);
    measured.clear();
    // Back to A, its rows built again; its newest reply grew while it was away.
    const back = chat("a", 200);
    back[199] = { ...back[199]!, version: 2, text: `${back[199]!.text} and more` };
    await render("chat-a", back);
    expect([...measured.keys()]).toEqual(["a-199"]);
    // B again, as it was: nothing of it is measured.
    measured.clear();
    await render("chat-b", chat("b", 50));
    expect(measured.size).toBe(0);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

test("a chat shown again as it was asks no sync render in its own commit", async () => {
  // Before: a nested render in each return. The switch's placement pass put the chat's opening offset
  // in state where its commit had drawn the rows already, asked follow, the scrollbar range, the sent
  // prompts and the way back again at the values they had, and retained the drawn heights against the
  // new rows with none gone: each a sync render of the whole transcript before the first paint that
  // changed nothing, inside the switch's long task
  // (settled page, Leo 2026-11-21: "workspace switch, opening a recent workspace, chat switch and
  // restart reach a settled page (zero layout shift after first paint, streaming included) within 2x
  // of a derived bound").
  const { Profiler } = await import("react");
  // jsdom keeps no scroll offset; a browser keeps the one the open writes.
  const offsets = new WeakMap<object, number>();
  const proto = dom.window.HTMLElement.prototype;
  const own = Object.getOwnPropertyDescriptor(dom.window.Element.prototype, "scrollTop");
  Object.defineProperty(proto, "scrollTop", {
    configurable: true,
    get(this: object) {
      return offsets.get(this) ?? 0;
    },
    set(this: object, value: number) {
      offsets.set(this, value);
    },
  });
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const expanded = new Set<string>();
  /// Renders asked from the commit's own layout pass (React's "nested-update" phase).
  let nested = 0;
  const render = (sessionId: string, rows: AcpmuxRow[]) =>
    act(async () => {
      root.render(
        <Profiler
          id="transcript"
          onRender={(_id, phase) => {
            if (phase === "nested-update") nested += 1;
          }}
        >
          <VirtualTranscript
            rows={rows}
            registry={defaultRegistry}
            sessionId={sessionId}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </Profiler>,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  try {
    await render("chat-c", chat("c", 60));
    await render("chat-d", chat("d", 30));
    nested = 0;
    // Each return, to the long chat (opened at its latest row) and to the short one.
    await render("chat-c", chat("c", 60));
    expect(nested).toBe(0);
    await render("chat-d", chat("d", 30));
    expect(nested).toBe(0);
  } finally {
    await act(async () => root.unmount());
    host.remove();
    delete (proto as { scrollTop?: number }).scrollTop;
    if (own) Object.defineProperty(dom.window.Element.prototype, "scrollTop", own);
  }
});

test("a switch to another chat commits once, then its reset once, deferred", async () => {
  // Before: the switch's reset effect set the selection, active row, range and held rows for the new
  // chat as sync state, a second whole-transcript commit inside the switch's long task. Those values
  // are drawn by the switch render already; as a transition they land after the first paint
  // (settled page, Leo 2026-11-21: "workspace switch, opening a recent workspace, chat switch and
  // restart reach a settled page (zero layout shift after first paint, streaming included) within 2x
  // of a derived bound").
  const { Profiler } = await import("react");
  const { flushSync } = await import("react-dom");
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const expanded = new Set<string>();
  let commits = 0;
  const tree = (sessionId: string, rows: AcpmuxRow[]) => (
    <Profiler id="transcript" onRender={() => (commits += 1)}>
      <VirtualTranscript
        rows={rows}
        registry={defaultRegistry}
        sessionId={sessionId}
        onToggleActivity={() => {}}
        expanded={expanded}
      />
    </Profiler>
  );
  try {
    await act(async () => {
      root.render(tree("chat-e", chat("e", 40)));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    commits = 0;
    // The switch as the app does it: one sync task, then the frame.
    flushSync(() => root.render(tree("chat-f", chat("f", 40))));
    // Sync work its effects ask runs in microtasks of the same task, still before the frame.
    for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
    expect(commits).toBe(1);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    // The reset lands in one deferred commit; as blocking state it took two whole-transcript renders.
    expect(commits).toBe(2);
    // The new chat shows its own rows once the transition lands.
    expect(host.textContent).toContain("f message");
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

test("a kept layout seeds only the look it was measured with, at its scale, and is bounded", () => {
  let now = 0;
  const kept = new KeptLayouts<string, AcpmuxRow>(2, () => now);
  const look = {};
  const rows = chat("a", 3);
  const heights = new WeakMap(rows.map((row) => [row, { width: 700, height: 42, scale: 1 }] as const));
  const layout = { drawn: "drawn", rows, heights, look, view: "attachments", registry: defaultRegistry };
  kept.record("a", layout);
  expect(kept.show("a", {}, "attachments", defaultRegistry, 1)).toBeUndefined();
  expect(kept.show("a", look, "attachments", defaultRegistry, 1)).toBe("drawn");
  // The rows built again for the return take the kept heights; a row that changed does not.
  const back = chat("a", 3);
  back[2] = { ...back[2]!, version: 2 };
  const into = new WeakMap<AcpmuxRow, { width: number; height: number }>();
  kept.seed("a", back, into, 1);
  expect([into.get(back[0]!)?.height, into.get(back[1]!)?.height, into.get(back[2]!)]).toEqual([42, 42, undefined]);
  // Seeding stops after its passes and its time.
  for (let pass = 0; pass < 3; pass += 1) kept.seed("a", back, new WeakMap(), 1);
  now = 2_000;
  kept.seed("a", back, new WeakMap(), 1);
  const late = new WeakMap<AcpmuxRow, { width: number; height: number }>();
  kept.seed("a", back, late, 1);
  expect(late.has(back[0]!)).toBe(false);
  // At another Interface Size nothing seeds.
  kept.show("a", look, "attachments", defaultRegistry, 1.25);
  const scaled = new WeakMap<AcpmuxRow, { width: number; height: number }>();
  kept.seed("a", back, scaled, 1.25);
  expect(scaled.has(back[0]!)).toBe(false);
  kept.record("b", layout);
  kept.record("c", layout);
  expect(kept.size).toBe(2);
  expect(kept.show("a", look, "attachments", defaultRegistry, 1)).toBeUndefined();
  kept.forget("c");
  expect(kept.show("c", look, "attachments", defaultRegistry, 1)).toBeUndefined();
});

test("a kept height stands only for the same row at the same scale", () => {
  const heights = new Map([["r", { version: 3, textLength: 5, width: 700, height: 42, scale: 1 }]]);
  expect(keptHeightFor(heights, { id: "r", version: 3, text: "hello" }, 1)?.height).toBe(42);
  expect(keptHeightFor(heights, { id: "r", version: 4, text: "hello" }, 1)).toBeUndefined();
  expect(keptHeightFor(heights, { id: "r", version: 3, text: "hello!" }, 1)).toBeUndefined();
  expect(keptHeightFor(heights, { id: "r", version: 3, text: "hello" }, 1.25)).toBeUndefined();
  expect(keptHeightFor(heights, { id: "s", version: 3, text: "hello" }, 1)).toBeUndefined();
});
