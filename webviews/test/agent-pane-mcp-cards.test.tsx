// l10n-allow-file: test fixture server names and reasons, not shipped UI.
// An agent's MCP connect card and its call card show in the real chat page (cmux#mcp-connect 3b):
// the whole AcpmuxApp gets a snapshot with `mcpConnect` or `mcpCall`, and the bottom ask area
// draws the card. The cards' own tests (McpConnectCard.test.tsx) render the card alone, which is
// how a chat that never drew either card passed them: the bottom ask area did not name them.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Event: dom.window.Event,
  KeyboardEvent: dom.window.KeyboardEvent,
  MouseEvent: dom.window.MouseEvent,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
(dom.window as unknown as { matchMedia: unknown }).matchMedia = replacements.matchMedia;
// jsdom has no layout. A tall viewport mounts every row of this small chat.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const fixtures = await import("../src/gallery/fixtures/acpmux");
const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const receive = (value: unknown) =>
  (dom.window as unknown as { cmuxAcpmuxBridge?: { receive(value: unknown): void } }).cmuxAcpmuxBridge?.receive(value);

const connectAsk = {
  requestId: "r-connect-1",
  title: "DeepWiki",
  publisher: "deepwiki.com",
  verified: true,
  target: "https://mcp.deepwiki.com/mcp",
  auth: "none",
  reason: "Read the docs of a GitHub repo for you",
  proposedScope: "chat" as const,
  phase: "ask" as const,
};
const callAsk = {
  requestId: "r-call-1",
  title: "Linear",
  tool: "create_issue",
  kind: "write",
  arguments: '{"title":"Fix the login page"}',
};

test("the chat page draws the MCP connect card, then the call card, and neither once they are answered", async () => {
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: { method?: string }) {
          if (message.method === "ready")
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const rows = [fixtures.user("Connect the DeepWiki MCP server", 1)];
  const root = createRoot(dom.window.document.getElementById("root")!);
  const card = () => dom.window.document.querySelector(".acpmux-mcp-card");
  const callCard = () => dom.window.document.querySelector(".acpmux-mcp-call-card");
  try {
    await act(async () => root.render(<AcpmuxApp />));

    await act(async () => receive(fixtures.chat(rows, { mcpConnect: connectAsk })));
    expect(card()).not.toBeNull();
    // The person sees the exact address and the agent's reason, and has a Connect button.
    expect(card()!.textContent).toContain("https://mcp.deepwiki.com/mcp");
    expect(card()!.textContent).toContain("Read the docs of a GitHub repo for you");
    expect(card()!.querySelectorAll("button.acpmux-secret-card-action").length).toBeGreaterThan(0);

    await act(async () => receive(fixtures.chat(rows, { mcpCall: callAsk })));
    expect(card()).toBeNull();
    expect(callCard()).not.toBeNull();
    expect(callCard()!.textContent).toContain("create_issue");
    expect(callCard()!.textContent).toContain("Fix the login page");

    await act(async () => receive(fixtures.chat(rows)));
    expect(card()).toBeNull();
    expect(callCard()).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});
