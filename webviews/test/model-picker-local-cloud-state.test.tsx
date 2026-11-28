// l10n-allow-file: test fixtures.
// model-picker-local-cloud-state: This Mac and Cloud + Auto each keep their own model picker state (agent,
// model, level). A pick on one side never changes the other's, switching Runs On shows each side's own pick
// again, a level pick never changes the model, and the Cloud start sends exactly what the chips draw (one
// source for the chips and the send: cloudAgentPick.ts). The real New Tab chips and model menu, in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";
import { until } from "./support/until";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  (await import("../src/agent-session/acpmux/cloudAgentPick")).forgetCloudAgentPicksForTests();
  (await import("../src/agent-session/acpmux/cloudModePick")).clearCloudModePick();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.document.body.querySelectorAll(".ui-popup").forEach((node) => node.remove());
  dom.window.localStorage.clear();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Summary = NonNullable<Snapshot["summary"]>;
type Call = { method: string; params: Record<string, unknown> };

const FOLDER = "/home/dev/local-cloud-state";

async function catalog(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
}

/// A New Tab page on `harness` before its first send; `startsOnCloud`: Cloud is picked in Runs On.
async function newTab(startsOnCloud: boolean, harness: string): Promise<Snapshot> {
  return {
    type: "snapshot",
    protocolVersion: 1,
    origin: "local",
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: await catalog(),
    summary: { sessionId: "", harness, turnCount: 0, cwd: FOLDER } as Summary,
    ...(startsOnCloud ? { startsOnCloud: true } : {}),
  } as Snapshot;
}

const calls: Call[] = [];
async function render(snapshot: Snapshot) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    {
      get:
        (_target, method) =>
        async (params: Record<string, unknown> = {}) =>
          void calls.push({ method: String(method), params }),
    },
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <NewTabComposerChips snapshot={snapshot} cwd={FOLDER} />
      </QueryClientProvider>,
    ),
  );
  await settle();
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const chip = () => host.querySelector<HTMLElement>('[data-menu="Model"]')!;
const chipFace = () => `${chip().textContent ?? ""} ${chip().getAttribute("title") ?? ""}`;
const cols = () => doc().querySelector<HTMLElement>(".acpmux-cols");
const nameOf = (row: Element) => row.querySelector(".acpmux-cols-name")?.textContent ?? "";
const click = async (target: HTMLElement) => {
  await act(async () => target.click());
  await settle();
};

