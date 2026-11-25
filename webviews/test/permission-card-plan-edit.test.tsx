// l10n-allow-file: test fixture plans and option names, not shipped UI.
// A plan approval could be approved or sent back, never changed: a person who wanted one step
// different had to Keep planning and wait for a new plan. Leo's gap doc item 6 (feature map
// `plan-pane`): "an edit step before Approve". Edit plan turns the plan into text; Approve plan then
// sends the edit (`_acpmux/plan/build` here with `plan`), and the agent builds the edited plan.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { permissionFromMessage } from "../src/agent-session/acpmux/direct";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { PermissionCard } from "../src/agent-session/acpmux/PermissionCard";
import { teardownDom } from "./support/domTeardown";

const PLAN = "## Retry uploads\n\n1. Add `withRetry`";

const plan: AcpmuxPermission = {
  permissionId: "p1",
  kind: "other",
  title: "Approve plan",
  plan: PLAN,
  planEditable: true,
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

test("only Claude Code's ExitPlanMode plan is editable", () => {
  const ask = (toolCall: Record<string, unknown>) =>
    permissionFromMessage(
      {
        sessionId: "s1",
        permissionId: "p1",
        request: {
          toolCall,
          options: [{ optionId: "a", name: "Allow", kind: "allow_once" }],
        },
      },
      "s1",
    )!;
  expect(
    ask({
      toolCallId: "t",
      kind: "other",
      rawInput: { plan: PLAN },
      _meta: { claude: { tool: "ExitPlanMode" } },
    }).planEditable,
  ).toBe(true);
  expect(ask({ toolCallId: "t", kind: "switch_mode", rawInput: { plan: PLAN } }).planEditable).toBeUndefined();
});

test("Edit plan shows only with somewhere to send the edit", () => {
  const without = renderToStaticMarkup(
    <PermissionCard permission={plan} onAnswer={() => undefined} harness="claude" />,
  );
  expect(without).not.toContain("Edit plan");
  const withEdit = renderToStaticMarkup(
    <PermissionCard
      permission={plan}
      onAnswer={() => undefined}
      harness="claude"
      onApproveEditedPlan={async () => undefined}
    />,
  );
  expect(withEdit).toContain("Edit plan");
});

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
  "PointerEvent",
  "KeyboardEvent",
  "FocusEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "DocumentFragment",
  "SVGElement",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: w.HTMLElement,
    Element: w.Element,
    Node: w.Node,
    ShadowRoot: w.ShadowRoot,
    MouseEvent: w.MouseEvent,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    KeyboardEvent: w.KeyboardEvent,
    FocusEvent: w.FocusEvent,
    Event: w.Event,
    CustomEvent: w.CustomEvent,
    MutationObserver: w.MutationObserver,
    DocumentFragment: w.DocumentFragment,
    SVGElement: w.SVGElement,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const click = (el: Element) => el.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
const button = (host: HTMLElement, text: string) =>
  [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.includes(text))!;
/// Types into a React-controlled textarea: the native setter, then an input event.
const type = (field: HTMLTextAreaElement, value: string) => {
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  setter.call(field, value);
  field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
};

async function mount(answered: string[], approved: string[]) {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => {
    root.render(
      <PermissionCard
        permission={plan}
        harness="claude"
        onAnswer={(optionId) => answered.push(optionId)}
        onApproveEditedPlan={async (text) => {
          approved.push(text);
        }}
      />,
    );
  });
  return { host, root };
}

test("an edited plan goes with Approve plan, once", async () => {
  const answered: string[] = [];
  const approved: string[] = [];
  const { host, root } = await mount(answered, approved);
  await act(async () => click(button(host, "Edit plan")));
  const field = host.querySelector<HTMLTextAreaElement>("textarea")!;
  expect(field.value).toBe(PLAN);
  await act(async () => type(field, `${PLAN}\n2. Log each retry`));
  expect(host.textContent).toContain("Approve plan sends this version");
  await act(async () => click(button(host, "Approve plan")));
  expect(approved).toEqual([`${PLAN}\n2. Log each retry`]);
  expect(answered).toEqual([]);
  act(() => root.unmount());
});

test("an unchanged or discarded edit approves the plan as the agent wrote it", async () => {
  const answered: string[] = [];
  const approved: string[] = [];
  const { host, root } = await mount(answered, approved);
  await act(async () => click(button(host, "Edit plan")));
  const field = host.querySelector<HTMLTextAreaElement>("textarea")!;
  await act(async () => type(field, "1. Something else"));
  await act(async () => click(button(host, "Discard edit")));
  expect(host.querySelector("textarea")).toBeNull();
  await act(async () => click(button(host, "Approve plan")));
  expect(approved).toEqual([]);
  expect(answered).toEqual(["allow_once"]);
  act(() => root.unmount());
});
