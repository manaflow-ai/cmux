// l10n-allow-file: test fixtures.
// A new chat that starts in a mode that skips approvals (bypassPermissions, agent-full-access,
// cx-uq9xi) draws its pending access chip in the warning treatment, as the live chip does, never
// neutral first. The mode is the one acpmux answers it will start the chat in (`_acpmux/start_mode`,
// cx-wx93i), not the one the harness's last chat showed: the answer this viewer kept draws on the
// first frame, the one acpmux gives now replaces it, and with no answer the chip names none.
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

function reported(sessionId: string, currentModeId: string): Summary {
  return {
    sessionId,
    harness: "claude",
    model: "default",
    turnCount: 0,
    modes: {
      currentModeId,
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "bypassPermissions", name: "Bypass permissions" },
      ],
    },
  };
}

/// Renders the composer's chips for `summary` (undefined: a new chat whose session has not reported).
async function render(summary: Summary, cwd?: string) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: summary ?? { sessionId: "", harness: "claude", turnCount: 0, ...(cwd ? { cwd } : {}) },
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  }
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
}

/// The access chip: its label and whether it has the warning treatment.
const access = () => {
  const chip = host.querySelector<HTMLElement>(".acpmux-mode");
  return (
    chip && {
      label: (chip.querySelector(".acpmux-mode-text")?.textContent ?? "").trim(),
      warning: chip.classList.contains("acpmux-unrestricted"),
    }
  );
};

type Answer = { modeId: string; name?: string } | undefined;

/// acpmux answers each ask with `answer` once `release` is called (a held answer: the first frame
/// draws before it arrives).
async function acpmux(answer: Answer) {
  const { setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  let release!: () => void;
  const arrived = new Promise<void>((done) => (release = done));
  setStartModeSource(async (harness) => {
    await arrived;
    return harness === "claude" ? answer : undefined;
  });
  return async () => {
    release();
    await act(async () => {
      await new Promise((done) => setTimeout(done, 0));
    });
  };
}

/// acpmux's answer this viewer kept from an earlier ask.
async function kept(answer: Answer) {
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  rememberStartMode("claude", undefined, answer);
}

async function fresh(cwd?: string) {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await render(undefined, cwd);
}

test("a new chat acpmux starts in full access draws its warning chip on the first frame", async () => {
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux({ modeId: "bypassPermissions", name: "Bypass permissions" });
  await render(reported("earlier", "default"));
  expect(access()).toEqual({ label: "Ask before edits", warning: false });

  // A new chat, before acpmux answers again: its kept answer, warning included.
  await fresh();
  expect(host.querySelector(".acpmux-chip-pending.acpmux-mode")).not.toBeNull();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
  await answer();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });

  // Its session reports the same mode: nothing changes.
  await render(reported("new", "bypassPermissions"));
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
});

test("a kept answer that is wrong gives way to acpmux's answer", async () => {
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux({ modeId: "default", name: "Ask before edits" });
  await fresh();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
  await answer();
  expect(access()).toEqual({ label: "Ask before edits", warning: false });
});

test("without an answer from acpmux a new chat names no mode, whatever the last chat showed", async () => {
  await render(reported("earlier", "bypassPermissions"));
  localStorage.setItem("cmux.acpmux.lastChips", JSON.stringify({ claude: { mode: "Bypass permissions" } }));
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  // acpmux sets no mode (or predates the method): the kept answer goes too.
  const answer = await acpmux(undefined);
  await fresh();
  await answer();
  expect(access()).toBeNull();
});

test("a folder acpmux has not answered for never names another folder's mode, nor its warning", async () => {
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  // Another folder's chats start in full access; this folder's profile pins its own mode, so
  // acpmux sets none here (it answers none). Until it answers, the chip holds its place unnamed.
  rememberStartMode("claude", "/elsewhere", { modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux(undefined);
  await fresh("/here");
  expect(host.querySelector(".acpmux-chip-pending.acpmux-mode")).not.toBeNull();
  const first = access()!;
  expect(first.label).not.toBe("Bypass permissions");
  expect(first.label).not.toBe("bypassPermissions");
  expect(first.warning).toBe(false);
  await answer();
  expect(access()).toBeNull();
});

test("a harness switch never draws another folder's start mode as the chat's current mode", async () => {
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  const { applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const { HarnessProfiles } = await import("../src/agent-session/acpmux/harnessProfiles");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const profiles = new HarnessProfiles(() => undefined);
  profiles.observe(reported("earlier", "default") as Snapshot["summary"]);
  rememberStartMode("claude", "/elsewhere", { modeId: "bypassPermissions", name: "Bypass permissions" });
  const raw = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
  } as unknown as Snapshot;
  const view = {
    intent: {
      id: 1,
      harness: "claude",
      cwd: "/unanswered",
      phase: "starting" as const,
      shown: true,
      queued: [],
      config: { options: {} },
    },
  };
  expect(applySwitch(raw, view, [], profiles).summary?.modes?.currentModeId).toBeUndefined();
  // acpmux's answer for this very folder is drawn.
  rememberStartMode("claude", "/unanswered", { modeId: "bypassPermissions", name: "Bypass permissions" });
  expect(applySwitch(raw, view, [], profiles).summary?.modes?.currentModeId).toBe("bypassPermissions");
});
