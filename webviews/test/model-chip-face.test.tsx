// l10n-allow-file: test fixtures.
// Lawrence 2026-11-10, on a composer chip that drew the OpenAI logo beside "Opus 5.5 Medium": "need to
// make this state impossible". The chip's logo is the provider of the model its text names, on every
// harness that can run that model (a Codex harness behind a router runs Opus), at every effort level,
// and on every path a chip is drawn on: a live session, a chat restored from the list before its
// session attaches, a held pick of another harness's model, and a switch to another harness.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { settleReact } from "./support/domTeardown";

setDefaultTimeout(900_000);
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
}, 900_000);

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
}, 900_000);

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
}, 900_000);

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

/// A model a harness lists, and the mark its own provider draws (AgentMark's brand key).
type Row = { id: string; name: string; provider: string };
const OPUS: Row = { id: "claude-opus-5-5", name: "Opus 5.5", provider: "claude" };
const SONNET: Row = { id: "claude-sonnet-5-5", name: "Sonnet 5.5", provider: "claude" };
const OPUS_ALIAS: Row = { id: "opus", name: "Opus", provider: "claude" };
const GPT: Row = { id: "gpt-6-astra", name: "GPT-6 Astra", provider: "openai" };
const GEMINI: Row = { id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", provider: "gemini" };
const DEEPSEEK: Row = { id: "opencode-go/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", provider: "deepseek" };
const OC_CLAUDE: Row = { id: "opencode/claude-opus-5-5", name: "Claude Opus 5.5", provider: "claude" };
const OC_GPT: Row = { id: "opencode/gpt-6-astra", name: "GPT-6 Astra", provider: "openai" };

/// Harnesses and what each runs: Codex and Claude Code through the router run each other's models.
const HARNESSES: { id: string; name: string; mark: string; models: Row[] }[] = [
  { id: "claude", name: "Claude Code", mark: "claude", models: [OPUS, SONNET, OPUS_ALIAS, GPT] },
  { id: "codex", name: "Codex", mark: "openai", models: [GPT, OPUS, SONNET] },
  { id: "gemini", name: "Gemini CLI", mark: "gemini", models: [GEMINI] },
  { id: "opencode", name: "OpenCode", mark: "opencode", models: [DEEPSEEK, OC_CLAUDE, OC_GPT] },
  { id: "claude-sr2", name: "Claude (router)", mark: "claude", models: [OPUS, GPT] },
];
const EFFORTS = [
  ["low", "Low"],
  ["medium", "Medium"],
  ["high", "High"],
  ["max", "Max"],
] as const;
const LEVELS = ["default", "low", "medium", "high", "xhigh", "max"];

const catalog = HARNESSES.map((harness) => ({
  id: harness.id,
  name: harness.name,
  family: harness.id === "claude-sr2" ? "claude" : harness.id,
  models: harness.models.map(({ id, name }) => ({ id, name })),
})) as unknown as Snapshot["catalog"];

function summary(harness: string, model: string, effort: string) {
  return {
    sessionId: "s-1",
    harness,
    family: harness === "claude-sr2" ? "claude" : harness,
    model,
    turnCount: 1,
    configOptions: [
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: model,
        options: HARNESSES.find((entry) => entry.id === harness)!.models.map((row) => ({
          value: row.id,
          name: row.name,
        })),
      },
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: effort,
        options: LEVELS.map((value) => ({ value })),
      },
    ],
  };
}

function base(): Snapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [{ id: "u1", kind: "user", text: "hi" }],
    sessions: [],
    sessionId: "s-1",
    connection: "connected",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    canHandoff: true,
    catalog,
  } as unknown as Snapshot;
}

async function draw(snapshot: Snapshot, fork = false) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, {});
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        {...(fork ? { fork: true } : {})}
        showPlan={false}
      />
    );
  }
  if (!root) root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
}

/// What the chip draws: its logo's brand, its name and its effort.
function chip() {
  const button = host.querySelector<HTMLElement>('[data-menu="Model"]');
  return {
    mark: button?.querySelector(".agent-mark")?.getAttribute("data-agent") ?? undefined,
    name: (button?.querySelector(".acpmux-model-name")?.textContent ?? "").trim(),
    effort: (button?.querySelector(".acpmux-model-detail")?.textContent ?? "").trim(),
  };
}

/// Every harness, every model it runs, every level.
const COMBOS = HARNESSES.flatMap((harness) =>
  harness.models.flatMap((row) => EFFORTS.map(([effort, level]) => ({ harness, row, effort, level }))),
);
const label = (combo: (typeof COMBOS)[number]) => `${combo.harness.id} ${combo.row.id} ${combo.effort}`;

test("a live session's chip draws the logo of the model it names, on every harness, model and level", async () => {
  const wrong: string[] = [];
  for (const combo of COMBOS) {
    await draw({ ...base(), summary: summary(combo.harness.id, combo.row.id, combo.effort) } as unknown as Snapshot);
    const drawn = chip();
    if (drawn.mark !== combo.row.provider || !drawn.effort.includes(combo.level))
      wrong.push(`${label(combo)}: ${drawn.mark} "${drawn.name}" "${drawn.effort}"`);
  }
  expect(wrong).toEqual([]);
}, 900_000);

test("a chat restored from the list, before its session attaches, draws its listed model's logo", async () => {
  const wrong: string[] = [];
  for (const combo of COMBOS) {
    await draw({
      ...base(),
      sessions: [
        { sessionId: "s-1", harness: combo.harness.id, model: combo.row.id, effort: combo.effort, turnCount: 3 },
      ],
      summary: undefined,
    } as unknown as Snapshot);
    const drawn = chip();
    if (drawn.name && drawn.mark !== combo.row.provider) wrong.push(`${label(combo)}: ${drawn.mark} "${drawn.name}"`);
  }
  expect(wrong).toEqual([]);
}, 900_000);

test("a held pick of another harness's model draws that model's logo, never the chat's harness", async () => {
  const { holdFork, clearHeldFork } = await import("../src/agent-session/acpmux/forkHold");
  const wrong: string[] = [];
  for (const combo of COMBOS) {
    for (const chat of ["claude", "codex"]) {
      if (combo.harness.id === chat) continue;
      // The previous chat's unmount clears its held pick (ComposerPickers), so it goes first.
      act(() => root?.unmount());
      root = undefined;
      holdFork({ sessionId: "s-1", harness: combo.harness.id, model: combo.row.id, effort: combo.effort });
      await draw(
        { ...base(), summary: summary(chat, chat === "claude" ? OPUS.id : GPT.id, "high") } as unknown as Snapshot,
        true,
      );
      const drawn = chip();
      if (drawn.mark !== combo.row.provider)
        wrong.push(`${chat} chat, held ${label(combo)}: ${drawn.mark} "${drawn.name}"`);
      clearHeldFork("s-1");
    }
  }
  expect(wrong).toEqual([]);
}, 900_000);

test("a switch to another harness draws that harness alone, its mark beside its own name", async () => {
  for (const harness of HARNESSES) {
    await draw({
      ...base(),
      sessionId: undefined,
      rows: [],
      switching: { harness: harness.id, name: harness.name, phase: "starting" },
      summary: { ...summary(harness.id, harness.models[0]!.id, "medium"), sessionId: "" },
    } as unknown as Snapshot);
    const drawn = chip();
    // A switch names either the harness (its own mark) or the model it starts on (that model's).
    const named = harness.models.find((row) => drawn.name.includes(row.name.replace(/^Claude /, "")));
    expect(drawn.mark, `${harness.id}: "${drawn.name}"`).toBe(named ? named.provider : harness.mark);
  }
}, 900_000);
