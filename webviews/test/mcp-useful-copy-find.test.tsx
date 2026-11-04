// Condensing a result changes its presentation, never the response copied or found in chat.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLAnchorElement",
  "NodeFilter",
  "Node",
  "customElements",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
  "CSS",
  "Highlight",
  "cmuxExperiments",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];
let clipboard: string[] = [];
const highlights = new Map<string, { ranges: Range[] }>();

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }));
  Object.defineProperty(window.navigator, "clipboard", {
    value: {
      writeText: async (text: string) => {
        clipboard.push(text);
      },
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLAnchorElement: window.HTMLAnchorElement,
    NodeFilter: window.NodeFilter,
    Node: window.Node,
    customElements: window.customElements,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
    CSS: {
      highlights: {
        set: (name: string, value: { ranges: Range[] }) => highlights.set(name, value),
        delete: (name: string) => highlights.delete(name),
      },
    },
    Highlight: class {
      constructor(...ranges: Range[]) {
        this.ranges = ranges;
      }
      ranges: Range[];
    },
    cmuxExperiments: { "hover-actions": "all" },
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  clipboard = [];
  highlights.clear();
});
afterAll(() => {
  window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
async function render(node: ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}
async function click(node: HTMLElement | undefined | null) {
  expect(node).toBeTruthy();
  await act(async () => node!.click());
}
const call = (args: unknown, output: string): AcpmuxActivity => ({
  kind: "tool",
  text: "mcp__test__inspect",
  tool: {
    id: "inspect",
    title: "mcp__test__inspect",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify(args),
    output,
  },
});

for (const [kind, args, selector] of [
  ["command", { command: "printf payment" }, ".cv-shell__output"],
  ["response", { query: "payment" }, ".cv-tool-output"],
] as const) {
  test(`a condensed MCP ${kind} copies its original JSON through clipboard and context menu`, async () => {
    const { McpCallRow } = await import("../src/agent-session/acpmux/conversation/McpCallRows");
    const { installMessageMenuReporter } = await import("../src/agent-session/acpmux/conversation/messageMenu");
    const original = JSON.stringify({ type: "payment", amount: 17 }, null, 2);
    await render(<McpCallRow item={call(args, original)} />);
    await click(host.querySelector<HTMLButtonElement>("button.cv-tool"));
    const output = host.querySelector<HTMLElement>(selector)!;
    expect(output.textContent).toContain("amount: 17");
    expect(output.textContent).not.toContain("payment");
    await click(
      [...host.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.getAttribute("aria-label") === "Copy",
      ),
    );
    expect(clipboard).toEqual([original]);
    const reports: unknown[] = [];
    const cleanup = installMessageMenuReporter(window.document, () => ({ postMessage: (body) => reports.push(body) }));
    try {
      output.dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true }));
      expect(reports).toHaveLength(1);
      expect(reports[0]).toMatchObject({ part: { output: original } });
    } finally {
      cleanup();
    }
  });
}

for (const [needle, text] of [
  ["description", "description"],
  ["waiting", "Waiting"],
] as const) {
  test(`Find opens and highlights the original ${needle} in an otherwise inert MCP step`, async () => {
    const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
    const { FindReveal, findMatches, paintFindHighlights } =
      await import("../src/agent-session/acpmux/conversation/chatFind");
    const row: AcpmuxRow = {
      id: "find-row",
      version: 1,
      at: 1,
      kind: "activity",
      items: [call({ description: "Inspect lifecycle state" }, "Waiting…")],
    };
    const view = (
      <div data-row-id={row.id}>
        <ToolRows row={row} />
      </div>
    );
    await render(view);
    expect(host.querySelector(".cv-mcp-call")).toBeNull();
    expect(findMatches([row], needle).length).toBeGreaterThan(0);
    await render(
      <FindReveal.Provider value={{ rowId: row.id, card: false, needle, repaint: () => {} }}>
        {view}
      </FindReveal.Provider>,
    );
    const raw = [...host.querySelectorAll<HTMLButtonElement>("button.cv-subsession__toggle")].find(
      (button) => button.textContent?.trim() === "Raw",
    );
    expect(raw?.getAttribute("aria-expanded")).toBe("true");
    const active = paintFindHighlights(host, needle, { rowId: row.id, card: false, occurrence: 0 });
    expect(active?.toString()).toBe(text);
    expect(highlights.get("acpmux-find-active")?.ranges).toHaveLength(1);
  });
}
