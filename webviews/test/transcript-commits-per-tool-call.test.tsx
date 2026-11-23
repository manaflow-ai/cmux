// A tool call's start or end, streamed into a long chat, commits the transcript once: the snapshot's
// own render. The row it changed is drawn again at the height already placed, so neither its drawn
// height (`sameDrawn` compares no version) nor the scroll pacer (`drewScroll`) renders the
// transcript a second time. Before cmux#50032 each record committed it about 2.6 times in the long
// replay (transcript_replay.long.tool_call_ms), 2.0 after; the bound below keeps that from coming back.
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
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
// jsdom has no layout: every row draws 40px tall, whatever its words.
const ROW_HEIGHT = 40;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? ROW_HEIGHT : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

const { act, Profiler } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const Plain = ({ row }: { row: AcpmuxRow }) => <p>{row.text}</p>;
const registry = { user: Plain, assistant: Plain, activity: Plain } as unknown as Parameters<
  typeof VirtualTranscript
>[0]["registry"];

const RECORDS = 24;

test("a streamed tool call's start or end commits a long chat's transcript once", async () => {
  const history = Array.from({ length: 300 }, (_, index) => [
    row(`${index}-user`, "user", { text: `Question ${index}` }),
    row(`${index}-answer`, "assistant", { text: `Answer ${index}.` }),
  ]).flat();
  const prompt = row("live-user", "user", { text: "Read the files" });
  let calls = row("live-calls", "activity", { text: "Read a.ts" });
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  const onToggleActivity = () => {};
  let commits = 0;
  const onRender = () => {
    commits += 1;
  };
  const draw = async () =>
    act(async () =>
      root.render(
        <Profiler id="transcript" onRender={onRender}>
          <VirtualTranscript
            rows={[...history, prompt, calls]}
            working
            registry={registry}
            onToggleActivity={onToggleActivity}
            expanded={expanded}
          />
        </Profiler>,
      ),
    );
  try {
    await draw();
    await draw();
    commits = 0;
    for (let record = 1; record <= RECORDS; record += 1) {
      // Each record is a call's start or end: the live activity row's words change, at its height.
      const file = `${Math.ceil(record / 2)}.ts`;
      calls = { ...calls, version: calls.version + 1, text: record % 2 ? `Reading ${file}` : `Read ${file}` };
      await draw();
    }
    const perRecord = commits / RECORDS;
    console.log(`PER-RECORD transcript commits: ${perRecord}`);
    expect(dom.window.document.body.textContent).toContain(`Read ${RECORDS / 2}.ts`);
    // The snapshot's render and one more (2 at cmux#50032's head; 3 before it, when the live row drawn again at
    // its placed height rendered the whole transcript a second time).
    expect(perRecord).toBeLessThanOrEqual(2.25);
  } finally {
    await act(async () => root.unmount());
  }
});
