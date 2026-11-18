// l10n-allow-file: test fixtures.
// The agent UI surface card (UiSurfaceCard.tsx) and its gate: text an agent sends draws as text
// (an HTML string never becomes markup), a press asks acpmux and shows the host's Pending, Return
// confirms with the request's id, Escape and a changed value cancel it, and with Labs off a tool
// row's surface draws nothing. Also the reader (model.ts) and the MCP App bridge's ordering.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { setAgentUiSurfaces } from "../agentUiSurfaces";
import type { AcpmuxRow } from "../model";
import type { UiSurfaceClient } from "./actions";
import { approvalFull, pendingFor, refineSearch, travelerForm } from "./fixtures";
import { createFrameBridge, framedHtml } from "./frameBridge";
import { readUiSurface, type UiSurface } from "./model";
import { ToolUiSurfaces } from "./ToolUiSurfaces";
import { UiSurfaceCard } from "./UiSurfaceCard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "HTMLSelectElement",
  "Element",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(GLOBALS.slice(0, -1).map((key) => [key, w[key]])), {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setAgentUiSurfaces(false);
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
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

type Call = [string, Record<string, unknown>];
function recordingClient(calls: Call[], confirmed: unknown = { sent: "agent" }): UiSurfaceClient {
  return {
    uiSurfaceAction: async (params) => {
      calls.push(["action", params]);
      return pendingFor(params.actionId, params.values);
    },
    uiSurfaceConfirm: async (params) => {
      calls.push(["confirm", params]);
      return confirmed;
    },
    uiSurfaceCancel: async (params) => {
      calls.push(["cancel", params]);
      return { ok: true };
    },
    uiSurfaceBridge: async (params) => {
      calls.push(["bridge", params]);
      return {};
    },
    openLink: (url) => calls.push(["open", { url }]),
    draft: (text) => calls.push(["draft", { text }]),
  };
}

const button = (container: HTMLElement, name: string) =>
  [...container.querySelectorAll("button")].find((each) => each.textContent?.trim().startsWith(name))!;

async function click(element: Element) {
  await act(async () => {
    (element as HTMLElement).click();
  });
  // The client answers on a later tick.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function key(target: Element, name: string) {
  await act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
  });
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

test("an HTML string an agent sends draws as text, never as markup", async () => {
  const html = '<img src=x onerror="alert(1)"><b>bold</b><script>alert(2)</script>';
  const surface = readUiSurface({
    schema: "cmux.ui-surface/1",
    surfaceId: "s-html",
    source: { kind: "a2ui", server: "evil<b>", tool: "<i>t</i>" },
    status: "ready",
    title: "<h1>Title</h1>",
    root: {
      id: "root",
      type: "stack",
      children: [
        { id: "t", type: "text", text: html },
        { id: "b", type: "button", label: "<u>Go</u>", action: { id: "a", name: "go" } },
        { id: "w", type: "Widget<svg onload=x>" },
      ],
    },
  })!;
  const container = await render(<UiSurfaceCard surface={surface} client={recordingClient([])} />);
  expect(container.querySelector("img, b, script, h1, u, i, svg[onload]")).toBeNull();
  expect(container.textContent).toContain(html);
  expect(container.textContent).toContain("<u>Go</u>");
  expect(container.textContent).toContain("<h1>Title</h1>");
  // An unknown component is a fallback naming it, as text.
  expect(container.querySelector(".uis-fallback")?.textContent).toContain("Widget<svg onload=x>");
  expect(container.querySelector(".uis-source")?.textContent).toContain("evil<b> · <i>t</i>");
});

