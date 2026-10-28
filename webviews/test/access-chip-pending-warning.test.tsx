// l10n-allow-file: test fixtures.
// A new chat that starts in a mode that skips approvals (bypassPermissions, agent-full-access,
// cx-uq9xi) draws its pending access chip in the warning treatment, as the live chip does, never
// neutral first. The mode is the one acpmux answers it will start the chat in (`_acpmux/start_mode`,
// cx-wx93i), not the one the harness's last chat showed: the answer this viewer kept draws on the
// first frame, the one acpmux gives now replaces it, and when acpmux sets none the chip names none
// but keeps its place as "Mode" (Leo 2026-10-23, cx-ncc.113.116: the New Tab row "keeps switching
// around"). Before acpmux has ever answered for the harness, it names the harness's highest level.
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
  const { setStartModeSource, resetStartModesForTests } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  resetStartModesForTests();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Summary = Record<string, unknown> | undefined;
type PermissionAccess = {
  grants: readonly { id: string; label: string; onRemove(): void }[];
};

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
async function render(summary: Summary, cwd?: string, permissionAccess?: PermissionAccess, holdsModePick = true) {
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
        permissionAccess={permissionAccess}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
        holdsModePick={holdsModePick}
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

async function fresh(cwd?: string, holdsModePick = true) {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await render(undefined, cwd, undefined, holdsModePick);
}

test("a new chat acpmux starts in full access draws its warning chip on the first frame", async () => {
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux({ modeId: "bypassPermissions", name: "Bypass permissions" });
  await render(reported("earlier", "default"));
  expect(access()).toEqual({ label: "Manual", warning: false });

  // A new chat, before acpmux answers again: its kept answer, warning included.
  await fresh();
  // The remembered mode is a live access menu while the new session is pending, so the person
  // can change it before the harness answers. It is no longer an inert pending chip.
  const pendingAccess = host.querySelector<HTMLButtonElement>(".acpmux-access-trigger");
  expect(pendingAccess).not.toBeNull();
  expect(pendingAccess?.disabled).toBe(false);
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
  await answer();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });

  // Its session reports the same mode: nothing changes.
  await render(reported("new", "bypassPermissions"));
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
});

test("the access chip keeps grant details in its menu without a count in the pill", async () => {
  await render(reported("chat", "default"), undefined, {
    grants: [{ id: "grant-1", label: "Always allow shell", onRemove: () => undefined }],
  });
  const chip = host.querySelector<HTMLElement>(".acpmux-mode")!;
  expect(chip.querySelector(".acpmux-access-grant-count")).toBeNull();
  expect(chip.querySelector(".acpmux-mode-text")?.textContent?.trim()).toBe("Manual");
  await act(async () => {
    const trigger = chip.querySelector<HTMLButtonElement>(".acpmux-access-trigger")!;
    const press = new MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 1, clientY: 1 });
    Object.defineProperties(press, { pointerId: { value: 1 }, pointerType: { value: "mouse" } });
    trigger.dispatchEvent(press);
  });
  expect(document.querySelector(".acpmux-access-grant-label")?.textContent).toBe("Always allow shell");
  expect(document.querySelector<HTMLButtonElement>(".acpmux-access-grant-remove")).not.toBeNull();
});

test("a kept answer that is wrong gives way to acpmux's answer", async () => {
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux({ modeId: "default", name: "Ask before edits" });
  await fresh();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
  await answer();
  expect(access()).toEqual({ label: "Manual", warning: false });
});

test("when acpmux sets no mode a new chat names none, whatever the last chat showed, and keeps the chip's place", async () => {
  await render(reported("earlier", "bypassPermissions"));
  localStorage.setItem("cmux.acpmux.lastChips", JSON.stringify({ claude: { mode: "Bypass permissions" } }));
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  // acpmux sets no mode (or predates the method): the kept answer goes too.
  const answer = await acpmux(undefined);
  await fresh();
  await answer();
  expect(access()).toEqual({ label: "Mode", warning: false });
});

