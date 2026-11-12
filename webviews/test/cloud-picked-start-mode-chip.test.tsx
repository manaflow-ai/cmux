// l10n-allow-file: test fixtures.
// A new chat on this Mac with Settings' Start New Chats In set to Cloud (or Cloud picked in the
// composer's Where row) sends its first message to a Cloud machine (cloud.startChat): that machine
// starts the chat, in what it decides (an asking mode: the Cloud start's policy `ask`). The access
// chip named this Mac's acpmux start mode instead, "Bypass permissions", and the chat then came up
// in Manual on the machine (cloud-ergo-start-chat capture, 2026-11-09). With Cloud picked, the chip
// names the mode the Cloud machine starts the chat in: the harness's asking mode (acpmux sets no
// start mode on a remote start and holds the `ask` policy, web_modes.rs), Claude's Manual and the
// Codex bridge's Ask, never the bare word "Mode" (Leo 2026-11-10: "the "mode" is weird"). The real
// composer chips, in JSDOM.
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
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  // The DOM constructors the menus and App's registered elements read at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

let clearCloudModePickSync: () => void = () => {};
beforeAll(async () => {
  clearCloudModePickSync = (await import("../src/agent-session/acpmux/cloudModePick")).clearCloudModePick;
});

afterEach(async () => {
  // The Cloud mode pick lives in the page's memory until the page goes.
  (await import("../src/agent-session/acpmux/cloudModePick")).clearCloudModePick();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
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

const FOLDER = "/home/dev/cloud-proof";

async function catalog(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  return BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
}

/// A new chat on this Mac in FOLDER, before its first send; `startsOnCloud`: Cloud is picked.
async function newChat(startsOnCloud: boolean, harness = "claude", cloudStartMode?: string): Promise<Snapshot> {
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
    ...(cloudStartMode ? { cloudStartMode } : {}),
  } as Snapshot;
}

async function render(snapshot: Snapshot) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  // This Mac's acpmux answered that a new Claude chat here starts in Bypass permissions.
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  rememberStartMode("claude", FOLDER, { modeId: "bypassPermissions", name: "Bypass permissions" });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ChatComposerChips snapshot={snapshot} />
      </QueryClientProvider>,
    ),
  );
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
}

const chipText = () => (host.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent ?? "").trim();

test("a new chat that starts on this Mac names the mode this Mac's acpmux starts it in", async () => {
  await render(await newChat(false));
  expect(chipText()).toBe("Bypass permissions");
});

test("with Cloud picked, the chip names the mode the Cloud machine starts a Claude chat in, not this Mac's", async () => {
  await render(await newChat(true));
  expect(chipText()).toBe("Manual");
});

test("with Cloud picked, a Codex chat's chip names the bridge's asking mode", async () => {
  await render(await newChat(true, "codex"));
  expect(chipText()).toBe("Ask");
});

// Leo, 2026-11-10: "but shouldnt the user be allowed to just go through with stuff?" A mode picked
// for the Cloud start is what the chip names, and what the send carries to the machine.
test("with Cloud picked, a Bypass permissions pick is what the chip names", async () => {
  await render(await newChat(true, "claude", "bypassPermissions"));
  expect(chipText()).toBe("Bypass permissions");
});

test("with Cloud picked, a Codex full access pick is what the chip names", async () => {
  await render(await newChat(true, "codex", "agent-full-access"));
  expect(chipText()).toBe("Full access");
});

test("a pick for another harness is not this start's: the chip keeps the asking mode", async () => {
  const { holdCloudModePick, cloudStartModePick } = await import("../src/agent-session/acpmux/cloudModePick");
  holdCloudModePick("codex", "agent-full-access");
  expect(cloudStartModePick("claude")).toEqual({});
  holdCloudModePick("claude", "bypassPermissions");
  expect(cloudStartModePick("claude")).toEqual({ mode: "bypassPermissions" });
  // A refused or held send goes again in the same mode: the pick stays held.
  expect(cloudStartModePick("claude")).toEqual({ mode: "bypassPermissions" });
});

