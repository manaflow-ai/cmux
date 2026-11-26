// A transcript row that throws while drawing draws as one note line, and every other row keeps
// drawing: before, only a reply's markdown had a boundary, so a tool card, diff or plan that threw
// took the whole pane down, and Retry's reload painted the same rows again from the saved snapshot
// (Leo, 2026-11-22: "the agent pane just blanked out entirely ... we need to make sure any solutions
// that reloading would help with, we never encounter those classes of bugs in the first place").
import { afterAll, afterEach, expect, test } from "bun:test";
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
  sessionStorage: dom.window.sessionStorage,
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

Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? 40 : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { PaneBoundary } = await import("../src/agent-session/acpmux/PaneBoundary");
const { saveSnapshot, emptySnapshot } = await import("../src/agent-session/acpmux/snapshotCache");
const SNAPSHOT_KEY = "cmux.acpmux.snapshot";

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const originalError = console.error;
let logged: unknown[][] = [];
afterEach(() => {
  console.error = originalError;
  logged = [];
  delete dom.window.__cmuxPaneFailure;
  dom.window.sessionStorage.clear();
});
function quietErrors() {
  console.error = (...args: unknown[]) => void logged.push(args);
}

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const Plain = ({ row }: { row: AcpmuxRow }) => <p className="plain-row">{row.text}</p>;
/// A tool card whose data it cannot draw: it throws while the row's text says so.
const Card = ({ row }: { row: AcpmuxRow }) => {
  if (row.text === "bad") throw new Error("tool card cannot draw");
  return <p className="tool-card">{row.text}</p>;
};
const registry = { user: Plain, assistant: Plain, tool: Card } as unknown as Parameters<
  typeof VirtualTranscript
>[0]["registry"];

test("a row that throws draws as one note line and every other row draws", async () => {
  quietErrors();
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  const draw = (card: AcpmuxRow) =>
    act(async () =>
      root.render(
        <PaneBoundary>
          <VirtualTranscript
            rows={[row("u1", "user", { text: "Question" }), card, row("a1", "assistant", { text: "Answer" })]}
            working={false}
            registry={registry}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </PaneBoundary>,
      ),
    );
  try {
    const card = row("t1", "tool", { text: "bad", version: 1 });
    await draw(card);
    const doc = dom.window.document;
    expect(dom.window.__cmuxPaneFailure).toBeUndefined();
    expect(doc.querySelector(".acpmux-pane-failed")).toBeNull();
    expect([...doc.querySelectorAll(".plain-row")].map((node) => node.textContent)).toEqual(["Question", "Answer"]);
    const failed = doc.querySelector('[data-row-id="t1"] [data-row-failed]');
    expect(failed).not.toBeNull();
    expect(failed!.querySelectorAll("p").length).toBe(1);
    // Logged as the pane logs its own failure, naming the row.
    const entry = logged.find(([message]) => message === "agent pane row failed to draw");
    expect((entry?.[1] as { row?: string; message?: string })?.row).toBe("t1");
    expect((entry?.[1] as { message?: string })?.message).toContain("tool card cannot draw");

    // Its next version draws again.
    await draw({ ...card, version: 2, text: "fixed" });
    expect(doc.querySelector('[data-row-id="t1"] [data-row-failed]')).toBeNull();
    expect(doc.querySelector('[data-row-id="t1"] .tool-card')?.textContent).toBe("fixed");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a pane failure drops the saved snapshot so Retry's reload cannot repaint the rows that threw", async () => {
  quietErrors();
  dom.window.sessionStorage.setItem(SNAPSHOT_KEY, JSON.stringify({ type: "snapshot", rows: [], sessions: [] }));
  function Broken(): never {
    throw new Error("broken pane");
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <PaneBoundary>
          <Broken />
        </PaneBoundary>,
      ),
    );
    expect(dom.window.__cmuxPaneFailure?.message).toContain("broken pane");
    expect(dom.window.sessionStorage.getItem(SNAPSHOT_KEY)).toBeNull();
    // The live client keeps saving, and the page unloads: neither puts the copy back.
    saveSnapshot(emptySnapshot());
    dom.window.dispatchEvent(new dom.window.Event("pagehide"));
    expect(dom.window.sessionStorage.getItem(SNAPSHOT_KEY)).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});
