// The missing-access card (paid-plan.md section 4; Lawrence 2026-10-23: "if they don't have api key
// set up for it, we will show error message, giving user button to add their own api key, as well
// as add credits for cmux inference"). One card in the composer's notice slot: Add API key (a native
// sheet stores it in the Keychain, then the chat moves onto that key's route and sends again), Use
// cmux credits (the chat moves onto the cmux model router and sends again), and, once the router
// answers that credits ran out, Add credits: an amount opens Checkout, and when the balance rises
// the blocked turn goes again by itself.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { missingAccess, MissingAccessNotice, type AccessNeed } from "./MissingAccessNotice";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Call = { method: string; params: Record<string, unknown>; resolve: (value: unknown) => void };

/// The host: each call waits for the test's answer, as a sheet or a payment would.
function host() {
  const calls: Call[] = [];
  const native = (method: string, params: Record<string, unknown> = {}) =>
    new Promise<unknown>((resolve) => calls.push({ method, params, resolve }));
  return { calls, native };
}

type Done = { routes: string[]; credits: number; retries: number; logIns: number };

async function render(
  container: HTMLElement,
  need: AccessNeed | undefined,
  native: (method: string, params?: Record<string, unknown>) => Promise<unknown>,
  extra: { harness?: string; family?: string; canUseCredits?: boolean; login?: boolean; clock?: () => number } = {},
) {
  const done: Done = { routes: [], credits: 0, retries: 0, logIns: 0 };
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <MissingAccessNotice
        need={need}
        harness={extra.harness ?? "claude"}
        family={extra.family ?? "claude"}
        name={extra.harness === "codex" ? "Codex" : "Claude Code"}
        native={native}
        canUseCredits={extra.canUseCredits ?? true}
        {...(extra.login ? { onLogIn: () => void (done.logIns += 1) } : {})}
        onUseRoute={async (routeId) => void done.routes.push(routeId)}
        onUseCredits={async () => void (done.credits += 1)}
        onRetry={() => void (done.retries += 1)}
        {...(extra.clock ? { now: extra.clock } : {})}
      />,
    );
  });
  return done;
}

const card = (container: HTMLElement) => container.querySelector<HTMLElement>("[data-access-notice]");
const action = (container: HTMLElement, name: string) =>
  container.querySelector<HTMLButtonElement>(`[data-access-action="${name}"]`);
async function press(container: HTMLElement, name: string) {
  const button = action(container, name);
  expect(button, `${name} in ${card(container)?.innerHTML}`).not.toBeNull();
  await act(async () => button!.click());
}
async function answer(call: Call | undefined, value: unknown) {
  expect(call).toBeDefined();
  await act(async () => call!.resolve(value));
}

test("which failures are missing access: a key or sign-in refusal, and the router's 402s", () => {
  expect(missingAccess("Invalid API key · Please run /login")).toBe("key");
  expect(missingAccess("API Error: 401 authentication_error")).toBe("key");
  expect(
    missingAccess(
      'API Error: 402 {"error":{"code":"credits.insufficient","message":"Not enough cmux credits for this call.","type":"insufficient_quota"}}',
    ),
  ).toBe("credits");
  expect(missingAccess('402 {"error":{"code":"inference.plan_required"}}')).toBe("credits");
  // Capacity and network failures are not missing access.
  expect(missingAccess("429 Too Many Requests")).toBeUndefined();
  expect(missingAccess("ECONNREFUSED 127.0.0.1:4000")).toBeUndefined();
  expect(missingAccess(undefined)).toBeUndefined();
});

test("no need, no card", async () => {
  const container = installDom();
  await render(container, undefined, host().native);
  expect(card(container)).toBeNull();
});