test("a folder acpmux has not answered for names another folder's mode until its own answer replaces it", async () => {
  const { rememberStartMode } = await import("../src/agent-session/acpmux/startMode");
  // Another folder's chats start in full access; this folder's profile pins its own mode, so
  // acpmux sets none here (it answers none). Until it answers, the chip names the mode a chat most
  // likely starts in (Lucas 2026-10-24: never a bare "Mode" on this Mac), still a menu; this
  // folder's answer then replaces it.
  rememberStartMode("claude", "/elsewhere", { modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux(undefined);
  await fresh("/here");
  expect(host.querySelector("button.acpmux-access-trigger")).not.toBeNull();
  expect(access()!.label).toBe("Bypass permissions");
  await answer();
  expect(access()).toEqual({ label: "Mode", warning: false });
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

test("a pending chat whose pane cannot hold a mode pick keeps the inert chip", async () => {
  // No New Tab start and no harness switch running: a pick would reach no session, so the chip
  // names the start mode without offering a menu.
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux({ modeId: "bypassPermissions", name: "Bypass permissions" });
  await fresh(undefined, false);
  await answer();
  expect(host.querySelector(".acpmux-chip-pending.acpmux-mode")).not.toBeNull();
  expect(host.querySelector("button.acpmux-access-trigger")).toBeNull();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
});

test("a pending chat that starts in Plan keeps the inert chip: Plan is never an access row", async () => {
  await kept({ modeId: "plan", name: "Plan" });
  const answer = await acpmux({ modeId: "plan", name: "Plan" });
  await fresh();
  await answer();
  expect(host.querySelector(".acpmux-chip-pending.acpmux-mode")).not.toBeNull();
});

test("a New Tab chat with no start mode to name still offers the harness's modes, at none", async () => {
  // acpmux sets none here: the chip says "Mode", and a click opens the harness's own menu.
  const answer = await acpmux(undefined);
  await fresh();
  await answer();
  expect(access()).toEqual({ label: "Mode", warning: false });
  const trigger = host.querySelector<HTMLButtonElement>("button.acpmux-access-trigger");
  expect(trigger).not.toBeNull();
  expect(host.querySelector(".acpmux-chip-pending.acpmux-mode")).toBeNull();
  await act(async () => {
    const press = new MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 1, clientY: 1 });
    Object.defineProperties(press, { pointerId: { value: 1 }, pointerType: { value: "mouse" } });
    trigger!.dispatchEvent(press);
  });
  const rows = [...document.querySelectorAll(".acpmux-access-item")];
  const text = rows.map((row) => row.textContent ?? "").join("|");
  expect(text).toContain("Bypass permissions");
  expect(text).not.toContain("Plan");
});

test("an ask that fails is not acpmux's answer: the chip keeps what it showed", async () => {
  const { setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  // The socket closed under the ask: nothing was answered, so nothing is kept as "sets none".
  setStartModeSource(async () => {
    throw new Error("not connected");
  });
  await fresh();
  await act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
});

// Last: it fills the shared profile store (`harnessProfiles` keeps no reset), which every
// test above relies on being empty.
test("a pending chat's access menu names acpmux's start mode, never the mode this harness's last chat showed", async () => {
  const { harnessProfiles } = await import("../src/agent-session/acpmux/harnessProfiles");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  // The last Claude chat sat in "Ask before edits"; new chats start in full access.
  harnessProfiles.observe(reported("earlier", "default") as Snapshot["summary"]);
  await kept({ modeId: "bypassPermissions", name: "Bypass permissions" });
  const answer = await acpmux({ modeId: "bypassPermissions", name: "Bypass permissions" });
  await fresh();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
  expect(host.querySelector<HTMLButtonElement>(".acpmux-access-trigger")?.disabled).toBe(false);
  await answer();
  expect(access()).toEqual({ label: "Bypass permissions", warning: true });
});
