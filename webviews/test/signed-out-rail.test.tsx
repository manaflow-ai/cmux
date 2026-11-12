// cx-ae9eb: the model rail listed a harness this Mac's acpmux found signed out like any other, so a
// pick started a chat that failed on its first turn ("authentication failed"). At the composer's
// boundary: the real catalog and compact picker, and what the pane sends. A signed-out harness's
// tab offers Log In (its login command) in place of its models; a search lists them, and a pick of
// one signs in before any chat starts on it (harnessSetup.ts).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { until } from "./support/until";
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

/// The shortcut opens the same compact picker as the model button.
const openQuickPicker = () =>
  dom.window.dispatchEvent(
    new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }),
  );

const tabFor = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('.acpmux-cols-tab[role="tab"]')].find(
    (tab) => tab.getAttribute("aria-label") === name,
  );
/// The model rows of either menu: the columns' (a menu with a rail) or the list's (a started chat's).
const modelRows = () => [
  ...dom.window.document.querySelectorAll<HTMLElement>(
    '.acpmux-cols [role="listbox"] [role="option"], .acpmux-quick-menu .acpmux-quick-item[role="menuitemradio"]',
  ),
];
/// The models column's rows that are not models (notes, Log In, Install…).
const columnRows = () => [
  ...dom.window.document.querySelectorAll<HTMLElement>('.acpmux-cols [role="listbox"] .acpmux-cols-row'),
];

test("a signed-out harness offers Log In, never its models", async () => {
  const logins: string[] = [];
  const { sent, catalog } = await mount({
    harness: "claude",
    signIn: { signedOut: { codex: "codex login" }, logIn: (harness, login) => logins.push(`${harness}: ${login}`) },
  });
  const codex = catalog.harnesses.find((entry) => entry.id === "codex")!;
  await act(async () => {
    openQuickPicker();
  });
  const tab = tabFor(codex.name);
  expect(tab, "the Codex rail tab").toBeDefined();
  expect(tab!.title).toContain("Signed out");
  await act(async () => tab!.click());
  expect(tab!.getAttribute("aria-selected")).toBe("true");
  expect(modelRows().map((row) => row.textContent)).toEqual([]);
  expect(columnRows().map((row) => row.textContent)).toEqual(["Signed out", "Log In"]);
  const login = columnRows().find((row) => row.getAttribute("role") === "button");
  expect(login?.textContent).toBe("Log In");
  await act(async () => login!.click());
  expect(logins).toEqual(["codex: codex login"]);
  expect(sent).toEqual([]);
  // Log In closes the menu.
  expect(dom.window.document.querySelector(".acpmux-cols")).toBeNull();
});

// Leo 2026-10-26: "if user picks a model they don't have api key, we offer them to add credits or add
// their own api key". cmux credits pay only for the cmux model router: buying a plan signs no local
// harness in, so a signed-out Claude Code, Codex or Gemini tab offers its own Log In alone, even where
// the pane can run Add Credits… (the turn card offers that on the router's refusal). Its API key goes in
// through that Log In; a key saved in Settings > Accounts never reaches the harness's process.
test("a signed-out harness offers its own Log In alone, never credits or a key that cannot sign it in", async () => {
  const asked: string[] = [];
  const signIn = {
    signedOut: { codex: "codex login" },
    logIn: () => undefined,
    access: { addCredits: () => asked.push("credits") },
  };
  const { sent, catalog } = await mount({ harness: "claude", signIn });
  const codex = catalog.harnesses.find((entry) => entry.id === "codex")!;
  await act(async () => {
    openQuickPicker();
  });
  await act(async () => tabFor(codex.name)!.click());
  // The models column and the account card (the avatar opens it) are where a sign-in shows.
  const profile = dom.window.document.querySelector<HTMLButtonElement>(".acpmux-cols-profile");
  expect(profile, "the account avatar").not.toBeNull();
  await act(async () => profile!.click());
  const card = dom.window.document.querySelector<HTMLElement>(".acpmux-cols-card");
  expect(card, "the account card").not.toBeNull();
  const labels = [
    ...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-cols .acpmux-cols-row, .acpmux-cols button"),
  ].map((item) => item.textContent);
  expect(labels).toContain("Log In");
  expect(labels).toContain(`Sign in to ${codex.name}…`);
  expect(labels).not.toContain("Add Credits…");
  expect(labels).not.toContain("Add API Key…");
  expect(labels).not.toContain("Use an API key…");
  expect(asked).toEqual([]);
  expect(sent).toEqual([]);
});

// Lawrence 2026-11-07 ("search for any model ... it needs to 'just work'"): a search lists a
// signed-out harness's models too, after the ready ones and marked Signed out, and a pick of one
// opens its login (the pick's own gesture) and starts no chat until it is signed in.
test("a search lists a signed-out harness's models after the ready ones, and a pick signs in first", async () => {
  const logins: string[] = [];
  const { sent } = await mount({
    harness: "claude",
    signIn: {
      signedOut: { codex: "codex login" },
      logIn: (harness, login) => void logins.push(`${harness}: ${login}`),
    },
  });
  await act(async () => {
    openQuickPicker();
  });
  const input = dom.window.document.querySelector<HTMLInputElement>(".acpmux-cols-search input")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(input, "gpt");
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  // A signed-out row says so in its description (its tooltip is the name alone); only Codex is signed out here.
  const codexRows = modelRows().filter((row) => row.getAttribute("aria-description") === "Signed out");
  expect(codexRows.length).toBeGreaterThan(0);
  const headings = [...dom.window.document.querySelectorAll(".acpmux-cols .acpmux-cols-group")].map(
    (heading) => heading.textContent,
  );
  // Its heading says a pick signs in first.
  expect(headings).toContain("CodexSigned out");
  // Other providers can offer GPT models; those that are ready come first.
  if (headings.length > 1) expect(headings[0]).not.toBe("CodexSigned out");
  await act(async () => codexRows[0]!.click());
  await until(
    () => logins.length > 0,
    () => act(async () => {}),
  );
  expect(logins).toEqual(["codex: codex login"]);
  expect(sent).toEqual([]);
  (await import("../src/agent-session/acpmux/harnessSetup")).resetHarnessSetupForTests();
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
    openQuickPicker();
  });
  // A started chat's harness is fixed: its menu has no rail, only that harness's models.
  expect(dom.window.document.querySelector(".acpmux-quick-rail")).toBeNull();
  expect(modelRows().length).toBeGreaterThan(0);
  expect(dom.window.document.querySelector(".acpmux-quick-menu")?.textContent).not.toContain("Log In");
});

test("Starred lists no model of a signed-out harness", async () => {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const first = (id: string) => BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === id)!.models[0]!.id;
  const [codexModel, claudeModel] = [first("codex"), first("claude")];
  // The picker reads its stars when it mounts.
  dom.window.localStorage.setItem("cmux.model-picker.favorites", JSON.stringify([codexModel, claudeModel]));
  await mount({ harness: "claude", signIn: { signedOut: { codex: "codex login" }, logIn: () => undefined } });
  await act(async () => {
    openQuickPicker();
  });
  const starred = tabFor("Starred");
  expect(starred, "the Starred tab").toBeDefined();
  await act(async () => starred!.click());
  const names = modelRows().map((row) => row.textContent ?? "");
  expect(names).toHaveLength(1);
  expect(names[0]).toContain(
    BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === "claude")!.models[0]!.name.replace(/^Claude /, ""),
  );
});
