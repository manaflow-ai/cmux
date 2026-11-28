// l10n-allow-file: test fixtures.
// cmux#59716: on a New Tab with Cloud picked, Claude Code > Opus 5.5 then Medium in the model menu left
// Opus 5.5 and Medium checked, but the chip showed Codex. The level went through the page's own
// `chat.new`, which started this Mac's shown agent (Codex) for a chat that runs on the Cloud machine;
// once that session opened, the chips dropped the Cloud pick and drew it. A level is now a Cloud pick
// like the model: held with the agent, sent with the Cloud start, and nothing starts here. On This
// Mac the same clicks start and set the Claude chat. The real New Tab chips and model menu, in JSDOM.
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

const FOLDER = "/home/dev/cloud-effort";

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

/// The chips gone and drawn again on the same page (Runs On's row redrawn, the page shown again).
async function remount(harness = "codex") {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  doc()
    .body.querySelectorAll(".ui-popup")
    .forEach((node) => node.remove());
  await render(await newTab(true, harness));
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

/// Claude Code > Opus 5.5 > Medium, clicked in the open model menu as the person did.
async function pickOpusMedium() {
  await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
  const tab = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')].find(
    (candidate) => candidate.getAttribute("aria-label") === "Claude Code",
  );
  expect(tab, "the Claude Code tab").toBeDefined();
  await click(tab!);
  const opus = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-row[role="option"]')].find(
    (row) => nameOf(row) === "Opus 5.5",
  );
  expect(opus, "the Opus 5.5 row").toBeDefined();
  await click(opus!);
  const level = () =>
    [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]')].find(
      (row) => nameOf(row) === "Medium",
    );
  await until(
    () => level() !== undefined,
    () => settle(),
  );
  await click(level()!);
  // The menu stays open: its check is on the picked model and level.
  const checked = [...cols()!.querySelectorAll<HTMLElement>('[aria-checked="true"], [aria-selected="true"]')].map(
    nameOf,
  );
  expect(checked).toContain("Opus 5.5");
  expect(checked).toContain("Medium");
}

