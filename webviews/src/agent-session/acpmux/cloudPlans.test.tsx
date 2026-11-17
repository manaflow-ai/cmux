// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// Cloud plans (cloudPlans.ts, cloudPlanSubscribe.ts) and their cards (CloudStartView): the plan the app's list
// reply names, the pricing card for no plan, Subscribe's host call and its one retry once the plan is on, and the
// folder that needs a larger machine than the plan includes.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { CloudStartView } from "./CloudStartView";
import { currentCloudPlan, refreshCloudMachines, setCloudPlanForTest } from "./cloudMachines";
import { cloudPlanFromReply, cloudPlanHoldsSend, cloudSizeLocked, type CloudPlanView } from "./cloudPlans";
import { createCloudPlanSubscribe } from "./cloudPlanSubscribe";
import { cloudStartEnded, cloudStartPlanHeld, type CloudStartProgress } from "./cloudStartProgress";
import { settleReact } from "../../../test/support/domTeardown";

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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  setCloudPlanForTest();
});

const begun: CloudStartProgress = { key: "k", task: "fix the build", state: "starting", folder: "paint" };
const NONE: CloudPlanView = { state: "none", id: null, maxSize: null };
const PRO: CloudPlanView = { state: "active", id: "pro", maxSize: "lg" };
const MAX: CloudPlanView = { state: "active", id: "max", maxSize: "2xl" };

/// A host for the store: records each call, and answers or refuses Subscribe.
function fakeHost(refuse?: { message: string }) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const call = (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    return refuse ? Promise.reject(new Error(refuse.message)) : Promise.resolve({ opened: true });
  };
  return { calls, call };
}

/// The page's key state, driven by the test: `back()` is the page becoming the key one again.
function fakePage() {
  let run: (() => void) | undefined;
  return {
    watchKey: (next: () => void) => {
      run = next;
      return () => {
        run = undefined;
      };
    },
    isKey: () => true,
    back: () => run?.(),
    watching: () => run !== undefined,
  };
}

test("the plan of a list reply: only an explicit none holds a send; unknown, active and an older reply never do", async () => {
  expect(cloudPlanFromReply({ plan: { state: "none", id: null, max_size: null } })).toEqual(NONE);
  expect(cloudPlanFromReply({ plan: { state: "active", id: "pro", max_size: "lg" } })).toEqual(PRO);
  for (const reply of [
    { plan: { state: "unknown", id: null, max_size: null } },
    {},
    { plan: null },
    { plan: "none" },
    { plan: { state: "None" } },
    null,
  ])
    expect(cloudPlanFromReply(reply).state, JSON.stringify(reply)).toBe("unknown");
  expect(cloudPlanFromReply({ plan: { state: "active", id: "pro", max_size: "huge" } }).maxSize).toBeNull();
  expect(cloudPlanHoldsSend(NONE)).toBe(true);
  for (const plan of [PRO, cloudPlanFromReply({}), cloudPlanFromReply({ plan: { state: "unknown" } })])
    expect(cloudPlanHoldsSend(plan)).toBe(false);
  // The page's copy follows the app's reply; a signed-out reply, an older one without `plan`, or a refused read is
  // unknown, never none.
  const read = async (reply: unknown) => {
    await refreshCloudMachines(() => Promise.resolve(reply));
    return currentCloudPlan().state;
  };
  expect(await read({ signedIn: true, loaded: true, machines: [], plan: { state: "none" } })).toBe("none");
  expect(await read({ signedIn: true, loaded: true, machines: [] })).toBe("unknown");
  expect(await read({ signedIn: false, plan: { state: "none" } })).toBe("unknown");
  await read({ signedIn: true, loaded: true, machines: [], plan: { state: "none" } });
  await refreshCloudMachines(() => Promise.reject(new Error("refused")));
  expect(currentCloudPlan().state).toBe("unknown");
});

test("a send held for want of a plan and the platform's refusal both show the pricing card in the start's place", () => {
  const held = cloudStartPlanHeld("plan-held-1", "fix the build", "/Users/me/paint");
  expect(held).toMatchObject({ state: "failed", code: "cloud_plan_required", folder: "paint", refusedHere: true });
  const refused = cloudStartEnded(begun, "k", { ok: false, code: "cloud_plan_required", message: "Needs a plan." });
  for (const start of [held, refused!]) {
    const html = renderToStaticMarkup(<CloudStartView start={start} onRunHere={() => undefined} />);
    expect(html).toContain('data-plans="true"');
    expect(html).toContain('data-plan="pro"');
    expect(html).toContain('data-plan="max"');
    expect(html).toContain('data-action="run-here"');
    expect(html).not.toContain("acpmux-cloud-start__retry");
  }
});

test("Subscribe asks the host for its plan; a refusal says why under the buttons", async () => {
  const host = fakeHost();
  const page = fakePage();
  const store = createCloudPlanSubscribe({ ...host, ...page, readPlan: async () => NONE });
  const container = installDom();
  root = createRoot(container);
  const held = cloudStartPlanHeld("plan-held-1", "fix the build", undefined);
  await act(async () => root?.render(<CloudStartView start={held} planStore={store} />));
  await act(async () => container.querySelector<HTMLButtonElement>('[data-plan="max"] button')?.click());
  await act(async () => container.querySelector<HTMLButtonElement>('[data-plan="pro"] button')?.click());
  expect(host.calls).toEqual([
    { method: "cloud.plan.subscribe", params: { plan: "max" } },
    { method: "cloud.plan.subscribe", params: { plan: "pro" } },
  ]);
  expect(store.snapshot().waiting).toBe(true);
  const refusing = fakeHost({ message: "Checkout isn't available for this team." });
  const refusedStore = createCloudPlanSubscribe({ ...refusing, ...fakePage() });
  await act(async () => root?.render(<CloudStartView start={held} planStore={refusedStore} />));
  await act(async () => container.querySelector<HTMLButtonElement>('[data-plan="pro"] button')?.click());
  expect(container.querySelector("[data-subscribe-error]")?.textContent).toBe(
    "Checkout isn't available for this team.",
  );
  expect(refusedStore.snapshot().waiting).toBe(false);
});

