// l10n-allow-file: test fixture plans, not shipped UI.
// The approved plan stays in sight while the agent builds it (ApprovedPlanBand.tsx). Leo's row: "plan
// pane that stays during the build, editable plan sent back".
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { ApprovedPlanBand } from "../src/agent-session/acpmux/ApprovedPlanBand";
import { approvedPlanOf, type ApprovedPlan } from "../src/agent-session/acpmux/approvedPlan";
import { teardownDom } from "./support/domTeardown";

const plan: ApprovedPlan = { markdown: "## Retry uploads\n\n1. Add `withRetry`", edited: false, permissionId: "p1" };

test("the summary's approvedPlan is read only with text and an approval id", () => {
  expect(approvedPlanOf(undefined)).toBeUndefined();
  expect(approvedPlanOf({ markdown: "  ", permissionId: "p1" })).toBeUndefined();
  expect(approvedPlanOf({ markdown: "Plan", edited: false })).toBeUndefined();
  expect(approvedPlanOf({ markdown: " Plan ", edited: true, permissionId: "p2", turn: 3, at: 9 })).toEqual({
    markdown: "Plan",
    edited: true,
    permissionId: "p2",
    turn: 3,
    at: 9,
  });
});

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    Node: w.Node,
    MouseEvent: w.MouseEvent,
    KeyboardEvent: w.KeyboardEvent,
    Event: w.Event,
    MutationObserver: w.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});

beforeEach(() => dom.window.localStorage.clear());

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const click = (element: Element) => element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));

test("folded it names the plan; a click opens the plan and another folds it", async () => {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(<ApprovedPlanBand chat="c1" plan={plan} />));
  const band = () => host.querySelector(".acpmux-approved-plan");
  expect(band()?.textContent).toContain("Approved plan");
  expect(band()?.textContent).toContain("Retry uploads");
  expect(host.querySelector(".acpmux-approved-plan-body")).toBeNull();
  expect(host.querySelector(".acpmux-approved-plan-tag")).toBeNull();
  const toggle = host.querySelector(".acpmux-approved-plan-toggle")!;
  await act(async () => click(toggle));
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".acpmux-approved-plan-body")?.textContent).toContain("withRetry");
  await act(async () => click(toggle));
  expect(host.querySelector(".acpmux-approved-plan-body")).toBeNull();
  act(() => root.unmount());
});

test("an edited plan wears Edited", async () => {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(<ApprovedPlanBand chat="c1" plan={{ ...plan, edited: true }} />));
  expect(host.querySelector(".acpmux-approved-plan-tag")?.textContent).toBe("Edited");
  act(() => root.unmount());
});

test("closed, it stays closed for that approval, in this chat only; a new approval shows again", async () => {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(<ApprovedPlanBand chat="c1" plan={plan} />));
  await act(async () => click(host.querySelector('[aria-label="Close plan"]')!));
  expect(host.querySelector(".acpmux-approved-plan")).toBeNull();
  act(() => root.unmount());

  const again = createRoot(host);
  await act(async () => again.render(<ApprovedPlanBand chat="c1" plan={plan} />));
  expect(host.querySelector(".acpmux-approved-plan")).toBeNull();
  await act(async () => again.render(<ApprovedPlanBand chat="c2" plan={plan} />));
  expect(host.querySelector(".acpmux-approved-plan")).not.toBeNull();
  await act(async () => again.render(<ApprovedPlanBand chat="c1" plan={{ ...plan, permissionId: "p2" }} />));
  expect(host.querySelector(".acpmux-approved-plan")).not.toBeNull();
  act(() => again.unmount());
});
