// Leo 2026-10-26: "if user picks a model they don't have api key, we offer them to add credits or add
// their own api key". The cmux model router refuses a caller with no plan and no credits (402
// `inference.plan_required`, or `credits.insufficient`), and its Messages endpoint passes on only the
// text. The failed turn names the way out and offers Add Credits… and Add API Key…, never a dead end.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { failureCopy, failureKind, failureRecovery } from "../src/agent-session/acpmux/failureCopy";
import { ACCESS_ACTIONS, addKeyParams, keyProvider } from "../src/agent-session/acpmux/accessOffer";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const t = translatorFor("en");
const router = { name: "cmux model router", harness: "cmux" };
const noCredits =
  'API Error: 402 {"type":"error","error":{"type":"billing_error","message":"AI models need cmux credits, your own API key, or a paid plan"}}';
const lowCredits =
  'API Error: 402 {"type":"error","error":{"type":"billing_error","message":"Not enough cmux credits for this call. Add credits or use your own API key."}}';

test("the router's credit refusals read as needs-credits, not a key, quota or generic failure", () => {
  for (const message of [
    noCredits,
    lowCredits,
    '{"error":{"code":"inference.plan_required","message":"..."}}',
    '{"error":{"code":"credits.insufficient"}}',
  ])
    expect([message, failureKind(message, router)]).toEqual([message, "needs-credits"]);
  // The router's code alone, typed, with no words.
  expect(failureKind(undefined, router, "inference.plan_required")).toBe("needs-credits");
  expect(failureKind("agent process closed", router, "credits.insufficient")).toBe("needs-credits");
  expect(failureCopy(t, undefined, router, "credits.insufficient")).toBe(
    "cmux model router needs cmux credits or your own API key for this model.",
  );
  expect(failureCopy(t, noCredits, router)).toBe(
    "cmux model router needs cmux credits or your own API key for this model.",
  );
  // After credits land, the same prompt goes again.
  expect(failureRecovery("needs-credits")).toBe("retry");
  // A provider's own key or quota failure stays what it was.
  expect(failureKind("invalid x-api-key", router)).toBe("invalid-key");
  expect(failureKind("API Error: 429 rate_limit_error", router)).toBe("rate-limited");
});

test("Add API Key… opens the Accounts row of the harness's provider, else Accounts itself", () => {
  expect(keyProvider("claude")).toBe("anthropic");
  expect(keyProvider("claude-sr")).toBe("anthropic");
  expect(keyProvider("codex")).toBe("openai");
  expect(keyProvider("gemini")).toBe("gemini");
  expect(keyProvider("cmux")).toBeUndefined();
  expect(keyProvider("constructor")).toBeUndefined();
  expect(keyProvider(undefined)).toBeUndefined();
  expect(addKeyParams("codex")).toEqual({ id: ACCESS_ACTIONS.addKey, provider: "openai" });
  expect(addKeyParams("cmux")).toEqual({ id: ACCESS_ACTIONS.addKey });
  expect(ACCESS_ACTIONS).toEqual({ addKey: "accounts.show", addCredits: "palette.pro.upgrade" });
});

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
const savedExperiments = globalThis.cmuxExperiments;
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  globalThis.cmuxExperiments = savedExperiments;
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const failed = (error: string) => ({
  id: "summary-2",
  version: 1,
  at: Date.now(),
  kind: "turnSummary",
  seq: 2,
  status: "failed",
  durationMs: 1_800,
  error,
  prompt: "Add retries to the fetch helper",
  retryRowId: "user-1",
});
const card = () => host.querySelector(".cv-turn-error")!;
const actionLabels = () =>
  [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
const button = (label: string) =>
  [...card().querySelectorAll("button")].find((element) => element.textContent === label);

async function render(error: string, arm?: string, access = true) {
  globalThis.cmuxExperiments = arm ? { "access-offer": arm } : {};
  const calls: string[] = [];
  const actions = {
    route: router,
    retry: () => calls.push("retry"),
    switchModel: () => calls.push("switch"),
    ...(access
      ? {
          access: {
            addKey: (harness?: string) => calls.push(`key:${harness}`),
            addCredits: () => calls.push("credits"),
          },
        }
      : {}),
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <TurnFooter row={failed(error)} />
      </TurnActionsContext.Provider>,
    ),
  );
  return calls;
}

test("a refused turn leads with Add Credits…, Add API Key… beside it, then Retry and Switch model", async () => {
  const calls = await render(noCredits);
  expect(card().getAttribute("data-failure-kind")).toBe("needs-credits");
  expect(actionLabels()).toEqual(["Add Credits…", "Add API Key…", "Retry", "Switch model"]);
  // The card keeps one filled button: Add Credits….
  expect([...card().querySelectorAll(".cv-turn-error__primary")].map((element) => element.textContent)).toEqual([
    "Add Credits…",
  ]);
  await act(async () => button("Add Credits…")!.click());
  await act(async () => button("Add API Key…")!.click());
  await act(async () => button("Retry")!.click());
  expect(calls).toEqual(["credits", "key:cmux", "retry"]);
});

test("the key-first arm fills Add API Key…; the link arm leaves Retry filled", async () => {
  await render(lowCredits, "key-first");
  expect(actionLabels().slice(0, 2)).toEqual(["Add API Key…", "Add Credits…"]);
  expect(button("Add API Key…")!.classList.contains("cv-turn-error__primary")).toBe(true);
  const calls = await render(lowCredits, "link");
  expect(actionLabels()).toEqual(["Retry", "Switch model"]);
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(true);
  const links = [...card().querySelectorAll(".cv-turn-error__cause .cv-turn-error__offer-link")];
  expect(links.map((element) => element.textContent)).toEqual(["Add Credits…", "Add API Key…"]);
  await act(async () => (links[1] as HTMLButtonElement).click());
  expect(calls).toEqual(["key:cmux"]);
});

test("a pane that cannot run the app's actions still names the way out, with no dead buttons", async () => {
  await render(noCredits, undefined, false);
  expect(card().querySelector(".cv-turn-error__cause")!.textContent).toContain(
    "needs cmux credits or your own API key",
  );
  expect(actionLabels()).toEqual(["Retry", "Switch model"]);
});

test("another failure shows no access offer", async () => {
  await render("invalid x-api-key");
  expect(button("Add Credits…")).toBeUndefined();
  expect(button("Add API Key…")).toBeUndefined();
});