test("a press asks acpmux with the field values; Return confirms the host's request", async () => {
  const calls: Call[] = [];
  const surface = { ...refineSearch, surfaceId: "refine" };
  const container = await render(<UiSurfaceCard surface={surface} client={recordingClient(calls)} />);
  await click(container.querySelector('[role="radio"]')!);
  await click(button(container, "Apply"));
  expect(calls[0]).toEqual([
    "action",
    { surfaceId: "refine", actionId: "a-apply", values: { "/filters/maxPrice": 600, "/filters/stops": "any" } },
  ]);
  const strip = container.querySelector(".uis-confirm")!;
  expect(strip).not.toBeNull();
  expect(strip.textContent).toContain("filters/maxPrice = 600");
  // Nothing sent yet: only the action asked.
  expect(calls.filter(([kind]) => kind === "confirm")).toEqual([]);
  await key(strip.querySelector("[data-uis-confirm]")!, "Enter");
  // The values go with Confirm too: acpmux refuses it as stale when they changed what it sends.
  expect(calls.at(-1)).toEqual([
    "confirm",
    { surfaceId: "refine", requestId: "r-a-apply", values: { "/filters/maxPrice": 600, "/filters/stops": "any" } },
  ]);
  expect(container.querySelector(".uis-confirm")).toBeNull();
});

test("Escape cancels the pending request, and so does a changed value", async () => {
  const calls: Call[] = [];
  const container = await render(<UiSurfaceCard surface={travelerForm} client={recordingClient(calls)} />);
  await click(button(container, "Save traveller"));
  expect(container.querySelector(".uis-confirm")).not.toBeNull();
  await key(container.querySelector(".uis-confirm")!, "Escape");
  expect(calls.at(-1)).toEqual(["cancel", { surfaceId: travelerForm.surfaceId, requestId: "r-a-save" }]);
  expect(container.querySelector(".uis-confirm")).toBeNull();

  await click(button(container, "Save traveller"));
  expect(container.querySelector(".uis-confirm")).not.toBeNull();
  await click(container.querySelector('[role="radio"]')!);
  expect(calls.at(-1)?.[0]).toBe("cancel");
  expect(container.querySelector(".uis-confirm")).toBeNull();
  expect(calls.some(([kind]) => kind === "confirm")).toBe(false);
});

test("an approval's Approve shows the strip; a confirmed one reads Approved", async () => {
  const calls: Call[] = [];
  const container = await render(<UiSurfaceCard surface={approvalFull} client={recordingClient(calls)} />);
  expect(container.querySelector(".uis-facts")?.textContent).toContain("UA 857");
  await click(button(container, "Approve"));
  await click(container.querySelector("[data-uis-confirm]")!);
  expect(calls.map(([kind]) => kind)).toEqual(["action", "confirm"]);
  expect(container.querySelector(".uis-answer")?.textContent).toContain("Approved");
  expect(button(container, "Approve")).toBeUndefined();
});

test("a streaming surface locks its controls and says it is still drawing", async () => {
  const surface: UiSurface = { ...travelerForm, status: "streaming" };
  const container = await render(<UiSurfaceCard surface={surface} client={recordingClient([])} />);
  expect(container.querySelector("section")?.getAttribute("aria-busy")).toBe("true");
  expect(button(container, "Save traveller").disabled).toBe(true);
  expect(container.querySelector('[role="status"]')).not.toBeNull();
});

test("with Labs off a tool row's surface draws nothing; on, it draws", async () => {
  const row = {
    id: "r1",
    version: 1,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "get-time",
        tool: { id: "c1", title: "get-time", status: "completed", uiSurface: approvalFull },
      },
    ],
  } as unknown as AcpmuxRow;
  setAgentUiSurfaces(false);
  const container = await render(<ToolUiSurfaces row={row} />);
  expect(container.querySelector(".uis-card")).toBeNull();
  expect(container.innerHTML).toBe("");
  await act(async () => setAgentUiSurfaces(true));
  expect(container.querySelector(".uis-card")).not.toBeNull();
});

