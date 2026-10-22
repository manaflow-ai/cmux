// l10n-allow-file: test fixture page titles, not shipped UI.
// A render tool call's card in the real pane (AcpmuxApp on a stand-in for the app's pane bridge, as
// the gallery's agent pane host mounts it): Open shows the page in the side panel, as a
// ```cmux-render fence's card does (cx-ncc.94), and a call with no title reads the page's <title>.
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

const PAGE = "<title>Desk clamp</title><p>Jaw 3°</p>";

/// The pane with one ended turn whose render tool call passed `input`; the app's bridge answers
/// `ready` and then delivers the chat's snapshot, as the gallery's agent pane host does.
async function pane(input: Record<string, unknown>) {
  const { activity, assistant, chat, summary, tool, user } = fixtures;
  const rows = [
    user("Draw the clamp", 3, { id: "u1" }),
    activity(
      [tool("mcp__cmux__render", "other", "completed", { id: "toolu_1", inputSummary: JSON.stringify(input) })],
      2.9,
      { id: "a1" },
    ),
    assistant("Here is the clamp.", 2.8, { id: "r1" }),
    summary(2.8, { id: "s1", status: "completed", toolCount: 1 }),
  ];
  const snapshot = chat(rows);
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method?: string }) => {
          if (message.method === "ready") {
            setTimeout(
              () =>
                (
                  dom.window as unknown as { cmuxAcpmuxBridge?: { receive(value: unknown): void } }
                ).cmuxAcpmuxBridge?.receive(structuredClone(snapshot)),
              0,
            );
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          }
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<AcpmuxApp />));
  for (let tries = 0; tries < 500 && !dom.window.document.querySelector(".acpmux-render-card"); tries += 1)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return root;
}

const card = () => dom.window.document.querySelector(".acpmux-render-card");

test("Open on a render tool call's card shows its page in the side panel", async () => {
  const root = await pane({ html: PAGE, title: "Desk clamp" });
  try {
    expect(card()).not.toBeNull();
    const open = card()!.querySelector<HTMLButtonElement>('button[aria-label="Open preview"]');
    expect(open).not.toBeNull();
    // The pointer's whole press, as a person's click lands.
    for (const type of ["pointerdown", "mousedown", "focus", "pointerup", "mouseup", "click"])
      await act(async () => {
        if (type === "focus") open!.focus();
        else open!.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
      });
    const panel = dom.window.document.querySelector(".acpmux-artifact");
    expect(panel).not.toBeNull();
    expect(panel!.querySelector(".acpmux-artifact-title")?.textContent).toBe("Desk clamp");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a render tool call with no title names its card by the page's <title>", async () => {
  const root = await pane({ html: PAGE });
  try {
    expect(card()?.querySelector(".acpmux-render-card-title")?.textContent).toBe("Desk clamp");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a render tool card's row has no row Copy over the card's Open; a prompt's one Copy is under its bubble", async () => {
  const root = await pane({ html: PAGE, title: "Desk clamp" });
  try {
    const document = dom.window.document;
    // The row's Copy sits at the row's top right, where a render row's card has its Open.
    expect(document.querySelector("article.acpmux-render")).not.toBeNull();
    expect(document.querySelector("article.acpmux-render .acpmux-row__copy")).toBeNull();
    // A prompt has no floating row Copy either (it sat alone at the row's top left; Leo 2026-10-21).
    expect(document.querySelector("article.acpmux-user .acpmux-row__copy")).toBeNull();
    expect(document.querySelector('article.acpmux-user .cv-user__actions button[aria-label="Copy"]')).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});
