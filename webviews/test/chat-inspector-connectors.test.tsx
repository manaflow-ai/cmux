// l10n-allow-file: test fixture server names, not shipped UI.
// The Inspector's Connectors: a failed MCP server's row has a Reconnect where acpmux reconnects one
// (`_acpmux/mcp/reconnect`, a Claude Code chat's), which asks for that server, reads Reconnecting…
// while it waits and Try again after an error. Without it, "Needs reconnect" is plain text: no
// button, nothing that looks clickable.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import { ChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import { DEFAULT_SECTIONS, resetInspectorState } from "../src/agent-session/acpmux/inspector/inspectorState";
import { chat } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => resetInspectorState());

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const base = chat([]);
const summary = {
  ...base.summary!,
  mcpServers: [
    { name: "github", status: "connected" as const },
    { name: "linear", status: "failed" as const },
  ],
};

async function show(
  container: HTMLElement,
  onReconnectMcp?: (server: string) => Promise<unknown>,
  servers = summary.mcpServers,
) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <ChatInspector
        summary={{ ...summary, mcpServers: servers }}
        sections={{ ...DEFAULT_SECTIONS, connectors: true }}
        onSection={() => undefined}
        onReconnectMcp={onReconnectMcp}
      />,
    );
  });
  return container.querySelector<HTMLElement>('section[data-section="connectors"]')!;
}

const reconnectButtons = (connectors: HTMLElement) => [
  ...connectors.querySelectorAll<HTMLButtonElement>(".acpmux-chat-inspector-row button"),
];

test("connector rows use the Environment row icon slot", async () => {
  const container = installDom();
  const connectors = await show(container);
  const environmentIcon = container.querySelector<SVGElement>(
    '[data-section="environment"] .acpmux-chat-inspector-row > svg',
  );
  const connectorIcon = connectors.querySelector<SVGElement>(".acpmux-chat-inspector-row > svg");
  expect(environmentIcon?.getAttribute("width")).toBe("14");
  expect(connectorIcon?.getAttribute("width")).toBe(environmentIcon?.getAttribute("width"));
  expect(connectorIcon?.getAttribute("height")).toBe(environmentIcon?.getAttribute("height"));
});

test("a failed server's Reconnect asks for that server, waits, and offers Try again after an error", async () => {
  const container = installDom();
  const asked: string[] = [];
  let answer: { resolve: () => void; reject: () => void } | undefined;
  const connectors = await show(container, (server) => {
    asked.push(server);
    return new Promise<void>((resolve, reject) => {
      answer = { resolve, reject };
    });
  });
  // Only the failed server has one.
  const buttons = reconnectButtons(connectors);
  expect(buttons.map((button) => button.textContent)).toEqual([translate("chatInspector.connectors.reconnectAction")]);
  expect(buttons[0]!.closest("li")!.textContent?.startsWith("linear")).toBe(true);

  await act(async () => buttons[0]!.click());
  expect(asked).toEqual(["linear"]);
  expect(buttons[0]!.textContent).toBe(translate("chatInspector.connectors.reconnecting"));
  expect(buttons[0]!.disabled).toBe(true);

  await act(async () => answer!.reject());
  expect(buttons[0]!.textContent).toBe(translate("chatInspector.connectors.retry"));
  expect(buttons[0]!.disabled).toBe(false);
  expect(buttons[0]!.dataset.state).toBe("failed");

  // Try again asks again; once acpmux marks the server connected, the row says so instead.
  await act(async () => buttons[0]!.click());
  expect(asked).toEqual(["linear", "linear"]);
  await act(async () => answer!.resolve());
  expect(buttons[0]!.textContent).toBe(translate("chatInspector.connectors.reconnectAction"));
  const after = await show(container, () => Promise.resolve(), [
    { name: "github", status: "connected" as const },
    { name: "linear", status: "connected" as const },
  ]);
  expect(reconnectButtons(after)).toEqual([]);
  const linear = [...after.querySelectorAll("li")].find((row) => row.textContent?.startsWith("linear"))!;
  const state = linear.querySelector<HTMLElement>(".acpmux-chat-inspector-row__end")!;
  expect(state.tagName).toBe("SPAN");
  expect(state.textContent).toBe(translate("composer.envConnected"));
});

test("where acpmux reconnects nothing, a failed server's state is plain text, not a button", async () => {
  const container = installDom();
  const connectors = await show(container);
  expect(reconnectButtons(connectors)).toEqual([]);
  const failed = connectors.querySelector<HTMLElement>('.acpmux-chat-inspector-row__end[data-state="failed"]')!;
  expect(failed.tagName).toBe("SPAN");
  expect(failed.textContent).toBe(translate("chatInspector.connectors.needsReconnect"));
});
