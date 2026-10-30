// l10n-allow-file: test fixtures.
// Lawrence 2026-10-20 ("a more comprehensive model and harness picker ... plus any extra config
// options the harness advertises, shown dynamically"): the composer had chips for the model, the
// effort level, fast mode and the permission mode only. The Options chip now lists custom config
// options it does not otherwise own; Codex's collaboration mode stays on its command/mode paths.
// A pick goes through the same config-option command as the effort chip. The mock daemon still
// offers Codex's collaboration mode and takes `session/set_mode`.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
});

afterEach(async () => {
  const { setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Summary = Record<string, unknown> | undefined;

const option = (id: string, values: string[], extra: Record<string, unknown> = {}) => ({
  id,
  name: id,
  currentValue: values[0],
  options: values.map((value) => ({ value, name: value[0]!.toUpperCase() + value.slice(1) })),
  ...extra,
});

const codex = (configOptions: unknown[]): Summary => ({
  sessionId: "s1",
  harness: "codex",
  model: "gpt-6-astra",
  turnCount: 1,
  modes: { currentModeId: "auto", availableModes: [{ id: "read-only" }, { id: "auto" }] },
  configOptions,
});

async function render(summary: Summary, sent: string[]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary,
  } as unknown as Snapshot;
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ComposerPickers
          snapshot={snapshot}
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={(configId, value) => sent.push(`${configId}=${value}`)}
          onHarness={() => undefined}
          showPlan={false}
        />
      </QueryClientProvider>,
    );
  });
}

test("only options no other chip owns are extra", async () => {
  const { extraConfigOptions } = await import("../src/agent-session/acpmux/agentOptions");
  const all = [
    option("model", ["a", "b"], { category: "model" }),
    option("mode", ["read-only", "auto"], { category: "mode" }),
    option("reasoning_effort", ["low", "high"], { category: "thought_level" }),
    option("ultracode", ["off", "on"], { category: "model_config" }),
    option("fast-mode", ["off", "on"], { category: "model_config" }),
    option("collaboration_mode", ["default", "plan"], { category: "collaboration_mode" }),
    option("thinking", ["off", "on"]),
    option("sandbox", ["workspace"]),
  ];
  type Summary = Parameters<typeof extraConfigOptions>[0];
  expect(extraConfigOptions(codex(all) as Summary).map((entry) => entry.id)).toEqual(["thinking"]);
  // A harness that reports its modes only as a config option keeps them here.
  const noModes = { ...codex(all), modes: undefined } as Summary;
  expect(extraConfigOptions(noModes).map((entry) => entry.id)).toEqual(["mode", "thinking"]);
});

test("the Options chip names one option and picks its choice through the config command", async () => {
  const sent: string[] = [];
  await render(codex([option("thinking", ["off", "on"], { name: "Thinking" })]), sent);
  const chip = host.querySelector<HTMLElement>("[data-menu=options]");
  expect(chip?.textContent).toContain("Thinking: Off");
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Options"));
  const on = [...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find((row) =>
    row.textContent?.includes("On"),
  );
  expect(on).toBeDefined();
  await act(async () => on!.click());
  expect(sent).toEqual(["thinking=on"]);
});

test("Codex collaboration mode does not add a composer Options chip", async () => {
  await render(codex([option("collaboration_mode", ["default", "plan"], { name: "Collaboration mode" })]), []);
  expect(host.querySelector("[data-menu=options]")).toBeNull();
});

test("a Codex profile collaboration option does not add a composer Options chip", async () => {
  await render(
    {
      ...codex([option("collaboration_mode", ["default", "plan"], { name: "Collaboration mode" })]),
      harness: "codex-work",
    },
    [],
  );
  expect(host.querySelector("[data-menu=options]")).toBeNull();
});

test("a custom harness collaboration option stays available in Options", async () => {
  const sent: string[] = [];
  await render(
    {
      ...codex([option("collaboration_mode", ["default", "plan"], { name: "Collaboration mode" })]),
      harness: "custom",
    },
    sent,
  );
  expect(host.querySelector<HTMLElement>("[data-menu=options]")?.textContent).toContain("Collaboration mode: Default");
});

test("a session with no extra option shows no Options chip", async () => {
  await render(codex([option("reasoning_effort", ["low", "high"], { category: "thought_level" })]), []);
  expect(host.querySelector("[data-menu=options]")).toBeNull();
});

test("the mock daemon offers Codex's collaboration mode and switches modes", async () => {
  const { MockAcpmuxSocket } = await import("../src/agent-session/acpmux/mock");
  type Hooks = { answer: (method: string, params: unknown) => Promise<unknown>; sessions: Record<string, any>[] };
  const daemon = new MockAcpmuxSocket(() => Promise.resolve()) as unknown as Hooks;
  const codexSession = daemon.sessions.find((session) => session.harness === "codex")!;
  expect(codexSession.configOptions.map((entry: { id: string }) => entry.id)).toContain("collaboration_mode");
  const claude = daemon.sessions.find((session) => session.harness === "claude")!;
  await daemon.answer("session/set_mode", { sessionId: claude.sessionId, modeId: "plan" });
  expect(daemon.sessions.find((session) => session.sessionId === claude.sessionId)!.modes.currentModeId).toBe("plan");
  await expect(daemon.answer("session/set_mode", { sessionId: claude.sessionId, modeId: "nope" })).rejects.toThrow();
});