const chatCalls = () => calls.filter((call) => call.method.startsWith("chat."));
const menuRows = () => [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-row[role="option"]')];
const levelRow = (name: string) =>
  [...(cols()?.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]') ?? [])].find(
    (row) => nameOf(row) === name,
  );

async function openMenu() {
  if (!cols()) await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
}

async function closeMenu() {
  if (!cols()) return;
  await act(async () => {
    cols()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await settle();
}

/// Picks `model` on the `tab` harness tab of the open menu.
async function pickModel(tab: string, model: string) {
  await openMenu();
  const rail = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')].find(
    (candidate) => candidate.getAttribute("aria-label") === tab,
  );
  expect(rail, `the ${tab} tab`).toBeDefined();
  await click(rail!);
  const row = menuRows().find((candidate) => nameOf(candidate) === model);
  expect(row, `the ${model} row`).toBeDefined();
  await click(row!);
}

async function pickLevel(level: string) {
  await openMenu();
  await until(
    () => levelRow(level) !== undefined,
    () => settle(),
  );
  await click(levelRow(level)!);
}

/// The chips gone and drawn again with `snapshot` (Runs On switched, the page shown again).
async function redraw(snapshot: Snapshot) {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  doc()
    .body.querySelectorAll(".ui-popup")
    .forEach((node) => node.remove());
  await render(snapshot);
}

/// A new page of this launch: nothing held on it, Cloud's remembered pick kept (this run's store).
async function newPage() {
  const picks = await import("../src/agent-session/acpmux/cloudAgentPick");
  const stored = dom.window.localStorage.getItem("cmux.acpmux.cloudAgentPick.v1");
  picks.forgetCloudAgentPicksForTests();
  if (stored) dom.window.localStorage.setItem("cmux.acpmux.cloudAgentPick.v1", stored);
}

// Edge case 1: switching the reasoning level switched the model.
test("Cloud: a level picked after a model keeps that model, on the chip and in the start", async () => {
  calls.length = 0;
  const { cloudAgentPick, cloudStartPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  await render(await newTab(true, "claude"));
  await pickModel("Claude Code", "Sonnet 5.5");
  const model = cloudAgentPick()?.model;
  expect(model).toBe("claude-sonnet-5-5");
  for (const level of ["High", "Low", "Medium"]) {
    await pickLevel(level);
    expect(cloudAgentPick()).toEqual({ harness: "claude", model: model!, effort: level.toLowerCase() });
    expect(chipFace()).toContain("Sonnet 5.5");
    expect(chipFace()).toContain(level);
  }
  expect(cloudStartPick({ harness: "claude" })).toEqual({ harness: "claude", model: model!, effort: "medium" });
  expect(chatCalls()).toEqual([]);
});

test("This Mac: a level pick sends only the level, never another model or agent", async () => {
  calls.length = 0;
  const page = await newTab(false, "claude");
  await render({ ...page, summary: { ...page.summary!, model: "claude-opus-5-5" } as Summary });
  await pickLevel("High");
  expect(chatCalls().some((call) => call.method === "chat.effort" && call.params.value === "high")).toBe(true);
  expect(chatCalls().filter((call) => call.method === "chat.model")).toEqual([]);
  expect(
    chatCalls()
      .filter((call) => call.method === "chat.new")
      .map((call) => call.params.harness),
  ).not.toContain("codex");
  expect(chipFace()).toContain("Opus 5.5");
});

// Edge case 2: starting a Cloud chat suddenly changed the model provider.
test("Cloud start sends the agent, model and level the chips show, never This Mac's agent", async () => {
  calls.length = 0;
  const { cloudStartPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  const { cloudSendAgent } = await import("../src/agent-session/acpmux/cloudModePick");
  await render(await newTab(true, "claude"));
  await pickModel("Codex", "GPT-6.1 Sol");
  await pickLevel("High");
  await closeMenu();
  // This Mac's side still shows Claude: the start never falls back to it.
  const start = cloudStartPick({ harness: "claude", model: "claude-opus-5-5", family: "claude" });
  expect(start.harness).toBe("codex");
  expect(start.effort).toBe("high");
  expect(cloudSendAgent("codex", start.harness, start.model, true)).toMatchObject({ harness: "codex" });
  expect(chipFace()).toContain("GPT-6.1 Sol");
  expect(chipFace()).not.toContain("Opus");
  expect(chatCalls()).toEqual([]);
});

test("Cloud with nothing picked yet starts on the model the chip names, not the machine's own default", async () => {
  const { cloudStartPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  await render(await newTab(true, "codex"));
  const start = cloudStartPick({ harness: "codex" });
  expect(start.harness).toBe("codex");
  // A named model: the chip's, so the machine never picks its own.
  expect(start.model).toBeTruthy();
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const name = BUNDLED_MODEL_CATALOG.harnesses
    .find((entry) => entry.id === "codex")
    ?.models.find((model) => model.id === start.model)?.name;
  expect(name).toBeTruthy();
  expect(chipFace()).toContain(name!);
});

// Edge case 3: switching between This Mac and Cloud restores each side's own pick.
test("switching This Mac and Cloud shows each side's own pick again, both ways, and after a new page", async () => {
  calls.length = 0;
  const { cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  const local = await newTab(false, "claude");
  const localPicked = { ...local, summary: { ...local.summary!, model: "claude-opus-5-5" } as Summary };
  const cloud = { ...localPicked, startsOnCloud: true } as Snapshot;
  await render(localPicked);
  expect(chipFace()).toContain("Opus 5.5");
  // Cloud: Codex at High.
  await redraw(cloud);
  await pickModel("Codex", "GPT-6.1 Sol");
  await pickLevel("High");
  await closeMenu();
  expect(chipFace()).toContain("GPT-6.1 Sol");
  // Back to This Mac: its own Opus 5.5, never the Cloud pick.
  await redraw(localPicked);
  expect(chipFace()).toContain("Opus 5.5");
  expect(chipFace()).not.toContain("GPT-6.1 Sol");
  // A pick on This Mac leaves Cloud's.
  await pickLevel("Low");
  expect(cloudAgentPick()).toMatchObject({ harness: "codex", effort: "high" });
  // Cloud again: its own Codex at High.
  await redraw(cloud);
  expect(chipFace()).toContain("GPT-6.1 Sol");
  expect(chipFace()).toContain("High");
  // A new page (Cmd-T, a relaunch with the app's copy): Cloud's pick comes back.
  await newPage();
  await redraw(cloud);
  expect(chipFace()).toContain("GPT-6.1 Sol");
  expect(chipFace()).toContain("High");
  // No Cloud pick ever reached This Mac's chat.
  expect(chatCalls().filter((call) => call.method === "chat.new" && call.params.harness === "codex")).toEqual([]);
});

test("the app's copy of Cloud's pick seeds a page of a new launch; a pick made here wins over it", async () => {
  const picks = await import("../src/agent-session/acpmux/cloudAgentPick");
  picks.seedCloudAgentPick({ harness: "codex", model: "gpt-6.1-sol", effort: "low" });
  await render(await newTab(true, "claude"));
  expect(chipFace()).toContain("GPT-6.1 Sol");
  expect(chipFace()).toContain("Low");
  await pickLevel("High");
  picks.seedCloudAgentPick({ harness: "claude", model: "claude-opus-5-5" });
  expect(picks.rememberedCloudAgentPick()).toMatchObject({ harness: "codex", effort: "high" });
  // Sent to the app as Cloud's own pick, never as This Mac's.
  const remembered = calls.filter((call) => call.method === "newTab.remember");
  expect(remembered.length).toBeGreaterThan(0);
  expect(remembered.every((call) => call.params.side === "cloud")).toBe(true);
});

// Edge case 4: the picker and what the send uses disagreed.
test("what the chips draw is what the Cloud start sends, as each pick lands", async () => {
  const { cloudStartPick, cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  await render(await newTab(true, "codex"));
  const steps: (() => Promise<void>)[] = [
    () => pickModel("Claude Code", "Opus 5.5"),
    () => pickLevel("High"),
    () => pickModel("Codex", "GPT-6.1 Sol"),
    () => pickLevel("Medium"),
  ];
  for (const step of steps) {
    await step();
    const start = cloudStartPick({ harness: "codex" });
    const held = cloudAgentPick()!;
    expect(start.harness).toBe(held.harness);
    expect(start.model).toBe(held.model);
    if (held.effort) expect(start.effort).toBe(held.effort);
  }
  expect(chipFace()).toContain("GPT-6.1 Sol");
  expect(chipFace()).toContain("Medium");
});

// Cloud + Auto share one picker: Auto's chips are Cloud's, apart from This Mac's.
test("Auto picked shows Cloud's pick and holds picks for Cloud, starting nothing here", async () => {
  calls.length = 0;
  const { cloudAgentPick, holdCloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "codex", model: "gpt-6.1-sol", effort: "high" });
  const auto = { ...(await newTab(false, "claude")), cloudPicker: true } as Snapshot;
  await render(auto);
  expect(chipFace()).toContain("GPT-6.1 Sol");
  await pickLevel("Low");
  expect(cloudAgentPick()).toEqual({ harness: "codex", model: "gpt-6.1-sol", effort: "low" });
  expect(chatCalls()).toEqual([]);
});