test("Add API key stores the key through the host's sheet, moves the chat onto its route and sends again", async () => {
  const container = installDom();
  const { calls, native } = host();
  const done = await render(container, "key", native);
  expect(card(container)?.dataset.accessNotice).toBe("key");
  expect(action(container, "useCredits")).not.toBeNull();
  await press(container, "addKey");
  expect(calls[0]?.method).toBe("access.addKey");
  // The page names the harness; the key itself never passes through it.
  expect(calls[0]?.params).toEqual({ harness: "claude", family: "claude" });
  await answer(calls[0], { routeId: "apikey-anthropic" });
  expect(done.routes).toEqual(["apikey-anthropic"]);
  expect(done.retries).toBe(1);
});

test("a cancelled sheet changes nothing", async () => {
  const container = installDom();
  const { calls, native } = host();
  const done = await render(container, "key", native);
  await press(container, "addKey");
  await answer(calls[0], { cancelled: true });
  expect(done.routes).toEqual([]);
  expect(done.retries).toBe(0);
  expect(card(container)).not.toBeNull();
});

test("Use cmux credits moves the chat onto the cmux model router and sends again", async () => {
  const container = installDom();
  const done = await render(container, "key", host().native);
  await press(container, "useCredits");
  expect(done.credits).toBe(1);
  expect(done.retries).toBe(1);
});

test("a chat the router cannot serve says so and offers no Use cmux credits", async () => {
  const container = installDom();
  await render(container, "key", host().native, { harness: "codex", family: "codex", canUseCredits: false });
  expect(action(container, "useCredits")).toBeNull();
  expect(card(container)?.textContent).toContain("Claude Code");
  expect(action(container, "addKey")).not.toBeNull();
});

test("a signed-out harness keeps its Log In beside the two other ways", async () => {
  const container = installDom();
  const done = await render(container, "signedOut", host().native, { login: true });
  await press(container, "login");
  expect(done.logIns).toBe(1);
  expect(action(container, "addKey")).not.toBeNull();
  expect(action(container, "useCredits")).not.toBeNull();
});

test("credits ran out: an amount opens Checkout, the balance rising sends the turn again, and the card says how long it took", async () => {
  const container = installDom();
  const { calls, native } = host();
  let now = 1_000;
  const done = await render(container, "credits", native, { clock: () => now });
  expect(card(container)?.dataset.accessNotice).toBe("credits");
  const amounts = [...container.querySelectorAll<HTMLButtonElement>("[data-access-amount]")].map(
    (button) => button.dataset.accessAmount,
  );
  expect(amounts).toEqual(["10", "20", "50", "100"]);
  await act(async () => container.querySelector<HTMLButtonElement>('[data-access-amount="20"]')!.click());
  expect(calls[0]?.method).toBe("credits.topup");
  expect(calls[0]?.params).toEqual({ usd: 20 });
  await answer(calls[0], { session: "cs_test_a1", before_usd: 0.4, opened_in: "cmuxBrowser" });
  expect(calls[1]?.method).toBe("credits.wait");
  expect(calls[1]?.params).toEqual({ above: 0.4, session: "cs_test_a1" });
  expect(card(container)?.dataset.accessPhase).toBe("paying");
  expect(done.retries).toBe(0);
  now = 8_200;
  await answer(calls[1], { available_usd: 20.4 });
  expect(done.retries).toBe(1);
  expect(card(container)?.dataset.accessPhase).toBe("added");
  expect(card(container)?.dataset.accessSeconds).toBe("7.2");
});

test("a wait that ends without the payment offers the amounts again, and sends nothing", async () => {
  const container = installDom();
  const { calls, native } = host();
  const done = await render(container, "credits", native);
  await act(async () => container.querySelector<HTMLButtonElement>('[data-access-amount="10"]')!.click());
  await answer(calls[0], { session: "cs_test_b2", before_usd: 0 });
  await answer(calls[1], { timedOut: true, available_usd: 0 });
  expect(done.retries).toBe(0);
  expect(container.querySelector('[data-access-amount="10"]')).not.toBeNull();
});
