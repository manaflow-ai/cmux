// Leo, 2026-10-22, on Session Info's Subagents hover card: "this flashes sometimes". The card is
// a glass card that wraps its lines (name, then state · time · what it does now, then its task) at
// its own max width. The escape past the window's edge (ui/popupHost.ts) measured it as one
// unwrapped line, so a running subagent whose current command is long (a shell line, a git
// pipeline) read wider than the pane: the page card went invisible and the native panel showed a
// flattened one-line copy instead, re-placed on every one-second tick of its elapsed time, and
// whether it escaped changed as the command changed. A hover card wraps; it never leaves the page
// for being long.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { PopupHost, PopupModel } from "../src/ui/popupHost";

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
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  innerWidth: 900,
  innerHeight: 800,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Event)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window, "innerWidth", { configurable: true, value: 900 });
Object.defineProperty(dom.window, "innerHeight", { configurable: true, value: 800 });

// Layout jsdom lacks: a line of text is 7px a character, the way the escape's one-line probe
// (`width: max-content`, no wrap) measures it; everything else sits mid-pane.
const proto = dom.window.HTMLElement.prototype;
proto.getBoundingClientRect = function (this: HTMLElement) {
  const oneLine = this.style.width === "max-content";
  const width = oneLine ? (this.textContent ?? "").length * 7 : 200;
  return { left: 100, top: 400, right: 100 + width, bottom: 420, width, height: 20, x: 100, y: 400, toJSON() {} };
} as never;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UiProvider } = await import("../src/ui/UiProvider");
const { AgentProgressContext, AgentProgressStore } =
  await import("../src/agent-session/acpmux/subagents/agentProgressStore");
const { SubagentsSection } = await import("../src/agent-session/acpmux/session-info/SubagentsSection");

const shown: PopupModel[] = [];
const host: PopupHost = {
  show: async (model) => {
    shown.push(model);
    return { shown: true };
  },
  update: () => {},
  hide: () => {},
  owner: () => null,
  listen: () => () => {},
};

const container = dom.window.document.getElementById("root")!;
const root = createRoot(container);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// Yields until `ready` holds (the tooltip's open delay passes on the real clock), or gives up.
async function until(ready: () => boolean): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!ready() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 0));
}
const frame = () => new Promise((resolve) => dom.window.requestAnimationFrame(resolve));

test("a running subagent's hover card with a long command stays in the page", async () => {
  const agent = {
    id: "01a16656-bb2d-7513-b459-4a893451d37a",
    parent: null,
    name: "needs_you_prior_art",
    task: "needs_you_prior_art",
    state: "running",
    startedAt: Date.now() - 21 * 60_000,
    background: true,
    tokens: 1000,
    agents: { started: 3, done: 0 },
    action:
      "'for c in 61c13a741f0 e5ece9e0dc7; do echo \"### $c refs\"; git for-each-ref --contains=$c --format='\"'%(refname)' | head -50; done",
  };
  const progress = new AgentProgressStore([agent]);
  await act(async () =>
    root.render(
      <UiProvider container={container} popupHost={host}>
        <AgentProgressContext.Provider value={progress}>
          <SubagentsSection agents={[agent]} waiting={new Set()} onOpen={() => {}} />
        </AgentProgressContext.Provider>
      </UiProvider>,
    ),
  );
  const line = container.querySelector<HTMLElement>(".acpmux-agent-line__button")!;
  expect(line).toBeTruthy();
  await act(async () => {
    // React's enter handlers come from the over events.
    for (const type of ["pointerover", "pointerenter", "pointermove"])
      line.dispatchEvent(new dom.window.PointerEvent(type, { bubbles: true, pointerType: "mouse" }));
    for (const type of ["mouseover", "mouseenter", "mousemove"])
      line.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true }));
    await until(() => container.querySelector(".acpmux-agent-card__popup") !== null);
  });
  const card = container.querySelector<HTMLElement>(".acpmux-agent-card__popup");
  expect(card?.textContent).toContain("needs_you_prior_art");
  // No subagent list says tokens (the Inspector's Context does); the counts are what updates.
  expect(card?.textContent).toContain("0/3 agents");
  expect(card?.textContent).not.toContain("tokens");
  // The parent keeps its structural agent object: both mounted surfaces subscribe to usage.
  await act(async () => progress.updateProgress(agent.id, { tokens: 42000, agents: { started: 3, done: 1 } }));
  expect(line.querySelector(".acpmux-agent-line__progress")?.textContent).toBe("1/3 agents");
  expect(card?.textContent).toContain("1/3 agents");
  expect(card?.textContent).not.toContain("0/3 agents");
  // The escape measures a frame after the card is placed.
  await act(async () => {
    await frame();
    await frame();
  });
  expect(shown).toEqual([]);
  expect(card!.parentElement!.hasAttribute("data-escaped")).toBe(false);
  expect(card!.parentElement!.style.opacity).toBe("");
});

test("a plain one-line tooltip wider than the pane still goes past the window's edge", async () => {
  shown.length = 0;
  const { Tooltip } = await import("../src/ui/Tooltip");
  const label = "x".repeat(200);
  await act(async () =>
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Tooltip label={label}>
          <button type="button" className="plain-trigger">
            ?
          </button>
        </Tooltip>
      </UiProvider>,
    ),
  );
  const trigger = container.querySelector<HTMLElement>(".plain-trigger")!;
  await act(async () => {
    for (const type of ["pointerover", "pointerenter", "pointermove"])
      trigger.dispatchEvent(new dom.window.PointerEvent(type, { bubbles: true, pointerType: "mouse" }));
    for (const type of ["mouseover", "mouseenter", "mousemove"])
      trigger.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true }));
    await until(() => shown.length > 0);
  });
  expect(shown.map((model) => model.items[0]?.label)).toEqual([label]);
});