/// A click elsewhere on the page (the Session Info Outputs, the prompt) closes the menu, as the person
/// did before going back to the reasoning levels; then the menu opens again and `level` is clicked.
async function elsewhereThenLevel(level: string) {
  const outside = doc().createElement("button");
  outside.textContent = "Outputs";
  doc().body.append(outside);
  await act(async () => {
    outside.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    outside.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    outside.click();
  });
  await settle();
  if (cols()) {
    await act(async () => {
      cols()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    await settle();
  }
  outside.remove();
  if (!cols()) await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
  const row = () =>
    [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]')].find(
      (item) => nameOf(item) === level,
    );
  await until(
    () => row() !== undefined,
    () => settle(),
  );
  await click(row()!);
}

test("with Cloud picked, a level picked after Opus 5.5 keeps the chip on Opus 5.5 and starts nothing here", async () => {
  calls.length = 0;
  const { cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  const { cloudPickExtras } = await import("../src/agent-session/acpmux/cloudRun");
  await render(await newTab(true, "codex"));
  await pickOpusMedium();
  // This Mac starts no chat, sets no model or level, for a chat the Cloud machine runs.
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
  // The Cloud send names the agent, model and level the menu checks.
  const pick = cloudAgentPick();
  expect(pick?.harness).toBe("claude");
  expect(pick?.model).toContain("opus");
  expect(pick?.effort).toBe("medium");
  expect(cloudPickExtras({ harness: "codex", effort: "high" }, pick)).toEqual({ effort: "medium" });
  // The chip names Opus 5.5 at Medium, never Codex, also once the chips mount again (the held pick
  // is the page's, not the chips' own state).
  await remount();
  expect(chipFace()).toContain("Opus 5.5");
  expect(chipFace()).toContain("Medium");
  expect(chipFace()).not.toContain("Codex");
  // Outputs, then the reasoning again: High, then Medium. The pick stays Opus 5.5 and follows the level.
  await elsewhereThenLevel("High");
  expect(cloudAgentPick()).toMatchObject({ harness: "claude", effort: "high" });
  await elsewhereThenLevel("Medium");
  expect(cloudAgentPick()).toMatchObject({ harness: "claude", effort: "medium" });
  expect(pick?.model && cloudAgentPick()?.model).toBe(pick?.model);
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
  expect(chipFace()).toContain("Opus 5.5");
  expect(chipFace()).not.toContain("Codex");
});

test("with Cloud picked, a level picked alone keeps the shown agent and model", async () => {
  calls.length = 0;
  const { cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  await render(await newTab(true, "codex"));
  const before = chip().textContent ?? "";
  await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
  const high = () =>
    [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]')].find(
      (row) => nameOf(row) === "High",
    );
  await until(
    () => high() !== undefined,
    () => settle(),
  );
  await click(high()!);
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
  const pick = cloudAgentPick();
  expect(pick?.harness).toBe("codex");
  expect(pick?.effort).toBe("high");
  await remount();
  expect(chipFace()).toContain("High");
  // The model the chip named before the level stays the one it names.
  expect(chipFace()).toContain(before.replace(/\s*(Low|Medium|High|Extra High|Max)\s*$/, "").trim());
});

test("with Cloud picked, another agent's level is never sent for the picked agent", async () => {
  const { cloudPickExtras } = await import("../src/agent-session/acpmux/cloudRun");
  const { holdCloudAgentEffort, holdCloudAgentPick, cloudAgentPick } =
    await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "claude", model: "claude-opus-5-5" });
  expect(cloudPickExtras({ harness: "codex", effort: "high" }, cloudAgentPick())).toEqual({});
  expect(cloudPickExtras({ harness: "claude", effort: "high" }, cloudAgentPick())).toEqual({ effort: "high" });
  holdCloudAgentEffort("claude", "low");
  // A model pick of the same agent keeps its level; a pick of another agent drops it.
  holdCloudAgentPick({ harness: "claude", model: "claude-sonnet-5" });
  expect(cloudAgentPick()).toEqual({ harness: "claude", model: "claude-sonnet-5", effort: "low" });
  holdCloudAgentPick({ harness: "codex" });
  expect(cloudAgentPick()).toEqual({ harness: "codex" });
});

test("on This Mac, Opus 5.5 then Medium starts the Claude chat and sets Medium on it", async () => {
  calls.length = 0;
  const { cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  const codex = await newTab(false, "codex");
  await render(codex);
  await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
  const tab = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')].find(
    (candidate) => candidate.getAttribute("aria-label") === "Claude Code",
  )!;
  await click(tab);
  const opus = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-row[role="option"]')].find(
    (row) => nameOf(row) === "Opus 5.5",
  )!;
  await click(opus);
  const starts = calls.filter((call) => call.method === "chat.new");
  expect(starts.map((call) => call.params.harness)).toEqual(["claude"]);
  // The page now shows the Claude chat the pick started; Medium lands on it.
  await render({ ...codex, summary: { ...codex.summary!, harness: "claude", model: String(starts[0]!.params.model) } });
  const medium = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-tune [role="radio"]')].find(
    (row) => nameOf(row) === "Medium",
  )!;
  await click(medium);
  expect(calls.filter((call) => call.method === "chat.new").map((call) => call.params.harness)).not.toContain("codex");
  expect(calls.some((call) => call.method === "chat.effort" && call.params.value === "medium")).toBe(true);
  expect(cloudAgentPick()).toBeUndefined();
  expect(chipFace()).toContain("Opus 5.5");
  expect(chipFace()).not.toContain("Codex");
});

// The page's snapshot still names Codex when the level is clicked (the Claude chat the pick started has
// not reported yet): the level goes to the Claude chat, never a chat.new that switches back to Codex.
test("on This Mac, Opus 5.5, a click elsewhere, then Medium never starts Codex again", async () => {
  calls.length = 0;
  await render(await newTab(false, "codex"));
  await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
  const tab = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')].find(
    (candidate) => candidate.getAttribute("aria-label") === "Claude Code",
  )!;
  await click(tab);
  const opus = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-row[role="option"]')].find(
    (row) => nameOf(row) === "Opus 5.5",
  )!;
  await click(opus);
  await elsewhereThenLevel("Medium");
  const starts = calls.filter((call) => call.method === "chat.new").map((call) => call.params.harness);
  expect(starts.length).toBeGreaterThan(0);
  expect(new Set(starts)).toEqual(new Set(["claude"]));
});

