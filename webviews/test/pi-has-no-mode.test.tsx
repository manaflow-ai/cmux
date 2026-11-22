// l10n-allow-file: test fixtures.
// Pi has no permission mode (Lawrence 2026-11-19, the omnibar's Ask Pi: "pi should not have a
// "mode""). Pi's ACP bridge (pi-acp 0.0.33) answers `session/new` with its thinking levels twice:
// as its `thought_level` config option and, for ACP clients older than config options, again as
// ACP `modes` ("Thinking: off" … "Thinking: xhigh"). Those modes are that option's mirror, not
// permission modes, so no composer draws a Mode chip for Pi: not a running Pi chat, and not a new
// chat (the New Tab, the omnibar's Ask) whose session has not started, which acpmux's harness list
// tells what Pi's chats report. Claude Code and Codex keep theirs.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"];
/// Pi's `session/new` answer as pi-acp 0.0.33 sends it (models cut to two).
const PI_MODES = {
  currentModeId: "medium",
  availableModes: LEVELS.map((id) => ({ id, name: `Thinking: ${id}`, description: null })),
};
const PI_OPTIONS = [
  {
    type: "select",
    id: "model",
    category: "model",
    name: "Model",
    currentValue: "openrouter/google/gemini-4-neon",
    options: [
      { value: "openrouter/google/gemini-4-neon", name: "openrouter/Google: Gemini 4 Neon" },
      { value: "anthropic/claude-opus-5-5", name: "anthropic/Claude Opus 5.5" },
    ],
  },
  {
    type: "select",
    id: "thought_level",
    category: "thought_level",
    name: "Thinking",
    currentValue: "medium",
    options: LEVELS.map((value) => ({ value, name: value })),
  },
];
/// Claude Code's reply (acpmux's own backend, claude_stdio): its modes mirror its `mode` option.
const CLAUDE_MODES = {
  currentModeId: "bypassPermissions",
  availableModes: [
    { id: "default", name: "Default" },
    { id: "acceptEdits", name: "Accept edits" },
    { id: "plan", name: "Plan" },
    { id: "bypassPermissions", name: "Bypass permissions" },
  ],
};
const CLAUDE_OPTIONS = [
  {
    type: "select",
    id: "mode",
    category: "mode",
    name: "Permission mode",
    currentValue: "bypassPermissions",
    options: CLAUDE_MODES.availableModes.map((mode) => ({ value: mode.id, name: mode.name })),
  },
  {
    type: "select",
    id: "effort",
    category: "thought_level",
    name: "Reasoning",
    currentValue: "high",
    options: ["low", "medium", "high"].map((value) => ({ value })),
  },
];

/// `_acpmux/harnesses` as acpmux answers it (hub/harness_view.rs), each row's `reported` what its
/// newest chat reported (start_mode.rs `reported_options`: definitions, no current values).
function harnessesReply() {
  const definitions = (options: typeof PI_OPTIONS | typeof CLAUDE_OPTIONS) =>
    options.map(({ currentValue: _current, ...option }) => option);
  return {
    defaultHarness: "claude",
    harnesses: {
      claude: {
        name: "Claude Code",
        family: "claude",
        models: [{ id: "opus", name: "Opus 5.5" }],
        reported: { modes: CLAUDE_MODES.availableModes, configOptions: definitions(CLAUDE_OPTIONS) },
      },
      pi: {
        name: "Pi",
        family: "pi",
        models: [{ id: "openrouter/google/gemini-4-neon", name: "openrouter/Google: Gemini 4 Neon" }],
        reported: { modes: PI_MODES.availableModes, configOptions: definitions(PI_OPTIONS) },
      },
    },
  };
}

type Summary = Record<string, unknown>;

/// Renders the composer's chips for `summary` with acpmux's harness list.
async function render(summary: Summary, harnesses: unknown = harnessesReply()) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { normalizeCatalog } = await import("../src/agent-session/acpmux/direct");
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
    catalog: normalizeCatalog(harnesses),
    summary,
  } as unknown as Snapshot;
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <div className="acpmux-composer-bar" data-footer-look="plain">
          <ComposerPickers
            snapshot={snapshot}
            onModel={() => undefined}
            onMode={() => undefined}
            onEffort={() => undefined}
            onHarness={() => undefined}
            harnessesListed
            showPlan={false}
          />
        </div>
      </QueryClientProvider>,
    );
  });
  await act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
}

const accessChip = () => host.querySelector(".acpmux-mode, .acpmux-access");
const modelChip = () => host.querySelector(".acpmux-model");

