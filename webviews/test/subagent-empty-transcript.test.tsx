// l10n-allow-file: regression fixture text, not shipped UI.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SUBAGENTS } = await import("../src/agent-session/acpmux/subagents/subagentFold");
const { childView } = await import("../src/agent-session/acpmux/subagents/subagentRows");
const { SubagentNavContext } = await import("../src/agent-session/acpmux/subagents/SubagentGroup");

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const group: AcpmuxRow = {
  id: "group",
  kind: SUBAGENTS,
  version: 1,
  at: 1,
  subagents: [{ id: "reviewer", parent: null, name: "Reviewer", state: "completed", startedAt: 1 }],
};
const reply: AcpmuxRow = { id: "reply", kind: "assistant", version: 1, at: 2, text: "The review is complete." };

test("an empty known child's transcript explains itself and keeps parent navigation", async () => {
  const root = createRoot(document.getElementById("root")!);
  const opened: (string | undefined)[] = [];
  const draw = async (views: Record<string, AcpmuxRow[]> | undefined) => {
    const rows = childView("reviewer", [group], views, new Set(), "Release review")!;
    await act(async () =>
      root.render(
        <SubagentNavContext.Provider value={(id) => opened.push(id)}>
          <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />
        </SubagentNavContext.Provider>,
      ),
    );
  };
  try {
    await draw(undefined);
    expect(document.querySelector("h3")?.textContent).toBe("No messages yet");
    expect(document.body.textContent).toContain("Messages and tool calls from this agent appear here.");
    expect(document.querySelector("[aria-busy=true]")).toBeNull();
    await act(async () => (document.querySelector(".cv-subagent-of__pill") as HTMLElement).click());
    expect(opened).toEqual([undefined]);
    await draw({ reviewer: [] });
    expect(document.querySelector("h3")?.textContent).toBe("No messages yet");
    await draw({ reviewer: [reply] });
    expect(document.body.textContent).toContain("The review is complete.");
    expect(document.body.textContent).not.toContain("No messages yet");
    expect(document.querySelector(".cv-subagent-of__parent")?.textContent).toBe("Release review");
  } finally {
    await act(async () => root.unmount());
  }
});

test("an unknown child remains unresolved rather than showing an empty transcript", () => {
  expect(childView("missing", [group], {}, new Set(), "Release review")).toBeUndefined();
});
