// l10n-allow-file: regression fixture text, not shipped UI.
// Opening a subagent shows its result first (Leo, 2026-11-04: "Put status, duration and its final
// report above its transcript, the way ChatGPT does."): the child view draws its result head (state,
// time, final report) under its pill and above its transcript, and an ended one opens on its top.
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
const { childView, SUBAGENT_RESULT, subagentReport } =
  await import("../src/agent-session/acpmux/subagents/subagentRows");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const START = 1_000;
const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "worker",
  parent: null,
  name: "Explore",
  task: "Find the reconnect race",
  state: "completed",
  startedAt: START,
  endedAt: START + 134_000,
  result: "The retry timer is armed before the old socket closes.",
  ...fields,
});
const group = (worker: Subagent): AcpmuxRow => ({
  id: "group",
  kind: SUBAGENTS,
  version: 1,
  at: START,
  subagents: [worker],
});
const transcript: AcpmuxRow[] = [
  { id: "prompt", kind: "user", version: 1, at: START, text: "Find why reconnect fires twice." },
  { id: "reply", kind: "assistant", version: 1, at: START + 90_000, text: "Transcript reply text." },
];

async function draw(worker: Subagent, rows: AcpmuxRow[] = transcript) {
  const view = childView("worker", [group(worker)], { worker: rows }, new Set(), "Release review")!;
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(<VirtualTranscript rows={view} onToggleActivity={() => {}} expanded={new Set()} />),
  );
  return { root, view };
}

test("the child view puts the result head between its pill and its transcript", () => {
  const view = childView("worker", [group(agent())], { worker: transcript }, new Set(), "Release review")!;
  expect(view.map((row) => row.kind)).toEqual(["subagentOf", SUBAGENT_RESULT, "user", "assistant"]);
  const empty = childView("worker", [group(agent())], {}, new Set(), "Release review")!;
  expect(empty.map((row) => row.kind)).toEqual(["subagentOf", SUBAGENT_RESULT, "subagentEmpty"]);
});

test("the head's version moves when what it draws changes", () => {
  const version = (worker: Subagent) =>
    childView("worker", [group(worker)], {}, new Set(), "Release review")!.find((row) => row.kind === SUBAGENT_RESULT)!
      .version;
  const running = version(agent({ state: "running", endedAt: undefined, result: undefined }));
  expect(version(agent())).not.toBe(running);
  expect(version(agent({ result: "Another report." }))).not.toBe(version(agent()));
  expect(version(agent())).toBe(version(agent()));
});

test("the report is the result, else the last message, else the failure; none while it runs", () => {
  expect(subagentReport(agent())).toBe("The retry timer is armed before the old socket closes.");
  expect(subagentReport(agent({ result: undefined, lastMessage: "Last thing said." }))).toBe("Last thing said.");
  expect(subagentReport(agent({ state: "failed", result: undefined, error: "API error." }))).toBe("API error.");
  expect(subagentReport(agent({ state: "running", endedAt: undefined }))).toBeUndefined();
});

test("a finished subagent shows Done, its duration and its report above the transcript", async () => {
  const { root } = await draw(agent());
  try {
    const head = document.querySelector<HTMLElement>(".cv-subagent-result")!;
    expect(head).not.toBeNull();
    expect(head.dataset.state).toBe("completed");
    expect(head.querySelector(".cv-subagent-result__status")?.textContent).toBe("Done · 2m 14s");
    expect(head.querySelector(".cv-subagent-result__report")?.textContent).toContain(
      "The retry timer is armed before the old socket closes.",
    );
    expect(head.querySelector("button[aria-label='Copy'], button[title='Copy']")).not.toBeNull();
    // Above the transcript: the head comes before the transcript's reply in document order.
    const reply = [...document.querySelectorAll("*")].find((node) => node.textContent === "Transcript reply text.")!;
    expect(head.compareDocumentPosition(reply) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    // The report is cut until Show more (collapsible when long).
    expect(head.querySelector(".cv-subagent-result__report")?.hasAttribute("data-cut")).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a failed subagent says Failed with its error, the red on the mark only", async () => {
  const { root } = await draw(
    agent({ state: "failed", endedAt: START + 41_000, result: undefined, error: "API error." }),
  );
  try {
    const head = document.querySelector<HTMLElement>(".cv-subagent-result")!;
    expect(head.dataset.state).toBe("failed");
    expect(head.querySelector(".cv-subagent-result__status")?.textContent).toBe("Failed · 41s");
    expect(head.querySelector(".cv-subagent-result__report")?.textContent).toContain("API error.");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a running subagent shows the spinner and its elapsed time, and no report", async () => {
  const { root } = await draw(agent({ state: "running", endedAt: undefined, result: undefined }));
  try {
    const head = document.querySelector<HTMLElement>(".cv-subagent-result")!;
    expect(head.dataset.state).toBe("running");
    expect(head.querySelector(".cv-subagent-result__state")?.textContent).toBe("Running");
    expect(head.querySelector(".cv-subagent-result__report")).toBeNull();
    // The working state is a spinner, never a dot.
    expect(head.querySelector(".cv-subagent-result__mark")?.children.length).toBe(1);
  } finally {
    await act(async () => root.unmount());
  }
});
