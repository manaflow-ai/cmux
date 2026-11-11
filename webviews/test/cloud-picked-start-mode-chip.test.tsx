// l10n-allow-file: test fixtures.
// A new chat on this Mac with Settings' Start New Chats In set to Cloud (or Cloud picked in the
// composer's Where row) sends its first message to a Cloud machine (cloud.startChat). That machine
// started the chat asking (the Cloud start's policy `ask`) while the access chip named this Mac's
// start mode, "Bypass permissions" (cloud-ergo-start-chat capture, 2026-11-09). Leo, 2026-11-11:
// "but shouldnt the user be allowed to just go through with stuff?". The send now carries the mode
// the chip names (cloudStartMode), the person's own Cloud machine starts the chat in it, and the chip
// names it with Cloud picked as it does for a chat on this Mac. The real composer chips, in JSDOM.
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(() => {
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
async function newChat(startsOnCloud: boolean): Promise<Snapshot> {
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
    summary: { sessionId: "", harness: "claude", turnCount: 0, cwd: FOLDER } as Summary,
    ...(startsOnCloud ? { startsOnCloud: true } : {}),
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

test("with Cloud picked, the chip names the mode the Cloud chat starts in", async () => {
  await render(await newChat(true));
  expect(chipText()).toBe("Bypass permissions");
});

test("a Cloud send carries the mode the chip names", async () => {
  const { cloudStartMode } = await import("../src/agent-session/acpmux/cloudRun");
  const snapshot = await newChat(true);
  await render(snapshot);
  expect(cloudStartMode(snapshot.summary, undefined, FOLDER)).toEqual({ mode: "bypassPermissions" });
  // The person's pick (a switch's held mode) goes instead of this Mac's answer.
  const picked = {
    ...snapshot.summary!,
    modes: { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }] },
  } as Summary;
  expect(cloudStartMode(picked, "claude", FOLDER)).toEqual({ mode: "default" });
  // Another harness, a folder acpmux has not answered for, or a chat that already runs: none.
  expect(cloudStartMode(snapshot.summary, "codex", FOLDER)).toEqual({});
  expect(cloudStartMode(snapshot.summary, undefined, "/home/dev/elsewhere")).toEqual({});
  expect(cloudStartMode({ ...snapshot.summary!, sessionId: "s1" }, undefined, FOLDER)).toEqual({});
});

test("the Cloud start request names the mode to the host", async () => {
  const { startCloudChat } = await import("../src/agent-session/acpmux/cloudRun");
  const calls: [string, Record<string, unknown>][] = [];
  const call = async (method: string, params: Record<string, unknown>) => void calls.push([method, params]);
  await startCloudChat(call, { task: "go", harness: "claude", mode: "bypassPermissions" }, "k");
  expect(calls[0]?.[1]).toMatchObject({ harness: "claude", mode: "bypassPermissions" });
  await startCloudChat(call, { task: "go" }, "k");
  expect("mode" in (calls[1]?.[1] ?? {})).toBe(false);
});
