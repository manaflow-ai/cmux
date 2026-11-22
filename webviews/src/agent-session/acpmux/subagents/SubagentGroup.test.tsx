import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { withSubagentRows } from "./subagentRows";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "customElements",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    callback(Date.now());
    return 0;
  },
  cancelAnimationFrame: () => undefined,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UiProvider } = await import("../../../ui/UiProvider");
const { SubagentGroupHeader, SubagentListRow } = await import("./SubagentGroup");
const SharedUiProvider = UiProvider as any;

const agent = (id: string): Subagent => ({
  id,
  parent: null,
  name: id,
  task: id,
  state: "completed",
  startedAt: 1,
  endedAt: 2,
});
const group: AcpmuxRow = {
  id: "subagents-1",
  version: 1,
  at: 1,
  kind: SUBAGENTS,
  subagents: [agent("a"), agent("b")],
};

test("an expanded subagent disclosure controls its rows and keeps focus", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  let expanded = false;
  const draw = () => {
    const rows = withSubagentRows([group], expanded ? new Set([group.id]) : new Set());
    root.render(
      createElement(
        SharedUiProvider,
        { container: container.ownerDocument.body, dir: "ltr" },
        createElement(
          "div",
          null,
          createElement(SubagentGroupHeader, {
            row: rows[0]!,
            expanded,
            onToggle: () => {
              expanded = !expanded;
              draw();
            },
          }),
          ...rows.slice(1).map((row) => createElement(SubagentListRow, { key: row.id, row })),
        ),
      ),
    );
  };

  try {
    await act(async () => draw());
    const disclosure = () => container.querySelector<HTMLButtonElement>(".cv-subagents")!;
    expect(disclosure().getAttribute("aria-controls")).toBeNull();

    disclosure().focus();
    await act(async () => disclosure().click());

    const controls = disclosure().getAttribute("aria-controls")!.split(" ");
    expect(controls).toEqual(["subagents-1:a", "subagents-1:b"]);
    expect(controls.map((id) => dom.window.document.getElementById(id)?.id)).toEqual(controls);
    expect([...container.querySelectorAll(".cv-subagent")].map((row) => row.id)).toEqual(controls);
    expect(dom.window.document.activeElement).toBe(disclosure());
  } finally {
    await act(async () => root.unmount());
  }
});
