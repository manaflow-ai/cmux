// Leo 2026-10-26: "if user picks a model they don't have api key, we offer them to add credits or add
// their own api key". This PR ships the Add Credits half: the cmux model router refuses a caller with
// no paid plan and no credits (402 `inference.plan_required`) or a credit-funded caller, still without
// a paid plan, whose credits do not cover the call (`credits.insufficient`; backend inference/route.ts
// resolveCaller). Both are lifted by a paid plan, so both offer Add Credits… (the paid-plan path). Add
// API Key… waits for key plumbing (no placement makes a saved key usable yet), so no card offers it.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { failureCopy, failureKind, failureRecovery } from "../src/agent-session/acpmux/failureCopy";
import { ACCESS_ACTIONS } from "../src/agent-session/acpmux/accessOffer";
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
  for (const [message, code] of [
    [noCredits, undefined],
    [lowCredits, undefined],
    [undefined, "inference.plan_required"],
    [undefined, "credits.insufficient"],
  ] as const)
    expect(failureCopy(t, message, router, code)).toBe(
      "cmux model router needs cmux credits or your own API key for this model.",
    );
  // After credits land, the same prompt goes again.
  expect(failureRecovery("needs-credits")).toBe("retry");
  // Other text that only mentions cmux credits is not the router's refusal.
  expect(failureKind("agent process closed\nstderr: see the cmux credits docs", router)).toBe("agent-exited");
  expect(failureKind("cmux credits: balance sync failed", router)).toBe("other");
  // A provider's own key or quota failure stays what it was.
  expect(failureKind("invalid x-api-key", router)).toBe("invalid-key");
  expect(failureKind("API Error: 429 rate_limit_error", router)).toBe("rate-limited");
});

test("Add Credits… is the paid-plan path, the only access action", () => {
  expect(ACCESS_ACTIONS).toEqual({ addCredits: "palette.pro.upgrade" });
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

async function render(error: string, access = true) {
  const calls: string[] = [];
  const actions = {
    route: router,
    retry: () => calls.push("retry"),
    switchModel: () => calls.push("switch"),
    ...(access ? { access: { addCredits: () => calls.push("credits") } } : {}),
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

test("a refused turn leads with Add Credits…, then Retry and Switch model, on both refusals", async () => {
  for (const error of [noCredits, lowCredits, '{"error":{"code":"credits.insufficient"}}']) {
    const calls = await render(error);
    expect(card().getAttribute("data-failure-kind")).toBe("needs-credits");
    expect(actionLabels()).toEqual(["Add Credits…", "Retry", "Switch model"]);
    // The card keeps one filled button: Add Credits….
    expect([...card().querySelectorAll(".cv-turn-error__primary")].map((element) => element.textContent)).toEqual([
      "Add Credits…",
    ]);
    expect(button("Add API Key…")).toBeUndefined();
    await act(async () => button("Add Credits…")!.click());
    await act(async () => button("Retry")!.click());
    expect(calls).toEqual(["credits", "retry"]);
  }
});

test("a pane that cannot run the app's actions still names the way out, with no dead buttons", async () => {
  await render(noCredits, false);
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
