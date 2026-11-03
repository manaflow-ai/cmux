// l10n-allow-file: test fixture subagent names, not shipped UI.
// A running subagent or Claude workflow shows its live numbers in the transcript, as Claude's task
// panel does (Lawrence 2026-10-14): what it does now, a workflow's agents done of started, its
// tokens and tool uses. acpmux sends them as `subagent_progress` in the subagent model
// (cmux-tui/crates/acpmux/src/claude_stdio/workflows.rs); the real fold and transcript draw them.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", {
  configurable: true,
  get: () => 10_000,
});
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => 760,
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SubagentFold } = await import("../src/agent-session/acpmux/subagents/subagentFold");
const { SubagentPaneContext, SubagentStopContext } =
  await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { withSubagentRows } = await import("../src/agent-session/acpmux/subagents/subagentRows");

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const START = Date.UTC(2026, 9, 14, 9, 0, 0);
let seq = 0;
function feed(fold: InstanceType<typeof SubagentFold>, update: Record<string, unknown>, subagents: unknown[]) {
  seq += 1;
  const msg = { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } };
  fold.reduce({ seq, at: START + seq * 1000, msg }, update);
}

/// The open group's subagent rows, as text per row: name, state line.
async function openRows(fold: InstanceType<typeof SubagentFold>): Promise<string[][]> {
  const groups = fold.takeRows();
  const rows = withSubagentRows(groups, new Set(groups.map((row) => row.id)));
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />),
    );
    return [...dom.window.document.querySelectorAll(".cv-subagent")].map((row) => [
      row.querySelector(".cv-subagent__name")!.textContent!,
      row.querySelector(".cv-subagent__state")!.textContent!,
    ]);
  } finally {
    await act(async () => root.unmount());
  }
}

test("a running workflow and a background agent show what they do and what they have spent", async () => {
  setPaneLanguage("en");
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, [
    {
      id: "w",
      parent: null,
      name: "Workflow",
      task: "Workflow",
      kind: "workflow",
      state: "running",
    },
  ]);
  feed(fold, { sessionUpdate: "subagent_spawned" }, [
    { id: "a", parent: null, name: "Watch the build", kind: "general-purpose", state: "running" },
  ]);
  feed(fold, { sessionUpdate: "subagent_progress" }, [
    {
      id: "w",
      parent: null,
      state: "running",
      name: "probe",
      task: "Two tiny agents",
      tokens: 19738,
      toolUses: 0,
      elapsedMs: 3212,
      action: "Count: n2",
      agents: { done: 1, started: 3 },
    },
  ]);
  feed(fold, { sessionUpdate: "subagent_progress" }, [
    {
      id: "a",
      parent: null,
      state: "running",
      tokens: 38_300,
      toolUses: 1,
      elapsedMs: 84_000,
      action: "Bash",
    },
  ]);
  expect(await openRows(fold)).toEqual([
    // No kind subtitle beside the name (design/chat-transcript.md "Subagent row anatomy") and no tokens
    // or tool uses (Leo, 2026-10-31: "we can remove the symbols and the tokens").
    ["probe", "Count: n2 · 1/3 agents"],
    ["Watch the build", "Bash"],
  ]);
});

test("a running subagent has a stop button; an ended one has none", async () => {
  setPaneLanguage("en");
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, [
    { id: "w", parent: null, name: "probe", kind: "workflow", state: "running" },
  ]);
  feed(fold, { sessionUpdate: "subagent_spawned" }, [
    { id: "a", parent: null, name: "Watch the build", state: "running" },
  ]);
  feed(fold, { sessionUpdate: "subagent_state_update" }, [
    { id: "a", parent: null, name: "Watch the build", state: "completed" },
  ]);
  const groups = fold.takeRows();
  const rows = withSubagentRows(groups, new Set(groups.map((row) => row.id)));
  const stopped: string[] = [];
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <SubagentStopContext.Provider value={async (id) => void stopped.push(id)}>
          <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />
        </SubagentStopContext.Provider>,
      ),
    );
    const stops = [...dom.window.document.querySelectorAll<HTMLButtonElement>(".cv-subagent__stop")];
    expect(stops.map((stop) => stop.getAttribute("aria-label"))).toEqual(["Stop probe"]);
    await act(async () => stops[0]!.click());
    expect(stopped).toEqual(["w"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("stopping a subagent leaves its row closed; a refused stop says so and can be tried again", async () => {
  setPaneLanguage("en");
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, [
    { id: "w", parent: null, name: "probe", kind: "workflow", state: "running" },
  ]);
  const groups = fold.takeRows();
  const rows = withSubagentRows(groups, new Set(groups.map((row) => row.id)));
  const opened: string[] = [];
  const answers: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];
  const stop = (_id: string) => new Promise<void>((resolve, reject) => answers.push({ resolve, reject }));
  const root = createRoot(dom.window.document.getElementById("root")!);
  const button = () => dom.window.document.querySelector<HTMLButtonElement>(".cv-subagent__stop")!;
  try {
    await act(async () =>
      root.render(
        <SubagentPaneContext.Provider value={(id) => void opened.push(id)}>
          <SubagentStopContext.Provider value={stop}>
            <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />
          </SubagentStopContext.Provider>
        </SubagentPaneContext.Provider>,
      ),
    );
    await act(async () => button().click());
    expect(opened).toEqual([]);
    expect(answers.length).toBe(1);
    // While Claude has not answered, another click sends nothing.
    expect(button().disabled).toBe(true);
    await act(async () => button().click());
    expect(answers.length).toBe(1);
    await act(async () => answers[0]!.reject(new Error("no running subagent w")));
    expect([button().disabled, button().getAttribute("aria-label")]).toEqual([false, "Couldn’t stop probe"]);
    await act(async () => button().click());
    expect(answers.length).toBe(2);
    expect(opened).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});
