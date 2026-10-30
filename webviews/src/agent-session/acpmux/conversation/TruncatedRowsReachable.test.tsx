// l10n-allow-file: test fixtures.
// A row that cuts its text short opens to all of it (Leo, ask-486cb2cec3: "why the fuck did you guys
// ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE"), one test per row kind
// this fixes:
// - a tool call's line (no shell): it opens, with output or without, and opened its label is drawn
//   whole (`is-whole-open`, conversation.css), never only its first words;
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
    const container = await render(<ToolRow item={item} />);
    const line = container.querySelector<HTMLButtonElement>("button.cv-tool")!;
    expect(line).not.toBeNull();
    expect(line.classList.contains("is-whole-open")).toBe(true);
    expect(line.getAttribute("aria-expanded")).toBe("false");
    await act(async () => line.click());
    expect(line.getAttribute("aria-expanded")).toBe("true");
    // The label holds the whole pattern; opened, the stylesheet draws it wrapped, not cut.
    expect(line.querySelector(".cv-tool__text")!.textContent).toContain(PATTERN);
  });
}

test("a shell's line keeps its one line: its Shell block shows the whole command", async () => {
  const shell: AcpmuxActivity = {
    kind: "tool",
    text: "ls",
    tool: { id: "sh-1", title: "ls", kind: "execute", command: "ls -la", status: "completed", output: "a\n" },
  };
  const container = await render(<ToolRow item={shell} />);
  expect(container.querySelector("button.cv-tool")!.classList.contains("is-whole-open")).toBe(false);
});

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
