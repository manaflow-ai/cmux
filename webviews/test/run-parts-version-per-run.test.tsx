// A running turn's long run cut into parts (runParts.ts) keeps every part's version while its calls stay the same,
// however many parts the run has: a live snapshot that changes one call draws that call's part again and no other.
// The part versions were one map of 512 kept for every run, so a run of more than 512 parts dropped its first parts
// while it was still being cut, and on the next snapshot every part took a new version and every mounted row drew,
// laid out and measured again. Leo, 2026-11-14: "the dream is infinite chats of infinite length with flat or no
// growth in cpu/memory/even disk".
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
// jsdom has no layout: a row draws 28px a line it holds (a card, a tool line), as the pane's rows do.
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const lines = this.dataset.rowId ? Math.max(1, this.querySelectorAll("p, li, .cv-agentcall, .cv-step").length) : 0;
  const height = lines * 28;
  return { x: 0, y: 0, top: 0, left: 0, right: 760, bottom: height, width: 760, height, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
/// Yields until `done()` holds, at most `ms`; whether it held.
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await act(async () => void (await tick()));
  return done();
};

type Item = NonNullable<AcpmuxRow["items"]>[number];

/// The run's `n`th Agent call, still running or done.
const agentCall = (n: number, done: boolean): Item =>
  ({
    kind: "tool",
    text: "",
    tool: {
      id: `agent-${n}`,
      title: "Agent",
      kind: "think",
      status: done ? "completed" : "in_progress",
      inputSummary: JSON.stringify({
        description: `Review step ${n}`,
        prompt: `Review the diff of step ${n}.`,
        subagent_type: "general-purpose",
      }),
      ...(done ? { output: `Reviewed step ${n}: no findings.\nagentId: sub-${n}` } : {}),
    },
  }) as Item;

/// The run's `n`th step's `k`th shell call.
const shellCall = (n: number, k: number): Item =>
  ({
    kind: "tool",
    text: "",
    tool: {
      id: `c-${n}-${k}`,
      title: `glaeda-gh status pr ${n}`,
      kind: "execute",
      status: "completed",
      command: `glaeda-gh status pr ${n}`,
      output: "checks SUCCESS",
    },
  }) as Item;

/// Parts the run is cut into: an Agent card and the two calls after it are two stretches, a part holds eight.
const PARTS = 2_000;

test("a live snapshot that changes one call of a 2,000-part run draws only that call's part", async () => {
  const { runParts, RUN_PART_STRETCHES } = await import("../src/agent-session/acpmux/conversation/runParts");
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { acpmuxPerf } = await import("../src/agent-session/acpmux/perf");
  const steps = (PARTS * RUN_PART_STRETCHES) / 2;
  const items: Item[] = [];
  for (let n = 0; n < steps; n += 1) items.push(agentCall(n, n % 3 === 0), shellCall(n, 0), shellCall(n, 1));
  const at = 1_700_000_000_000;
  const user = { id: "u", version: 1, at, kind: "user", text: "Coordinate the lanes" } as AcpmuxRow;
  const run: AcpmuxRow = { id: "run-1", version: 7, at, kind: "activity", items, foldRun: true, settled: true };
  const before = runParts(run);
  expect(before.length).toBe(PARTS);

  // The next snapshot: the turn keeps every unchanged call's object, and the last Agent call ends.
  const last = steps - 1;
  expect(last % 3).not.toBe(0);
  const changed = [...items];
  changed[last * 3] = agentCall(last, true);
  const next: AcpmuxRow = { ...run, version: 8, items: changed };
  const after = runParts(next);
  expect(after.map((part) => part.id)).toEqual(before.map((part) => part.id));
  const moved = after.filter((part, k) => part.version !== before[k]!.version).map((part) => part.id);

  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const wasEnabled = acpmuxPerf.enabled;
  acpmuxPerf.enabled = true;
  const rowRenders = () => [...acpmuxPerf.renders].filter(([name]) => name.startsWith("row:"));
  const renderCount = () => rowRenders().reduce((sum, [, count]) => sum + count, 0);
  /// Waits until a frame passes that renders no row: the follow pass and the warm rows have settled.
  const quiet = async () => {
    let seen = -1;
    return settle(() => {
      const now = renderCount();
      const still = now === seen;
      seen = now;
      return still;
    }, 20_000);
  };
  const draw = (parts: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript rows={[user, ...parts]} working onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
  const lastPart = () =>
    [...host.querySelectorAll<HTMLElement>("[data-row-id]")].find((node) => node.dataset.rowId === after.at(-1)!.id);
  try {
    await draw(before);
    // Followed to its end, as the open chat is: the run's last part is in the window.
    expect(await settle(() => lastPart() !== undefined, 20_000)).toBe(true);
    expect(await quiet()).toBe(true);
    const mounted = host.querySelectorAll(".acpmux-row").length;
    expect(mounted).toBeGreaterThan(1);
    acpmuxPerf.resetRenders();

    await draw(after);
    expect(await settle(() => lastPart()?.textContent?.includes(`Reviewed step ${last}`) === true, 20_000)).toBe(true);
    expect(await quiet()).toBe(true);
    const drawn = rowRenders();
    console.log(
      `run-parts-version parts=${PARTS} mounted=${mounted} moved=${moved.length} rowRenders=${drawn.length}: ${JSON.stringify(drawn)}`,
    );
    expect(drawn.map(([name]) => name)).toEqual([`row:${after.at(-1)!.id}`]);
    // Only the part that holds the changed call takes a new version.
    expect(moved).toEqual([after.at(-1)!.id]);
  } finally {
    acpmuxPerf.enabled = wasEnabled;
    acpmuxPerf.resetRenders();
    await act(async () => root.unmount());
  }
}, 120_000);
