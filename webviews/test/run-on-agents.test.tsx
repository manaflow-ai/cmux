// l10n-allow-file: test fixtures, not shipped UI.
// Run on N agents (gaps-agent-workflow #8): one composer prompt on 2 to 4 agents, each in its own
// worktree, compared in the chat's builds card, where Keep this one removes the others' worktrees.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { PickerCatalog, PickerHarness } from "../src/agent-session/acpmux/modelCatalogData";
import { PlanBuildCard } from "../src/agent-session/acpmux/planBuild/PlanBuildCard";
import type { PlanBuild } from "../src/agent-session/acpmux/planBuild/planBuild";
import { RunOnAgentsPanel } from "../src/agent-session/acpmux/runOnAgents/RunOnAgentsPanel";
import type { RunVariant } from "../src/agent-session/acpmux/runOnAgents/runOnAgents";

const model = (id: string, shortName: string, efforts: string[] = []) =>
  ({ id, name: shortName, shortName, efforts, fast: false, searchText: id }) as PickerHarness["models"][number];
const harness = (id: string, name: string, models: PickerHarness["models"]): PickerHarness => ({
  id,
  name,
  brand: id,
  acpmuxHarness: id,
  installed: true,
  pickable: true,
  models,
});
const catalog: PickerCatalog = {
  provisional: false,
  harnesses: [
    harness("claude", "Claude", [
      model("claude-opus-5-5", "Opus 5.5", ["high"]),
      model("claude-sonnet-5-5", "Sonnet 5.5"),
    ]),
    harness("codex", "Codex", []),
    harness("opencode", "OpenCode", []),
  ],
};

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "PointerEvent",
  "KeyboardEvent",
  "FocusEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "DocumentFragment",
  "SVGElement",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    Node: w.Node,
    ShadowRoot: w.ShadowRoot,
    MouseEvent: w.MouseEvent,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    KeyboardEvent: w.KeyboardEvent,
    FocusEvent: w.FocusEvent,
    Event: w.Event,
    CustomEvent: w.CustomEvent,
    MutationObserver: w.MutationObserver,
    DocumentFragment: w.DocumentFragment,
    SVGElement: w.SVGElement,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function mount(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(node));
  return { host, root };
}
const click = async (el: Element) =>
  act(async () => {
    el.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });

test("Run on 3 agents: Claude Opus, Codex and Claude Sonnet, started with one press", async () => {
  const runs: RunVariant[][] = [];
  const { host, root } = await mount(
    <RunOnAgentsPanel
      catalog={catalog}
      prompt="Fix the flaky upload test"
      onRun={async (variants) => {
        runs.push(variants);
      }}
      onClose={() => undefined}
    />,
  );
  expect(host.querySelectorAll(".acpmux-run-on-row").length).toBe(3);
  const run = host.querySelector<HTMLButtonElement>(".acpmux-run-on-run")!;
  expect(run.textContent).toContain("Run on 3 agents");
  await click(run);
  expect(runs).toEqual([
    [
      { harness: "claude", model: "claude-opus-5-5" },
      { harness: "codex" },
      { harness: "claude", model: "claude-sonnet-5-5" },
    ],
  ]);
  act(() => root.unmount());
});

test("at most four agents and at least two; an empty prompt runs nothing", async () => {
  const runs: RunVariant[][] = [];
  const { host, root } = await mount(
    <RunOnAgentsPanel catalog={catalog} prompt="  " onRun={async (v) => void runs.push(v)} onClose={() => undefined} />,
  );
  const add = host.querySelector<HTMLButtonElement>(".acpmux-run-on-add")!;
  await click(add);
  expect(host.querySelectorAll(".acpmux-run-on-row").length).toBe(4);
  expect(add.disabled).toBe(true);
  const remove = () => [...host.querySelectorAll<HTMLButtonElement>(".acpmux-run-on-remove")];
  await click(remove()[0]!);
  await click(remove()[0]!);
  expect(host.querySelectorAll(".acpmux-run-on-row").length).toBe(2);
  expect(remove().every((b) => b.disabled)).toBe(true);
  const run = host.querySelector<HTMLButtonElement>(".acpmux-run-on-run")!;
  expect(run.disabled).toBe(true);
  expect(host.textContent).toContain("Type a prompt first");
  await click(run);
  expect(runs).toEqual([]);
  act(() => root.unmount());
});

test("a refused run keeps the panel and says why", async () => {
  let closed = false;
  const { host, root } = await mount(
    <RunOnAgentsPanel
      catalog={catalog}
      prompt="Fix it"
      onRun={async () => {
        throw new Error("width limit reached");
      }}
      onClose={() => {
        closed = true;
      }}
    />,
  );
  await click(host.querySelector(".acpmux-run-on-run")!);
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("width limit reached");
  expect(closed).toBe(false);
  act(() => root.unmount());
});

test("the runs card: Keep this one removes the others' worktrees", async () => {
  const build: PlanBuild = {
    buildId: "r1",
    target: "prompt",
    builds: [
      { sessionId: "a", harness: "claude", model: "claude-opus-5-5", state: "done" },
      { sessionId: "b", harness: "codex", state: "done" },
      { sessionId: "c", harness: "claude", model: "claude-sonnet-5-5", state: "done" },
    ],
    archived: [],
    turnsEnded: 3,
  };
  const diffs = {
    buildId: "r1",
    builds: build.builds.map((b) => ({ sessionId: b.sessionId, added: 3, removed: 1, files: [] })),
  };
  const kept: [string, boolean][] = [];
  const { host, root } = await mount(
    <PlanBuildCard
      build={build}
      sessionId="parent"
      onOpen={() => undefined}
      compare={async () => diffs}
      keep={async (_s, _b, keep, removeOthers) => {
        kept.push([keep, removeOthers]);
        return {
          ...diffs,
          keptSessionId: keep,
          removed: [
            { sessionId: "a", removed: true },
            { sessionId: "c", removed: true },
          ],
        };
      }}
    />,
  );
  expect(host.textContent).toContain("Same prompt on 3 agents");
  expect(host.textContent).toContain("Opus 5.5");
  expect(host.textContent).toContain("Sonnet 5.5");
  const keeps = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-plan-builds-keep")];
  expect(keeps.length).toBe(3);
  await click(keeps[1]!);
  expect(kept).toEqual([["b", true]]);
  expect(host.querySelectorAll('[data-outcome="removed"]').length).toBe(2);
  expect(host.querySelector('[data-outcome="kept"]')).not.toBeNull();
  act(() => root.unmount());
});