/// The summary acpmux's direct client publishes for a chat whose agent answered `session/new` with
/// these modes and options (the mock daemon stands in for acpmux).
async function published(harness: string, modes: unknown, configOptions: unknown) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  type Published = {
    summary?: { sessionId?: string; harness?: string; model?: string; modes?: unknown; configOptions?: unknown };
  };
  let latest: Published | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      latest = snapshot as Published;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const target = mockHost.sessionId!;
    while (latest?.summary?.sessionId !== target) await new Promise<void>((resolve) => wakes.push(resolve));
    (socket as unknown as { touch(target: string, fields: Record<string, unknown>): void }).touch(target, {
      harness,
      family: harness,
      // Marks the frame that carries this update: the mock's own chat already reports Claude's.
      model: `reported-by-${harness}`,
      modes,
      configOptions,
    });
    while (latest?.summary?.model !== `reported-by-${harness}`)
      await new Promise<void>((resolve) => wakes.push(resolve));
    return latest.summary;
  } finally {
    client.close?.();
  }
}

test("a running Pi chat publishes no modes: its thinking levels are its Thinking option, not a Mode", async () => {
  const pi = await published("pi", PI_MODES, PI_OPTIONS);
  expect(pi?.modes).toBeUndefined();
  // Its thinking levels stay, as the option the effort chip draws.
  expect(((pi?.configOptions ?? []) as { id: string }[]).map((option) => option.id)).toEqual([
    "model",
    "thought_level",
  ]);
  const claude = await published("claude", CLAUDE_MODES, CLAUDE_OPTIONS);
  expect(claude?.modes).toEqual(CLAUDE_MODES);
});

test("a running Pi chat's composer draws no Mode chip", async () => {
  const pi = await published("pi", PI_MODES, PI_OPTIONS);
  await render({ ...pi, sessionId: "s-pi", harness: "pi", family: "pi", model: "openrouter/google/gemini-4-neon" });
  expect(modelChip()).not.toBeNull();
  expect(accessChip()).toBeNull();
});

test("a new Pi chat (New Tab, omnibar Ask) draws no Mode chip, not even the held placeholder", async () => {
  await render({ sessionId: "", harness: "pi", turnCount: 0 });
  expect(modelChip()).not.toBeNull();
  expect(accessChip()).toBeNull();
  expect(host.textContent ?? "").not.toContain("Mode");
});

test("a new Claude Code chat still holds its Mode chip's place from the first frame", async () => {
  await render({ sessionId: "", harness: "claude", turnCount: 0 });
  expect(accessChip()).not.toBeNull();
});

test("a harness whose own modes arrive with config options keeps them (Claude Code, Codex)", async () => {
  const { permissionModes } = await import("../src/agent-session/acpmux/permissionModes");
  expect(permissionModes(CLAUDE_MODES, CLAUDE_OPTIONS)).toBe(CLAUDE_MODES);
  // OpenCode and Gemini report modes and no config options: theirs are real modes.
  const opencode = { currentModeId: "build", availableModes: [{ id: "build" }, { id: "plan" }] };
  expect(permissionModes(opencode, undefined)).toBe(opencode);
  // A collaboration-mode option (Codex's Default/Plan) is not what its approval modes mirror.
  const codex = {
    currentModeId: "agent",
    availableModes: [{ id: "ask" }, { id: "agent" }, { id: "agent-full-access" }],
  };
  const collaboration = [
    { id: "collaboration_mode", category: "collaboration_mode", options: [{ value: "default" }, { value: "plan" }] },
  ];
  expect(permissionModes(codex, collaboration)).toBe(codex);
  expect(permissionModes(PI_MODES, PI_OPTIONS)).toBeUndefined();
});

/// `_acpmux/harnesses` on a Mac that never ran these agents, before their startup probes answer
/// (or after one failed): no row says what its chats report.
function nothingReported() {
  const reply = harnessesReply();
  const harnesses = reply.harnesses as Record<string, Record<string, unknown>>;
  for (const row of Object.values(harnesses)) delete row.reported;
  harnesses.opencode = { name: "OpenCode", family: "opencode", models: [{ id: "m", name: "M" }] };
  return reply;
}

test("the first New Tab on Pi, on a Mac that never ran Pi, draws no Mode chip", async () => {
  // Nothing says Pi has a permission mode: no chat of it, no probe answer, no family menu.
  await render({ sessionId: "", harness: "pi", turnCount: 0 }, nothingReported());
  expect(modelChip()).not.toBeNull();
  expect(accessChip()).toBeNull();
  expect(host.textContent ?? "").not.toContain("Mode");
});

test("a harness acpmux reports modes for holds its Mode chip's place before any chat of it", async () => {
  // Claude Code: its family's own menu, reported or not.
  await render({ sessionId: "", harness: "claude", turnCount: 0 }, nothingReported());
  expect(accessChip()).not.toBeNull();
  // OpenCode, once its probe reported its modes (build, plan), with no config options.
  const reply = nothingReported();
  (reply.harnesses as Record<string, Record<string, unknown>>).opencode.reported = {
    modes: [
      { id: "build", name: "Build" },
      { id: "plan", name: "Plan" },
    ],
    configOptions: [],
  };
  await render({ sessionId: "", harness: "opencode", turnCount: 0 }, reply);
  expect(accessChip()).not.toBeNull();
});
