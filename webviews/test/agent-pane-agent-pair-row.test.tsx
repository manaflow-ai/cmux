// l10n-allow-file: test fixture chat names, not shipped UI.
// The paused agent pair row in the real transcript (App.tsx's AgentPairRow): its Resume goes
// through the page's `chat.agentPair.resume` action, which the pane wires to the direct client, and
// reaches acpmux as `_acpmux/agent_pair_resume` for the chat on screen. A double click sends one.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { CHAT, PEER, connect, fakeDaemon, held, pairRows, paused, record } from "./support/agentPairDaemon";

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

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { translate } = await import("../src/agent-session/acpmux/i18n");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("Resume on the transcript row sends agent_pair_resume once, through chat.agentPair.resume", async () => {
  const daemon = fakeDaemon(record([paused(), held("p-9", "again")]));
  const { client, rows } = await connect(daemon);
  const actions: string[] = [];
  (dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => unknown> }).cmuxAcpmuxActions = {
    "chat.agentPair.resume": ({ peer }) => {
      actions.push(String(peer));
      return client.resumeAgentPair(String(peer));
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={pairRows(rows())} onToggleActivity={() => {}} expanded={new Set()} />),
    );
    const resume = [...dom.window.document.querySelectorAll("button")].find(
      (button) => button.textContent === translate("agentPair.resume"),
    )!;
    expect(resume).toBeDefined();
    await act(async () => {
      resume.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      resume.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(actions).toEqual([PEER]);
    expect(daemon.resumes().map((request) => request.params)).toEqual([{ sessionId: CHAT, peerSessionId: PEER }]);
  } finally {
    await act(async () => root.unmount());
  }
});