test("back from the browser, the plan is read again and the held start goes once it is on, only once", async () => {
  const host = fakeHost();
  const page = fakePage();
  const plans: CloudPlanView[] = [NONE, PRO, PRO];
  let reads = 0;
  let retried = 0;
  const store = createCloudPlanSubscribe({
    ...host,
    ...page,
    readPlan: async () => plans[reads++] ?? PRO,
    onReady: () => void retried++,
  });
  // Before Subscribe, the page becoming the key one reads nothing.
  page.back();
  expect(reads).toBe(0);
  store.start("pro", (plan) => plan.state === "active");
  await Promise.resolve();
  expect(page.watching()).toBe(true);
  // Still no plan: the card stays, and the next return reads again.
  page.back();
  await Promise.resolve();
  await Promise.resolve();
  expect(retried).toBe(0);
  page.back();
  await Promise.resolve();
  await Promise.resolve();
  expect(retried).toBe(1);
  expect(store.snapshot().waiting).toBe(false);
  expect(page.watching()).toBe(false);
  page.back();
  await Promise.resolve();
  expect(retried).toBe(1);
  expect(reads).toBe(2);
  // A reset (the card went) drops a wait: a plan read after it starts nothing.
  let droppedRetries = 0;
  const droppedPage = fakePage();
  const second = createCloudPlanSubscribe({
    ...fakeHost(),
    ...droppedPage,
    readPlan: async () => PRO,
    onReady: () => void droppedRetries++,
  });
  second.start("max", (plan) => plan.state === "active");
  await Promise.resolve();
  second.reset();
  droppedPage.back();
  await Promise.resolve();
  expect(droppedRetries).toBe(0);
  expect(second.snapshot().waiting).toBe(false);
});

test("a folder that needs a larger machine names its size, offers the plan that includes it, This Mac and Retry", async () => {
  const locked = cloudStartEnded(begun, "k", {
    ok: false,
    code: "cloud_size_locked",
    details: { needed: "xl", allowed: "lg", upgrade_plan: "max", folder_bytes: 60_000_000_000 },
  });
  expect(locked).toMatchObject({
    state: "failed",
    code: "cloud_size_locked",
    retryable: true,
    sizeLocked: { needed: "xl", allowed: "lg", upgradePlan: "max" },
    message: "This folder needs a machine with 16 vCPU and 32 GB memory, more than your plan includes.",
  });
  const host = fakeHost();
  const page = fakePage();
  const plans: CloudPlanView[] = [PRO, MAX];
  let retried = 0;
  const store = createCloudPlanSubscribe({
    ...host,
    ...page,
    readPlan: async () => plans.shift() ?? MAX,
    onReady: () => void retried++,
  });
  const container = installDom();
  root = createRoot(container);
  await act(async () =>
    root?.render(
      <CloudStartView start={locked!} planStore={store} onRunHere={() => undefined} onRetry={() => undefined} />,
    ),
  );
  expect(container.textContent).toContain("16 vCPU and 32 GB memory");
  expect(container.textContent).not.toContain("xl");
  const buttons = [...container.querySelectorAll<HTMLButtonElement>("[data-size-locked] button")];
  expect(buttons.map((button) => [button.textContent, button.getAttribute("data-role")])).toEqual([
    ["Upgrade to Max", "default"],
    ["Run on This Mac", null],
    ["Retry", null],
  ]);
  // One Retry only: the generic retry row stays out.
  expect(container.querySelectorAll(".acpmux-cloud-start__retry")).toHaveLength(1);
  await act(async () => buttons[0]?.click());
  expect(host.calls).toEqual([{ method: "cloud.plan.subscribe", params: { plan: "max" } }]);
  // Still on Pro (largest lg): the start waits; on Max it goes, once.
  await act(async () => page.back());
  expect(retried).toBe(0);
  await act(async () => page.back());
  expect(retried).toBe(1);
  // On the largest plan already: too large for Cloud, no upgrade, This Mac leads.
  const largest = cloudStartEnded(begun, "k", {
    ok: false,
    code: "cloud_size_locked",
    details: { needed: "xl", allowed: "lg", upgrade_plan: null },
  });
  expect(largest?.message).toBe("This folder is too large for Cloud. It needs 16 vCPU and 32 GB memory.");
  const html = renderToStaticMarkup(
    <CloudStartView start={largest!} onRunHere={() => undefined} onRetry={() => undefined} />,
  );
  expect(html).not.toContain('data-action="upgrade"');
  expect(html).toContain('data-action="run-here" data-role="default">Run on This Mac</button>');
  // Malformed details: no size card, the host's words and its own Retry.
  expect(cloudSizeLocked({ needed: "huge" })).toBeUndefined();
  expect(cloudSizeLocked({ needed: "md", upgrade_plan: "ultra" })).toEqual({
    needed: "md",
    allowed: null,
    upgradePlan: null,
  });
});
