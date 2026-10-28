// Copy a selection from the real transcript, including the footer produced by turnView.
// A finished answer is also the footer's copy source; selecting both must copy it only once.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

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
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout. A tall viewport mounts every row of these small conversations.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
const copied: string[] = [];
Object.defineProperty(dom.window.navigator, "clipboard", {
  value: { writeText: async (text: string) => void copied.push(text) },
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
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const completed = (id: string, prompt: string, answer: string): AcpmuxRow[] => [
  row(`${id}-user`, "user", prompt),
  row(`${id}-answer`, "assistant", answer),
  { ...row(`${id}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
];

async function copyRange(source: AcpmuxRow[], from: string, to: string, method: "keyboard" | "button" = "keyboard") {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView(source, new Set());
  const start = rows.findIndex((row) => row.id === from);
  const end = rows.findIndex((row) => row.id === to);
  if (start < 0 || end < start) throw new Error("invalid fixture selection");
  copied.length = 0;
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />),
    );
    const article = dom.window.document.querySelector<HTMLElement>(`[data-row-id="${from}"]`)!;
    const first = article.querySelector<HTMLButtonElement>(".acpmux-row__copy") ?? article;
    await act(async () => first.focus());
    for (let index = start; index < end; index += 1)
      await act(async () => {
        dom.window.document.activeElement!.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", {
            key: "ArrowDown",
            shiftKey: true,
            bubbles: true,
            cancelable: true,
          }),
        );
      });
    if (method === "button") {
      // A prompt drawn as the person's bubble has no floating Copy (#24267): the range's Copy is the
      // floating one on a selected row that still has it.
      const copy = dom.window.document.querySelector<HTMLButtonElement>(
        '[data-transcript-selected="true"] .acpmux-row__copy',
      );
      if (!copy) throw new Error("no selected row has a floating Copy");
      await act(async () => copy.click());
    } else
      await act(async () => {
        dom.window.document.activeElement!.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", { key: "c", metaKey: true, bubbles: true, cancelable: true }),
        );
      });
    expect(copied).toHaveLength(1);
    return copied[0];
  } finally {
    await act(async () => root.unmount());
  }
}

test("keyboard range copy includes a finished answer once", async () => {
  expect(await copyRange(completed("one", "Explain retries", "Retry **twice**."), "one-user", "one-end")).toBe(
    "Explain retries\n\nRetry **twice**.",
  );
});

// A prompt drawn as the person's bubble has no floating Copy of its own (#24267), and an answer's
// and its footer's Copy are the turn's, not the range's. Another agent's message, drawn as a line,
// keeps its floating Copy, which copies the selected range.
test("button range copy includes a finished answer once", async () => {
  const [prompt, answer, end] = completed("one", "Explain retries", "Retry **twice**.");
  const message: AcpmuxRow = {
    ...prompt!,
    incoming: { kind: "message", message: { name: "Retry lane", text: "Explain retries", raw: "" } },
  };
  expect(await copyRange([message, answer!, end!], "one-user", "one-end", "button")).toBe(
    "Explain retries\n\nRetry **twice**.",
  );
});

test("a selected footer still copies its answer when the answer row is outside the selection", async () => {
  expect(await copyRange(completed("one", "Explain retries", "Retry **twice**."), "one-end", "one-end")).toBe(
    "Retry **twice**.",
  );
});

test("identical answers from different turns remain separate in a selected conversation", async () => {
  const source = [...completed("one", "Run tests", "Passed."), ...completed("two", "Run again", "Passed.")];
  expect(await copyRange(source, "one-user", "two-end")).toBe("Run tests\n\nPassed.\n\nRun again\n\nPassed.");
});

test("an independent summary with no answer keeps its copy source", async () => {
  const source = [row("one-user", "user", "Run tests"), row("one-end", "turnSummary", "No response available")];
  expect(await copyRange(source, "one-user", "one-end")).toBe("Run tests\n\nNo response available");
});
