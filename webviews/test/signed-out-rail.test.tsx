// cx-ae9eb: the model rail listed a harness this Mac's acpmux found signed out like any other, so a
// pick started a chat that failed on its first turn ("authentication failed"). At the composer's
// boundary: the real catalog and picker, and what the pane sends. A signed-out harness's tab is
// dimmed and offers Log In (its login command) in place of its models, and no pick or search
// reaches its models. The full picker is opened by More models' shortcut: the model button opens the
// compact menu first (Leo 2026-10-20).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
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

afterEach(() => {
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

type Sent = { method: "model" | "harness" | "effort"; value: string };

async function mount(start: {
  signIn?: import("../src/agent-session/acpmux/signIn").SignIn;
  harness: string;
  extra?: { id: string; name: string; family?: string; unavailable?: string; probeFailed?: boolean }[];
  /// Completed turns of the shown chat: none (the default) is a chat with no message yet.
  turnCount?: number;
  /// acpmux's session list (the sidebar's Chats).
  sessions?: import("../src/agent-session/acpmux/model").AcpmuxSnapshot["sessions"];
}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  // acpmux's harness list: what `_acpmux/models` reports for each catalog harness.
  const acpmux: Snapshot["catalog"] = BUNDLED_MODEL_CATALOG.harnesses
    .map((harness) => ({
      id: harness.id,
      name: harness.name,
      family: harness.families[0],
      models: harness.models.map((model) => ({ id: model.id, name: model.name })),
    }))
    .concat((start.extra ?? []).map((entry) => ({ family: entry.id, ...entry, models: [] }))) as Snapshot["catalog"];
  const sent: Sent[] = [];
  let session = 0;
  function Host() {
    const [state, setState] = useState({
      sessionId: `s${session}`,
      harness: start.harness,
      model: "default",
      effort: "medium",
    });
    const snapshot: Snapshot = {
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: start.sessions ?? [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: acpmux,
      summary: {
        sessionId: state.sessionId,
        harness: state.harness,
        model: state.model,
        turnCount: start.turnCount ?? 0,
        configOptions: [
          {
            id: "effort",
            name: "Effort",
            category: "thought_level",
            currentValue: state.effort,
            options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
          },
        ],
      },
    } as Snapshot;
    const picker = usePickerCatalog(snapshot.catalog, { harness: state.harness }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={(model) => {
          sent.push({ method: "model", value: model });
          setState((current) => ({ ...current, model }));
        }}
        onMode={() => undefined}
        onEffort={(_id, value) => {
          sent.push({ method: "effort", value });
          setState((current) => ({ ...current, effort: value }));
        }}
        onHarness={(harness, model) => {
          sent.push({ method: "harness", value: model ? `${harness}/${model}` : harness });
          session += 1;
          setState({ sessionId: `s${session}`, harness, model: model ?? "default", effort: "medium" });
        }}
        showPlan={false}
        {...(start.signIn ? { signIn: start.signIn } : {})}
      />
    );
  }
  const client = new QueryClient();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Host />
      </QueryClientProvider>,
    );
  });
  return { sent, catalog: BUNDLED_MODEL_CATALOG };
}

/// The full picker, as More models' shortcut opens it (Cmd-Ctrl-M): the composer's model button opens
/// the compact menu first (Leo 2026-10-20: one model button), and the full picker is reached from it.
const openFullPicker = () =>
  dom.window.dispatchEvent(
    new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }),
  );

const tabFor = (name: string) =>
  [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
    (button) => button.title.split(" · ")[0] === name,
  );
const modelRows = () => [
  ...host.querySelectorAll<HTMLElement>('.acpmux-mp-models [role="option"][data-key^="model:"]'),
];

test("a signed-out harness offers Log In, never its models", async () => {
  const logins: string[] = [];
  const { sent, catalog } = await mount({
    harness: "claude",
    signIn: { signedOut: { codex: "codex login" }, logIn: (harness, login) => logins.push(`${harness}: ${login}`) },
  });
  const codex = catalog.harnesses.find((entry) => entry.id === "codex")!;
  await act(async () => {
    openFullPicker();
  });
  const tab = tabFor(codex.name);
  expect(tab, "the Codex rail tab").toBeDefined();
  expect(tab!.getAttribute("aria-disabled")).toBe("true");
  await act(async () => tab!.click());
  expect(modelRows().map((row) => row.textContent)).toEqual([]);
  // No More models fold either: it would open models a pick refuses (seen on a DEV build).
  expect(host.querySelector(".acpmux-mp-older")).toBeNull();
  const login = host.querySelector<HTMLButtonElement>(".acpmux-mp-login");
  expect(login?.textContent).toBe("Log In");
  await act(async () => login!.click());
  expect(logins).toEqual(["codex: codex login"]);
  expect(sent).toEqual([]);
});

test("a search never lists a signed-out harness's models", async () => {
  const { sent, catalog } = await mount({
    harness: "claude",
    signIn: { signedOut: { codex: "codex login" }, logIn: () => undefined },
  });
  const codexModels = new Set(catalog.harnesses.find((entry) => entry.id === "codex")!.models.map((model) => model.id));
  await act(async () => {
    openFullPicker();
  });
  const input = host.querySelector<HTMLInputElement>(".acpmux-mp input")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(input, "gpt");
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  const keys = modelRows().map((row) => row.dataset.key!.slice("model:".length));
  expect(keys.filter((key) => codexModels.has(key))).toEqual([]);
  expect(sent).toEqual([]);
});

// Review of #20692: a chat already running on a harness keeps its models (a stale or wrong row
// must never lock the person out of the chat they are in), and Starred lists no model a pick
// would refuse.
test("the running chat's own harness keeps its models", async () => {
  await mount({
    harness: "codex",
    turnCount: 1,
    signIn: { signedOut: { codex: "codex login" }, logIn: () => undefined },
  });
  await act(async () => {
    openFullPicker();
  });
  // A started chat's harness is fixed: its menu has no rail, only that harness's models.
  expect(host.querySelector(".acpmux-mp-harness")).toBeNull();
  expect(modelRows().length).toBeGreaterThan(0);
  expect(host.querySelector(".acpmux-mp-login")).toBeNull();
});

test("Starred lists no model of a signed-out harness", async () => {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const first = (id: string) => BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === id)!.models[0]!.id;
  const [codexModel, claudeModel] = [first("codex"), first("claude")];
  // The picker reads its stars when it mounts.
  dom.window.localStorage.setItem("cmux.model-picker.favorites", JSON.stringify([codexModel, claudeModel]));
  await mount({ harness: "claude", signIn: { signedOut: { codex: "codex login" }, logIn: () => undefined } });
  await act(async () => {
    openFullPicker();
  });
  const starred = host.querySelector<HTMLButtonElement>('.acpmux-mp-rail-list [aria-label="Starred"]');
  expect(starred, "the Starred tab").not.toBeNull();
  await act(async () => starred!.click());
  const keys = modelRows().map((row) => row.dataset.key!.slice("model:".length));
  expect(keys).toEqual([claudeModel]);
});
