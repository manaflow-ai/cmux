// l10n-allow-file: test fixture plans and option names, not shipped UI.
// A plan approval could only be approved in its own chat. Leo, 2026-11-08: "esp valuable things that
// people would think \"wow this is awesome\"". Approve plan is now a split button: the filled half
// approves here with ⌘↩ as before, and its chevron offers Build here, Build in a new worktree and
// Build on two agents and compare (`_acpmux/plan/build`).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { PermissionCard } from "../src/agent-session/acpmux/PermissionCard";
import {
  compareHarnesses,
  harnessName,
  planBuildTarget,
  type PlanBuildElsewhere,
} from "../src/agent-session/acpmux/permissions/planBuild";
import { teardownDom } from "./support/domTeardown";

const plan: AcpmuxPermission = {
  permissionId: "p1",
  kind: "other",
  title: "Approve plan",
  plan: "## Retry uploads\n\n1. Add `withRetry`",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

const card = (permission: AcpmuxPermission, onBuildPlan?: (target: PlanBuildElsewhere) => Promise<unknown>) =>
  renderToStaticMarkup(
    <PermissionCard permission={permission} onAnswer={() => undefined} harness="claude" onBuildPlan={onBuildPlan} />,
  );

test("a plan with a build path joins Approve plan to its build menu; Approve plan keeps its label and ⌘↩", () => {
  const html = card(plan, async () => undefined);
  expect(html).toContain("acpmux-plan-build-split");
  expect(html).toContain('data-menu="plan-build"');
  expect(html).toContain('aria-label="Approve plan"');
  expect(html).toMatch(/aria-label="Approve plan"[^>]*aria-keyshortcuts="[^"]*Meta\+Enter/);
});

test("without a build path, and on any other ask, Approve plan stands alone", () => {
  expect(card(plan)).not.toContain("acpmux-plan-build-split");
  const write = { ...plan, plan: undefined, title: "Write notes", kind: "edit" } as AcpmuxPermission;
  expect(card(write, async () => undefined)).not.toContain("acpmux-plan-build-split");
});

test("a compare names the chat's harness and the other of Claude and Codex", () => {
  expect(compareHarnesses("claude")).toEqual(["claude", "codex"]);
  expect(compareHarnesses("claude-opus")).toEqual(["claude", "codex"]);
  expect(compareHarnesses("codex")).toEqual(["codex", "claude"]);
  expect(compareHarnesses(undefined)).toEqual(["claude", "codex"]);
  expect(harnessName("codex")).toBe("Codex");
  expect(harnessName("pi")).toBe("pi");
  expect(planBuildTarget("compare")).toBe("compare");
  expect(() => planBuildTarget("cloud")).toThrow();
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
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
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

test("the chevron's menu offers the three builds, and a pick builds once", async () => {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const built: PlanBuildElsewhere[] = [];
  const answered: string[] = [];
  await act(async () => {
    root.render(
      <PermissionCard
        permission={plan}
        harness="claude"
        onAnswer={(optionId) => answered.push(optionId)}
        onBuildPlan={async (target) => {
          built.push(target);
        }}
      />,
    );
  });
  const chevron = host.querySelector<HTMLButtonElement>('button[data-menu="plan-build"]')!;
  await act(async () => {
    chevron.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  const items = () => [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
  expect(items().map((item) => item.dataset.value)).toEqual(["here", "worktree", "compare"]);
  expect(items()[2]!.textContent).toContain("Claude and Codex");
  await act(async () => {
    items()[2]!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  expect(built).toEqual(["compare"]);
  expect(answered).toEqual([]);
  act(() => root.unmount());
});

test("a build refused before anything started says acpmux's reason on the card", async () => {
  const { createRoot } = await import("react-dom/client");
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => {
    root.render(
      <PermissionCard
        permission={plan}
        harness="claude"
        onAnswer={() => undefined}
        onBuildPlan={async () => {
          throw new Error("this chat already runs 8 sub-sessions");
        }}
      />,
    );
  });
  const chevron = host.querySelector<HTMLButtonElement>('button[data-menu="plan-build"]')!;
  await act(async () => {
    chevron.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  const worktree = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.dataset.value === "worktree",
  )!;
  await act(async () => {
    worktree.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  const alert = host.querySelector('[role="alert"]');
  expect(alert?.textContent).toBe("The plan was not built: this chat already runs 8 sub-sessions");
  act(() => root.unmount());
});