test("the reader refuses what is not a surface and caps what it reads", () => {
  expect(readUiSurface({ schema: "cmux.ui-surface/2", surfaceId: "x" })).toBeUndefined();
  expect(readUiSurface("<html>")).toBeUndefined();
  const rows = Array.from({ length: 250 }, (_, index) => [String(index)]);
  const surface = readUiSurface({
    schema: "cmux.ui-surface/1",
    surfaceId: "t",
    root: { id: "t", type: "table", columns: [{ key: "n", label: "n" }], rows },
  });
  expect(surface?.root?.type === "table" && surface.root.rows.length).toBe(200);
  expect(surface?.root?.type === "table" && surface.root.truncated).toBe(true);
});

test("the MCP App bridge forwards everything and posts host notifications only after initialized", async () => {
  const posted: unknown[] = [];
  const forwarded: unknown[] = [];
  const answers: Record<string, unknown> = {
    "ui/initialize": {
      reply: { jsonrpc: "2.0", id: 1, result: { protocolVersion: "x" } },
      notify: [{ jsonrpc: "2.0", method: "ui/notifications/tool-input", params: {} }],
    },
    "ui/notifications/initialized": {
      notify: [{ jsonrpc: "2.0", method: "ui/notifications/tool-result", params: {} }],
    },
    "tools/call": { blocked: "tools/call refused" },
  };
  const blocked: string[] = [];
  const bridge = createFrameBridge({
    forward: async (message) => {
      forwarded.push(message);
      return answers[(message as { method: string }).method];
    },
    post: (message) => posted.push(message),
    onHeight: () => {},
    onBlocked: (reason) => blocked.push(reason),
  });
  bridge.receive({ jsonrpc: "2.0", id: 1, method: "ui/initialize" });
  bridge.receive({ not: "json-rpc" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  // The reply to the view's own request goes; the host's tool-input waits for initialized.
  expect(posted).toEqual([{ jsonrpc: "2.0", id: 1, result: { protocolVersion: "x" } }]);
  bridge.receive({ jsonrpc: "2.0", method: "ui/notifications/initialized" });
  bridge.receive({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rm" } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(posted.slice(1)).toEqual([
    { jsonrpc: "2.0", method: "ui/notifications/tool-input", params: {} },
    { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: {} },
  ]);
  expect(forwarded).toHaveLength(3);
  expect(blocked).toEqual(["tools/call refused"]);
  expect(framedHtml("<p>x</p>", `default-src 'none'; "x"`)).toBe(
    `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; &quot;x&quot;"><p>x</p>`,
  );
});

// One render per test: each installs its own DOM, restored in afterEach.
for (const [openUrl, opened] of [
  ["https://example.com/book", true],
  ["javascript:alert(1)", false],
] as const) {
  test(`a confirmed link opens only an https URL acpmux returned (${openUrl})`, async () => {
    const calls: Call[] = [];
    const container = await render(
      <UiSurfaceCard surface={approvalFull} client={recordingClient(calls, { sent: "link", openUrl })} />,
    );
    await click(button(container, "Approve"));
    await click(container.querySelector("[data-uis-confirm]")!);
    expect(calls.filter(([kind]) => kind === "open")).toEqual(opened ? [["open", { url: openUrl }]] : []);
  });
}

test("the bridge hands a view's Pending and draft to the card, never sending them itself", async () => {
  const pendings: unknown[] = [];
  const drafts: string[] = [];
  const posted: unknown[] = [];
  const bridge = createFrameBridge({
    forward: async () => ({
      pending: { requestId: "r1", actionId: "ui/message", summary: "Send to the agent", sends: [], target: "agent" },
      draft: "Book the 9:40",
    }),
    post: (message) => posted.push(message),
    onHeight: () => {},
    onBlocked: () => {},
    host: { onPending: (pending) => pendings.push(pending), onDraft: (text) => drafts.push(text) },
  });
  bridge.receive({ jsonrpc: "2.0", id: 3, method: "ui/message", params: {} });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(pendings).toHaveLength(1);
  expect((pendings[0] as { requestId: string }).requestId).toBe("r1");
  expect(drafts).toEqual(["Book the 9:40"]);
  expect(posted).toEqual([]);
});
