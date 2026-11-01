// l10n-allow-file: test fixture chart sources, not shipped UI.
// A chart or diagram that redraws (its source changed, or its block left the page) must not be written
// over by a render still running for the earlier draw: a late Vega or Mermaid render used to replace
// the newer chart, so Save exported a stale one. The earlier draw's Vega view is finalized too (its
// timers and window listeners), and cancelDiagram stops the current one.
import { afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type * as Diagrams from "../src/pages/markdown/diagrams";

let diagrams: typeof Diagrams;
const scope = globalThis as Record<string, unknown>;
const restore = new Map<string, unknown>();

beforeAll(async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "DOMParser", "Node", "Element", "HTMLElement", "SVGElement"]) {
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  diagrams = await import("../src/pages/markdown/diagrams");
});

beforeEach(() => {
  // No Ondine here: Mermaid is the renderer, as for a source Ondine refuses.
  for (const key of ["ondine", "mermaid", "vega"]) restore.set(key, scope[key]);
  delete scope.ondine;
});

afterEach(() => {
  for (const [key, value] of restore) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  document.body.replaceChildren();
});

const libraries = () => new diagrams.DiagramLibraries(() => null);
const target = () => {
  const element = document.createElement("div");
  document.body.append(element);
  return element;
};
/** A promise a test settles by hand, so one render can finish after another. */
function gate() {
  let release: () => void = () => undefined;
  const promise = new Promise<void>((resolve) => (release = resolve));
  return { promise, release };
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** Mermaid whose render of each source waits for that source's gate and answers an svg naming it. */
function stubMermaid(gates: Record<string, Promise<void>>) {
  scope.mermaid = {
    initialize() {},
    async render(_id: string, source: string) {
      await gates[source];
      return { svg: `<svg data-source="${source}"><rect width="1" height="1"/></svg>` };
    },
  };
}

test("a Mermaid render that finishes after a newer one leaves the newer diagram", async () => {
  const older = gate();
  const newer = gate();
  stubMermaid({ old: older.promise, new: newer.promise });
  const el = target();
  const first = diagrams.renderMermaid(libraries(), "old", el);
  const second = diagrams.renderMermaid(libraries(), "new", el);
  newer.release();
  await second;
  expect(el.querySelector("svg")?.getAttribute("data-source")).toBe("new");
  older.release();
  await first;
  expect(el.querySelector("svg")?.getAttribute("data-source")).toBe("new");
  expect(el.querySelectorAll("svg").length).toBe(1);
});

test("cancelDiagram makes a render still running drop its result", async () => {
  const pending = gate();
  stubMermaid({ slow: pending.promise });
  const el = target();
  const drawing = diagrams.renderMermaid(libraries(), "slow", el);
  diagrams.cancelDiagram(el);
  pending.release();
  await drawing;
  expect(el.querySelector("svg")).toBeNull();
});

/** A Vega stand-in whose views record `finalize` and whose runAsync waits for the spec's gate. */
function stubVega(gates: Record<string, Promise<void>>) {
  const finalized: string[] = [];
  scope.vega = {
    parse: (spec: { name: string }) => spec,
    View: class {
      constructor(
        private readonly runtime: { name: string },
        options: { container: HTMLElement },
      ) {
        options.container.dataset.view = runtime.name;
      }
      async runAsync() {
        await gates[this.runtime.name];
      }
      finalize() {
        finalized.push(this.runtime.name);
      }
    },
  };
  return finalized;
}

test("a Vega render that finishes late is finalized and never replaces the newer chart", async () => {
  const older = gate();
  const newer = gate();
  const finalized = stubVega({ old: older.promise, new: newer.promise });
  const el = target();
  const first = diagrams.renderVega(libraries(), "vega", JSON.stringify({ name: "old" }), el);
  const second = diagrams.renderVega(libraries(), "vega", JSON.stringify({ name: "new" }), el);
  newer.release();
  await second;
  expect(el.firstElementChild?.getAttribute("data-view")).toBe("new");
  older.release();
  await first;
  await tick();
  expect(el.firstElementChild?.getAttribute("data-view")).toBe("new");
  // The stale view stopped; the one on screen did not.
  expect(finalized).toEqual(["old"]);
});

test("cancelDiagram finalizes the Vega view on screen and one still running", async () => {
  const done = gate();
  const running = gate();
  const finalized = stubVega({ shown: done.promise, late: running.promise });
  const el = target();
  done.release();
  await diagrams.renderVega(libraries(), "vega", JSON.stringify({ name: "shown" }), el);
  expect(finalized).toEqual([]);
  const late = diagrams.renderVega(libraries(), "vega", JSON.stringify({ name: "late" }), el);
  diagrams.cancelDiagram(el);
  expect(finalized).toEqual(["shown"]);
  running.release();
  await late;
  expect(finalized).toEqual(["shown", "late"]);
  expect(el.firstElementChild?.getAttribute("data-view")).toBe("shown");
});
