// l10n-allow-file: test fixture arguments, not shipped UI.
// An agent's tool result renders an extension's chat widget (cmux.chat.widget/1) under the call: the
// page asks the daemon which extension answers (`cmux.apps.panels.route`), mounts that answer on the
// chatWidget surface and draws its scene with the sections' renderer. No answer draws nothing.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { ChatWidgetClientContext, widgetTool } from "./ToolWidget";
import { ToolRow } from "./ToolRow";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "NodeFilter",
  "HTMLElement",
  "Element",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    NodeFilter: dom.window.NodeFilter,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

/** Lets the route, mount and scene subscription answer, and React commit what they drew. */
async function settle() {
  for (let i = 0; i < 6; i++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

function call(title: string, status: string, input: unknown, id = "toolu_42"): AcpmuxActivity {
  return {
    kind: "tool",
    text: title,
    tool: { id, title, kind: "other", status, inputSummary: JSON.stringify(input), output: '{"title":"x"}' },
  };
}

const PR_CALL = call("mcp__github__get_pull_request", "completed", {
  owner: "manaflow-ai",
  repo: "cmux",
  pullNumber: 42,
});

test("an MCP call is routed by its mcp__<server>__<tool> name with its arguments", () => {
  expect(widgetTool(PR_CALL.tool!)).toEqual({
    name: "mcp__github__get_pull_request",
    title: "mcp__github__get_pull_request",
    status: "completed",
    input: { owner: "manaflow-ai", repo: "cmux", pullNumber: 42 },
    output: '{"title":"x"}',
  });
});

test("an agent's tool result renders the extension's widget under the call", async () => {
  const client = new MockAppPanelsClient();
  const container = await render(
    <ChatWidgetClientContext.Provider value={client}>
      <ToolRow item={PR_CALL} />
    </ChatWidgetClientContext.Provider>,
  );
  await settle();
  expect(client.routes).toEqual([{ key: "tool:toolu_42", tool: widgetTool(PR_CALL.tool!) }]);
  const widget = container.querySelector(".cv-tool-widget");
  expect(widget?.getAttribute("data-app")).toBe("local/pr-card");
  const rows = [...widget!.querySelectorAll('[data-app-type="Row"]')].map((row) => row.textContent ?? "");
  expect(rows[0]).toContain("manaflow-ai/cmux #42");
  expect(rows.some((row) => row.includes("test (macos)"))).toBe(true);
});

test("a call no extension answers, or one still running, draws no widget and mounts nothing", async () => {
  const client = new MockAppPanelsClient();
  const container = await render(
    <ChatWidgetClientContext.Provider value={client}>
      <ToolRow item={call("mcp__linear__get_issue", "completed", { id: "ENG-1" }, "toolu_50")} />
      <ToolRow item={{ ...PR_CALL, tool: { ...PR_CALL.tool!, id: "toolu_43", status: "in_progress" } }} />
    </ChatWidgetClientContext.Provider>,
  );
  await settle();
  expect(container.querySelector(".cv-tool-widget")).toBeNull();
  // The running call is not asked about until it ends; the other is asked once and gets no widget.
  expect(client.routes.map((route) => (route as { key: string }).key)).toEqual(["tool:toolu_50"]);
});

test("without a page host (an older host or a plain browser) a call looks as it always did", async () => {
  const container = await render(
    <ChatWidgetClientContext.Provider value={null}>
      <ToolRow item={PR_CALL} />
    </ChatWidgetClientContext.Provider>,
  );
  await settle();
  expect(container.querySelector(".cv-tool-widget")).toBeNull();
});