test("with Cloud picked, the menu offers only the modes a Cloud start can run in", async () => {
  await render(await newChat(true));
  const button = host.querySelector<HTMLElement>(".acpmux-mode .acpmux-access-trigger");
  expect(button).not.toBeNull();
  await act(async () => {
    button!.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    button!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    button!.click();
  });
  // The menu's rows, not a turn of the event loop: wait until the menu drew them.
  await until(
    () => dom.window.document.querySelectorAll("[role=menuitemradio]").length > 0,
    () => act(async () => {}),
  );
  const rows = [...dom.window.document.querySelectorAll("[role=menuitemradio]")].map((row) => row.textContent ?? "");
  expect(rows.some((row) => row.includes("Manual"))).toBe(true);
  expect(rows.some((row) => row.includes("Bypass permissions"))).toBe(true);
  expect(rows.some((row) => row.includes("Accept edits"))).toBe(false);
  expect(rows.some((row) => row.includes("Auto"))).toBe(false);
});

// A Mac with no agent CLI shows another harness (unii) in the composer; the Cloud send names none,
// so the machine starts its default agent, Claude (acpmux default_harness.rs). The chip and its menu
// name that agent's modes, never a bare "Mode" (journey run 42975854214: every cell read "Mode").
test("with Cloud picked and a harness cmux knows no Cloud mode for, the chip names Claude's asking mode", async () => {
  await render(await newChat(true, "unii"));
  expect(chipText()).toBe("Manual");
});

test("with Cloud picked and such a harness, a Bypass permissions pick is what the chip names", async () => {
  await render(await newChat(true, "unii", "bypassPermissions"));
  expect(chipText()).toBe("Bypass permissions");
});

test("with Cloud picked and such a harness, the menu offers Claude's Cloud modes, Bypass included", async () => {
  await render(await newChat(true, "unii"));
  const button = host.querySelector<HTMLElement>(".acpmux-mode .acpmux-access-trigger");
  expect(button).not.toBeNull();
  await act(async () => {
    button!.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    button!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    button!.click();
  });
  // The menu's rows, not a turn of the event loop: wait until the menu drew them.
  await until(
    () => dom.window.document.querySelectorAll("[role=menuitemradio]").length > 0,
    () => act(async () => {}),
  );
  const rows = [...dom.window.document.querySelectorAll("[role=menuitemradio]")].map((row) => row.textContent ?? "");
  expect(rows.some((row) => row.includes("Manual"))).toBe(true);
  expect(rows.some((row) => row.includes("Bypass permissions"))).toBe(true);
  expect(rows.some((row) => row.includes("Accept edits"))).toBe(false);
});

async function openModeMenu(): Promise<string[]> {
  const button = host.querySelector<HTMLElement>(".acpmux-mode .acpmux-access-trigger");
  expect(button).not.toBeNull();
  await act(async () => {
    button!.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    button!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
    button!.click();
  });
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  return [...dom.window.document.querySelectorAll("[role=menuitemradio]")].map((row) => row.textContent ?? "");
}

