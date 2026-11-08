// l10n-allow-file: test fixture plans and option names, not shipped UI.
// A plan approval had two answers, Approve plan and Keep planning, so approving always left Claude
// Code asking before each edit: the "Yes, and auto-accept edits" its own prompt offers was missing.
// acpmux now offers it on ExitPlanMode (claude_stdio `PLAN_ACCEPT_EDITS`), and the card draws it as
// Approve and auto-accept edits beside Approve plan, on key 2 and ⌥⌘2. Keep planning still opens its
// field, whose note is optional.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { permissionAnswers, PLAN_ACCEPT_EDITS } = await import("../src/agent-session/acpmux/permissions/prompt");
const { permissionCardHeight } = await import("../src/agent-session/acpmux/permissions/cardHeight");

const PLAN = "## Retry uploads\n\n1. Add `withRetry`\n2. Wrap `uploadChunk`";
const OPTIONS: AcpmuxPermission["options"] = [
  { id: "allow_once", name: "Answer", kind: "allow_once", allow: true },
  { id: PLAN_ACCEPT_EDITS, name: "Approve and auto-accept edits", kind: "allow_once", allow: true },
  { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
];
const planAsk: AcpmuxPermission = {
  permissionId: "p1",
  title: "Approve plan",
  kind: "other",
  plan: PLAN,
  pending: true,
  options: OPTIONS,
};

async function mount(permission: AcpmuxPermission) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const sent: string[] = [];
  const denied: [string, string][] = [];
  await act(async () =>
    root.render(
      <PermissionCard
        permission={permission}
        harness="claude"
        onAnswer={(optionId) => {
          sent.push(optionId);
          return Promise.resolve();
        }}
        onDenyWithFeedback={(optionId, text) => {
          denied.push([optionId, text]);
          return Promise.resolve(true);
        }}
      />,
    ),
  );
  const labels = () => [...host.querySelectorAll("button")].map((b) => b.getAttribute("aria-label"));
  const button = (label: string) =>
    [...host.querySelectorAll("button")].find((b) => b.getAttribute("aria-label") === label);
  const key = (k: string) =>
    act(async () => void dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: k })));
  const shortcut = (action: string) =>
    act(async () => void dom.window.dispatchEvent(new dom.window.Event(`cmux-acpmux-${action}`)));
  const unmount = () => act(async () => root.unmount()).then(() => host.remove());
  return { host, labels, button, key, shortcut, sent, denied, unmount };
}

const approveAcceptEdits = translate("permission.plan.approveAcceptEdits");

test("a plan approval's answers: Keep planning, Approve and auto-accept edits, Approve plan", async () => {
  const card = await mount(planAsk);
  try {
    expect(card.labels()).toEqual([
      translate("permission.plan.keepPlanning"),
      approveAcceptEdits,
      translate("permission.plan.approve"),
    ]);
    expect(card.host.querySelector(".acpmux-permission-plan-card")).not.toBeNull();
    await act(async () => card.button(approveAcceptEdits)!.click());
    expect(card.sent).toEqual([PLAN_ACCEPT_EDITS]);
  } finally {
    await card.unmount();
  }
});

test("key 2 approves and auto-accepts edits; key 1 approves the plan alone", async () => {
  const two = await mount(planAsk);
  try {
    await two.key("2");
    expect(two.sent).toEqual([PLAN_ACCEPT_EDITS]);
  } finally {
    await two.unmount();
  }
  const chord = await mount({ ...planAsk, permissionId: "p2" });
  try {
    await chord.shortcut("permissionAllowChat");
    expect(chord.sent).toEqual([PLAN_ACCEPT_EDITS]);
  } finally {
    await chord.unmount();
  }
  const one = await mount({ ...planAsk, permissionId: "p3" });
  try {
    await one.key("1");
    expect(one.sent).toEqual(["allow_once"]);
  } finally {
    await one.unmount();
  }
});

test("Keep planning sends its optional note with the deny, or denies with none", async () => {
  const card = await mount(planAsk);
  try {
    await act(async () => card.button(translate("permission.plan.keepPlanning"))!.click());
    const field = card.host.querySelector("textarea")!;
    expect(field.getAttribute("placeholder")).toBe(translate("permission.plan.feedbackPlaceholder"));
    await act(async () => (card.host.querySelector("form") as HTMLFormElement).requestSubmit());
    expect(card.denied).toEqual([["reject_once", ""]]);
    expect(card.sent).toEqual([]);
  } finally {
    await card.unmount();
  }
});

test("a plan approval without the mode keeps its two answers", async () => {
  const card = await mount({ ...planAsk, options: OPTIONS.filter((option) => option.id !== PLAN_ACCEPT_EDITS) });
  try {
    expect(card.labels()).toEqual([translate("permission.plan.keepPlanning"), translate("permission.plan.approve")]);
  } finally {
    await card.unmount();
  }
});

test("only a plan approval takes the option out as Approve and auto-accept edits", () => {
  expect(permissionAnswers(OPTIONS, true).acceptEdits?.id).toBe(PLAN_ACCEPT_EDITS);
  expect(permissionAnswers(OPTIONS, true).others).toEqual([]);
  // On any other ask an option of that id is just another option, by its own name.
  expect(permissionAnswers(OPTIONS).acceptEdits).toBeUndefined();
  expect(permissionAnswers(OPTIONS).others.map((option) => option.id)).toEqual([PLAN_ACCEPT_EDITS]);
});

test("the card's height estimate counts the extra answer", () => {
  const two = { ...planAsk, options: OPTIONS.filter((option) => option.id !== PLAN_ACCEPT_EDITS) };
  // At a narrow width the third answer wraps to a second row.
  expect(permissionCardHeight(planAsk, 300)).toBeGreaterThan(permissionCardHeight(two, 300));
});
