// l10n-allow-file: test fixture subagent names, not shipped UI.
// A batch of subagents says how many there are and what is still going in one phrase, in the
// pane language's plural forms (Leo 2026-10-13): "1 subagent running", "2 subagents, 1 running".
// Before: "1 subagents" over "1 running", the noun always plural and the count said twice.
// The real transcript renders the group row, in English and in Russian (one, few and many forms).
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

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const START = Date.UTC(2026, 9, 13, 19, 0, 0);
/// The group row's line for subagents in `states`, in `language`.
async function label(states: string[], language = "en"): Promise<string> {
  setPaneLanguage(language);
  const agents = states.map((state, index) => ({
    id: `agent-${index}`,
    parent: null,
    name: `Agent ${index}`,
    state,
    startedAt: START,
    ...(state === "running" ? {} : { endedAt: START + 60_000 }),
  }));
  const rows = [{ id: "group", kind: SUBAGENTS, version: 1, at: START, subagents: agents } as AcpmuxRow];
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />),
    );
    return dom.window.document.querySelector(".cv-subagents__text")!.textContent!;
  } finally {
    await act(async () => root.unmount());
  }
}

test("one phrase says how many subagents there are and what is still going", async () => {
  expect(await label(["running"])).toBe("1 subagent running");
  expect(await label(["running", "running", "running"])).toBe("3 subagents running");
  expect(await label(["running", "completed"])).toBe("2 subagents, 1 running");
  expect(await label(["running", "failed", "completed"])).toBe("3 subagents, 1 running, 1 failed");
  expect(await label(["completed", "completed"])).toBe("2 subagents done");
  expect(await label(["completed", "failed"])).toBe("2 subagents, 1 failed, 1 done");
});

// A subagent the person stopped, or one acpmux lost, ended without its result: the phrase said
// nothing of it ("3 subagents, 1 done" for one done, one cancelled and one disconnected).
test("cancelled and disconnected subagents count as stopped", async () => {
  expect(await label(["completed", "cancelled", "disconnected"])).toBe("3 subagents, 2 stopped, 1 done");
  expect(await label(["cancelled", "cancelled"])).toBe("2 subagents, 2 stopped");
  expect(await label(["running", "cancelled"])).toBe("2 subagents, 1 running, 1 stopped");
});

test("the count takes the pane language's plural form", async () => {
  expect(await label(["running"], "ru")).toBe("1 субагент выполняется");
  expect(await label(["running", "running"], "ru")).toBe("2 субагента выполняются");
  expect(await label(Array(5).fill("running"), "ru")).toBe("5 субагентов выполняются");
  expect(await label(["completed", "completed"], "ja")).toBe("サブエージェント 2 件完了");
});
