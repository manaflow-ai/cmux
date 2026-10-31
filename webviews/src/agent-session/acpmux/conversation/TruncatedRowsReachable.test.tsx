// l10n-allow-file: test fixtures.
// A row that cuts its text short opens to all of it (Leo, ask-486cb2cec3: "why the fuck did you guys
// ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE"), one test per row kind
// this fixes:
// - a tool call's line (no shell): it opens when it has output, or when a long label itself is cut;
//   a short label with no detail stays an inert row;
// - a dispatch report's text: the whole report, never cut at 2,000 characters.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { dispatchCall } from "./dispatchCalls";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";
import { ToolRow } from "./ToolRow";

let dom: JSDOM | undefined;
let root: Root | undefined;
let labelWidth = 300;
let labelScrollWidth = 300;
const resizeCallbacks = new Set<() => void>();
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.defineProperties(dom.window.HTMLElement.prototype, {
    clientWidth: {
      configurable: true,
      get() {
        return this.classList.contains("cv-tool__text") ? labelWidth : 0;
      },
    },
    scrollWidth: {
      configurable: true,
      get() {
        return this.classList.contains("cv-tool__text") ? labelScrollWidth : 0;
      },
    },
  });
  Object.defineProperty(dom.window, "ResizeObserver", {
    value: class {
      callback: () => void;
      constructor(callback: () => void) {
        this.callback = callback;
      }
      observe() {
        resizeCallbacks.add(this.callback);
      }
      disconnect() {
        resizeCallbacks.delete(this.callback);
      }
    },
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  expect(resizeCallbacks.size).toBe(0);
  labelWidth = 300;
  labelScrollWidth = 300;
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const PATTERN = "useAnchoredCollapse|useTranscriptDisclosure|holdFold|keepFold|foldToggleAt|ANCHORED_COLLAPSE_EVENT";

const search = (output?: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Grep ${PATTERN}`,
  tool: {
    id: "grep-1",
    title: `Grep ${PATTERN}`,
    kind: "search",
    status: "completed",
    ...(output === undefined ? {} : { output }),
  },
});

for (const [kind, item] of [
  ["with output", search("App.tsx:12: holdFold(toggle)")],
  ["without output", search()],
] as const) {
  test(`a tool call's line ${kind} opens to its whole label`, async () => {
    labelScrollWidth = 800;
    const container = await render(<ToolRow item={item} />);
    const line = container.querySelector<HTMLButtonElement>("button.cv-tool")!;
    expect(line).not.toBeNull();
    expect(line.classList.contains("is-whole-open")).toBe(true);
    expect(line.getAttribute("aria-expanded")).toBe("false");
    await act(async () => line.click());
    expect(line.getAttribute("aria-expanded")).toBe("true");
    // The label holds the whole pattern; opened, the stylesheet draws it wrapped, not cut.
    expect(line.querySelector(".cv-tool__text")!.textContent).toContain(PATTERN);
    // It names a body only when one is drawn: a call with no output opens to its label alone.
    const controls = line.getAttribute("aria-controls");
    if (controls) expect(container.querySelector(`[id="${controls}"]`)).not.toBeNull();
    else expect(kind).toBe("without output");
  });
}

test("a long label that fits does not offer an empty disclosure", async () => {
  labelWidth = 1000;
  labelScrollWidth = 800;
  const container = await render(<ToolRow item={search()} />);
  expect(container.querySelector("button.cv-tool")).toBeNull();
});

test("a label-only row becomes expandable on overflow and stays collapsible while wrapped", async () => {
  const container = await render(<ToolRow item={search()} />);
  expect(container.querySelector("button.cv-tool")).toBeNull();
  await act(async () => {
    labelWidth = 100;
    labelScrollWidth = 300;
    for (const callback of resizeCallbacks) callback();
  });
  const line = container.querySelector<HTMLButtonElement>("button.cv-tool")!;
  expect(line).not.toBeNull();
  await act(async () => line.click());
  expect(line.getAttribute("aria-expanded")).toBe("true");
  await act(async () => {
    labelScrollWidth = 100;
    for (const callback of resizeCallbacks) callback();
  });
  expect(container.querySelector("button.cv-tool")).toBe(line);
  await act(async () => line.click());
  expect(container.querySelector("button.cv-tool")).toBeNull();
});

test("a shell's line keeps its one line: its Shell block shows the whole command", async () => {
  const shell: AcpmuxActivity = {
    kind: "tool",
    text: "ls",
    tool: { id: "sh-1", title: "ls", kind: "execute", command: "ls -la", status: "completed", output: "a\n" },
  };
  const container = await render(<ToolRow item={shell} />);
  expect(container.querySelector("button.cv-tool")!.classList.contains("is-whole-open")).toBe(false);
});

for (const [name, output] of [
  ["without output", undefined],
  ["with whitespace output", " \n\t"],
  ["with an image-only result", '{"content":[{"type":"image","mimeType":"image/png","data":"aGVsbG8="}]}'],
] as const) {
  test(`a short tool call ${name} has no empty disclosure`, async () => {
    const item: AcpmuxActivity = {
      kind: "tool",
      text: "Wait 60000 ms",
      tool: {
        id: `wait-${name}`,
        title: "Wait 60000 ms",
        kind: "execute",
        status: "completed",
        ...(output === undefined ? {} : { output }),
      },
    };
    const container = await render(<ToolRow item={item} />);
    expect(container.querySelector("button.cv-tool")).toBeNull();
    expect(container.querySelector(".cv-tool")?.tagName).toBe("DIV");
    expect(container.querySelector(".cv-tool")?.getAttribute("aria-expanded")).toBeNull();
    expect(container.querySelector(".cv-tool__chevron")).toBeNull();
    expect(container.querySelector(".cv-tool")?.getAttribute("aria-controls")).toBeNull();
  });
}

test("a dispatch report keeps its whole text", () => {
  const long = `${"The picker now fails over a stalled label. ".repeat(80)}END`;
  expect(long.length).toBeGreaterThan(2_000);
  const call = dispatchCall({
    kind: "tool",
    text: "acp.dispatch",
    tool: {
      id: "d-1",
      title: "acp.dispatch",
      status: "completed",
      inputSummary: JSON.stringify({ server: "codex_apps", tool: "report", arguments: { brief_id: "b-1" } }),
      output: long,
    },
  });
  expect(call?.kind).toBe("report");
  expect(call?.text?.endsWith("END")).toBe(true);
  expect(call?.text).toBe(long.trim());
  expect(call?.summary).toBe(long.trim());
});