// The chip names the agent and mode the Cloud machine starts; both sends (the chat composer's, which
// names a harness only after a switch, and New Tab's `onCloud`) start exactly that. A face harness
// with no Cloud start mode (unii on a Mac with no agent CLI) is left out of the send, so the machine
// starts its default agent, Claude, in the mode the chip names.
test("both Cloud sends start the agent and mode the chip names, for every face harness", async () => {
  const { cloudStartAgent, CLOUD_DEFAULT_AGENT, harnessFamilyMenu } =
    await import("../src/agent-session/acpmux/harnessModes");
  const { cloudSendAgent, clearCloudModePick } = await import("../src/agent-session/acpmux/cloudModePick");
  const cases = [
    { face: "claude", family: "claude", runs: "claude", asking: "Manual" },
    { face: "codex", family: "codex", runs: "codex", asking: "Ask" },
    { face: "unii", family: "unii", runs: CLOUD_DEFAULT_AGENT, asking: "Manual" },
  ];
  // Another agent the person picked is the one the machine runs, never swapped for Claude.
  expect(cloudSendAgent("opencode", "opencode", "m")).toEqual({ harness: "opencode", model: "m" });
  expect(cloudStartAgent("opencode", "opencode")).toEqual({ family: "opencode", harness: "opencode", named: true });
  for (const { face, family, runs, asking } of cases) {
    // Each face is its own new chat: a fresh page, no pick or menu left from the last.
    clearCloudModePick();
    act(() => root?.unmount());
    root = undefined;
    host.replaceChildren();
    await render(await newChat(true, face));
    expect(chipText()).toBe(asking);
    // Pick the widest mode through the chip's own menu, as a click does.
    const rows = await openModeMenu();
    const widest = rows.find((row) => /Bypass permissions|Full access/.test(row));
    expect(widest).toBeDefined();
    const row = [...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find(
      (item) => item.textContent === widest,
    )!;
    await act(async () => row.click());
    // New Tab's send: the harness and model only when the machine runs that agent.
    const newTab = cloudSendAgent(family, face, "some-model");
    const started = newTab.harness ?? CLOUD_DEFAULT_AGENT;
    expect(started).toBe(runs);
    expect(newTab.model).toBe(started === face ? "some-model" : undefined);
    // The chat composer's send names no harness (no switch): the machine starts its default unless
    // the face is an agent it runs, which acpmux also starts first for that face (cloudStartAgent).
    expect(cloudStartAgent(family, face).harness).toBe(runs);
    // Both carry the picked mode, a mode of the agent that starts, named as the chip named it.
    expect(newTab.mode).toBeDefined();
    const menu = harnessFamilyMenu(runs, runs)!;
    const sentRow = menu.rows.find((r) => r.id === newTab.mode);
    expect(sentRow).toBeDefined();
    expect(widest).toContain(sentRow!.name);
  }
});

// A real app's New Agent Chat opens a session on this Mac before the first send (journey run
// 43021965230): it has an id, and may report modes, with none current. Cloud picked, that session is
// not the one that runs, so the chip still names the Cloud start's mode and a pick shows.
function withLocalSession(snapshot: Snapshot, modes: { id: string; name: string }[]): Snapshot {
  return {
    ...snapshot,
    summary: {
      ...snapshot.summary!,
      sessionId: "local-session-1",
      ...(modes.length ? { modes: { availableModes: modes } } : {}),
    } as Summary,
  };
}

const CLAUDE_MODES = [
  { id: "default", name: "Manual" },
  { id: "acceptEdits", name: "Accept edits" },
  { id: "plan", name: "Plan" },
  { id: "bypassPermissions", name: "Bypass permissions" },
];

for (const [face, modes] of [
  ["claude", CLAUDE_MODES],
  ["claude", []],
  ["unii", []],
] as const) {
  test(`with Cloud picked and a local ${face} session already open (${modes.length ? "with" : "no"} modes), the chip names the Cloud start's mode and a pick`, async () => {
    clearCloudModePickSync();
    await render(withLocalSession(await newChat(true, face), [...modes]));
    expect(chipText()).toBe("Manual");
    const rows = await openModeMenu();
    expect(rows.some((row) => row.includes("Bypass permissions"))).toBe(true);
    expect(rows.some((row) => row.includes("Accept edits"))).toBe(false);
    await render(withLocalSession(await newChat(true, face, "bypassPermissions"), [...modes]));
    expect(chipText()).toBe("Bypass permissions");
  });
}

test("with Cloud picked and no harness listed yet, the chip names the machine's default agent's mode", async () => {
  const snapshot = await newChat(true);
  await render({ ...snapshot, summary: { ...snapshot.summary!, harness: undefined } as unknown as Summary });
  expect(chipText()).toBe("Manual");
});

test("the Cloud start request carries the picked mode to the host, and only a pick", async () => {
  const { startCloudChat } = await import("../src/agent-session/acpmux/cloudRun");
  const calls: Record<string, unknown>[] = [];
  const call = async (_method: string, params: Record<string, unknown>) => void calls.push(params);
  await startCloudChat(call, { task: "go", harness: "claude", mode: "bypassPermissions" }, "k");
  expect(calls[0]).toMatchObject({ harness: "claude", mode: "bypassPermissions" });
  await startCloudChat(call, { task: "go", harness: "claude" }, "k");
  expect("mode" in calls[1]!).toBe(false);
});

test("a start in another mode is another start; one with no pick keeps its key", async () => {
  const { cloudStartFingerprint } = await import("../src/agent-session/acpmux/cloudRun");
  const plain = cloudStartFingerprint({ task: "go", harness: "claude" });
  expect(cloudStartFingerprint({ task: "go", harness: "claude", mode: "bypassPermissions" })).not.toBe(plain);
  expect(cloudStartFingerprint({ task: "go", harness: "claude" })).toBe(plain);
});