// The chip that read only "Codex" (no model, no level): a Codex session this Mac opened for the page,
// before it named a model or levels, drawn by the chip's harness-only face (agents.ts
// modelChipFallback). With an agent picked for the Cloud machine, the chips keep that pick until the
// first message, whatever session this Mac has opened behind the page.
test("with Cloud picked, a Codex session this Mac opens behind the page never replaces the picked Opus 5.5", async () => {
  calls.length = 0;
  const { cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  await render(await newTab(true, "codex"));
  await pickOpusMedium();
  expect(cloudAgentPick()).toMatchObject({ harness: "claude", effort: "medium" });
  const page = await newTab(true, "codex");
  // The local Codex session: an id, no model yet, and a Codex catalog row with no models listed.
  const local: Snapshot = {
    ...page,
    sessionId: "local-codex-1",
    catalog: page.catalog.map((entry) =>
      entry.id === "codex" ? { ...entry, models: [{ id: "default", name: "Default" }] } : entry,
    ) as Snapshot["catalog"],
    summary: { ...page.summary!, sessionId: "local-codex-1", harness: "codex" } as Summary,
  };
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  doc()
    .body.querySelectorAll(".ui-popup")
    .forEach((node) => node.remove());
  await render(local);
  expect(chipFace()).toContain("Opus 5.5");
  expect(chipFace()).toContain("Medium");
  expect(chipFace()).not.toContain("Codex");
});

/// Opens the model menu on `tab` and clicks a model row there that is not the checked one (a click on
/// the running model lands nothing); returns that row's name.
async function pickFirstModel(tab: string): Promise<string> {
  if (!cols()) await click(chip());
  await until(
    () => cols() !== null,
    () => settle(),
  );
  const rail = [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')].find(
    (candidate) => candidate.getAttribute("aria-label") === tab,
  );
  expect(rail, `the ${tab} tab`).toBeDefined();
  await click(rail!);
  const row = cols()!.querySelector<HTMLElement>('.acpmux-cols-row[role="option"]:not([aria-selected="true"])');
  expect(row, `a ${tab} model row`).not.toBeNull();
  const name = nameOf(row!);
  await click(row!);
  return name;
}

// The other direction: a page that starts on Claude, Cloud picked, Codex picked, then its levels. The
// chips and the Cloud send stay on Codex; nothing starts Claude here (the report: a Codex Cloud chat
// came up on Claude, "Claude Code is signed out").
test("with Cloud picked, a Codex pick on a Claude page then High, elsewhere, Medium stays Codex", async () => {
  calls.length = 0;
  const { cloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  await render(await newTab(true, "claude"));
  const codex = await pickFirstModel("Codex");
  expect(cloudAgentPick()).toMatchObject({ harness: "codex" });
  await elsewhereThenLevel("High");
  await elsewhereThenLevel("Medium");
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
  expect(cloudAgentPick()).toMatchObject({ harness: "codex", effort: "medium" });
  await remount("claude");
  expect(chipFace()).toContain(codex);
  expect(chipFace()).toContain("Medium");
  expect(chipFace()).not.toContain("Opus");
});

// A Cloud pick of Claude made earlier on the page, then Codex picked on This Mac: each side keeps its own
// pick (model-picker-local-cloud-state), so Cloud picked again shows and starts the Claude picked for it,
// and This Mac's pick never reaches the Cloud start.
test("a This Mac pick of Codex leaves an earlier Cloud pick of Claude as it was", async () => {
  calls.length = 0;
  const { cloudAgentPick, holdCloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "claude", model: "claude-opus-5-5", effort: "high" });
  await render(await newTab(false, "codex"));
  await pickFirstModel("Codex");
  expect(cloudAgentPick()).toEqual({ harness: "claude", model: "claude-opus-5-5", effort: "high" });
  await remount();
  expect(chipFace()).toContain("Opus 5.5");
  expect(chipFace()).not.toContain("Codex");
});
