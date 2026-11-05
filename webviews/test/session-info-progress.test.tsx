// l10n-allow-file: test fixture plan steps, not shipped UI.
// Session Info's Progress is live (Leo, 2026-11-04: "A live Progress section in Session Info (medium).
// Today the plan only shows in the transcript."). The pane mounts Session Info open on a chat whose
// agent wrote a plan, then sends the plan updates an agent's TodoWrite makes: the same plan row, its
// steps' states changed in place (no row added, so the sections' cached rows do not move). Each update
// shows in Progress at once; the turn ending stops the spinner; a chat with no plan has no Progress;
// and a streamed token that leaves the plan as it was paints nothing in it.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxPlanEntry, AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { setPaneLanguage } from "../src/agent-session/acpmux/i18n";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { currentPlan } from "../src/agent-session/acpmux/session-info/ProgressSection";
import { projectLiveProgress, type LiveProgress } from "../src/agent-session/acpmux/liveProgress";
import { resetSessionInfoState, setSessionInfoOpen } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { assistant, chat, user } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  class FakeResizeObserver {
    observe() {}
    disconnect() {}
  }
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: FakeResizeObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  setPaneLanguage("en");
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  published = undefined;
  planArrays.clear();
  resetSessionInfoState();
  setHeaderState({ inspector: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

type Status = AcpmuxPlanEntry["status"];
const STEPS = ["Read the code", "Write the fix", "Run the tests"];
const planRow = (statuses: readonly Status[], version: number): AcpmuxRow => ({
  id: "plan-7",
  version,
  at: 1_000,
  kind: "plan",
  plan: STEPS.map((content, index) => ({ content, status: statuses[index]! })),
});
/// The checklist the client publishes beside its rows (direct.ts, liveProgress.ts): its plan array is
/// the same object until a plan update (a new row version), so a streamed token keeps the projection.
let published: LiveProgress | undefined;
const planArrays = new Map<string, AcpmuxPlanEntry[]>();

/// The chat as acpmux sends it: new objects every time, the plan row in place among the rows, and the
/// client's `progress` beside them.
const withPlan = (statuses: readonly Status[] | undefined, version = 1, fields: Partial<AcpmuxSnapshot> = {}) => {
  const base = chat([user("Fix the retry", 3)]);
  const row = statuses ? planRow(statuses, version) : undefined;
  const key = `${version}:${statuses?.join()}`;
  const entries = row ? (planArrays.get(key) ?? planArrays.set(key, row.plan!).get(key)!) : undefined;
  const isWorking = fields.isWorking ?? true;
  published = projectLiveProgress(published, entries, isWorking);
  return {
    ...base,
    rows: [...base.rows, ...(row ? [{ ...row, plan: entries }] : []), assistant("Working on it", 1)],
    isWorking,
    ...(published ? { progress: published } : {}),
    ...fields,
  } satisfies AcpmuxSnapshot;
};

async function mount(first: AcpmuxSnapshot) {
  const container = installDom();
  let push: (snapshot: AcpmuxSnapshot) => void = () => {};
  function Pane() {
    const [snapshot, setSnapshot] = useState(first);
    const [shell, setShell] = useState<HTMLElement | null>(null);
    push = setSnapshot;
    const sessionInfo = useSessionInfo({ snapshot, shell, machineName: "Studio" });
    return (
      <section
        className="acpmux-shell"
        ref={(element) => {
          if (element && element !== shell) {
            Object.defineProperty(element, "clientWidth", { configurable: true, get: () => 1200 });
            Object.defineProperty(element, "clientHeight", { configurable: true, get: () => 900 });
            setShell(element);
          }
        }}
      >
        <div className="acpmux-main" />
        {sessionInfo.panel}
      </section>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  await act(async () => setSessionInfoOpen(true));
  return { container, push: (snapshot: AcpmuxSnapshot) => act(async () => push(snapshot)) };
}

const progress = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-section="progress"]');
const states = (container: HTMLElement) =>
  [...(progress(container)?.querySelectorAll<HTMLElement>(".acpmux-session-info-progress__step") ?? [])].map(
    (step) => step.dataset.status,
  );
const head = (container: HTMLElement) =>
  progress(container)?.querySelector(".acpmux-session-info-section__value")?.textContent;
const spinners = (container: HTMLElement) => progress(container)?.querySelectorAll(".cv-spinner").length ?? 0;

test("Progress follows the plan as the agent updates it in place", async () => {
  const { container, push } = await mount(withPlan(["in_progress", "pending", "pending"]));
  expect(states(container)).toEqual(["in_progress", "pending", "pending"]);
  expect(head(container)).toBe("0 of 3");
  expect(spinners(container)).toBe(1);
  // The step texts, in order, on the panel.
  expect(
    [...progress(container)!.querySelectorAll(".acpmux-session-info-progress__text")].map((node) => node.textContent),
  ).toEqual(STEPS);

  await push(withPlan(["completed", "in_progress", "pending"], 2));
  expect(states(container)).toEqual(["completed", "in_progress", "pending"]);
  expect(head(container)).toBe("1 of 3");

  await push(withPlan(["completed", "completed", "in_progress"], 3));
  expect(states(container)).toEqual(["completed", "completed", "in_progress"]);
  expect(head(container)).toBe("2 of 3");

  // The turn ends with the last step still marked in progress: it stops spinning.
  await push(withPlan(["completed", "completed", "in_progress"], 3, { isWorking: false }));
  expect(spinners(container)).toBe(0);

  await push(withPlan(["completed", "completed", "completed"], 4, { isWorking: false }));
  expect(head(container)).toBe("3 of 3");
});

test("a chat with no plan has no Progress", async () => {
  const { container } = await mount(withPlan(undefined));
  expect(container.querySelector("aside.acpmux-session-info")).not.toBeNull();
  expect(progress(container)).toBeNull();
});

test("a streamed token that leaves the plan as it was paints nothing in Progress", async () => {
  const { container, push } = await mount(withPlan(["completed", "in_progress", "pending"]));
  const section = progress(container)!;
  const observer = new dom!.window.MutationObserver(() => undefined);
  observer.observe(section, { subtree: true, childList: true, attributes: true, characterData: true });
  for (let step = 0; step < 10; step++) await push(withPlan(["completed", "in_progress", "pending"]));
  expect(observer.takeRecords()).toEqual([]);
  observer.disconnect();
  expect(progress(container)).toBe(section);
});

test("currentPlan reads the latest plan, ended once a later prompt or the turn's end came", () => {
  const plan = planRow(["completed", "in_progress", "pending"], 1);
  expect(currentPlan([user("go", 2)], true)).toBeUndefined();
  expect(currentPlan([user("go", 2), plan], true)).toEqual({ entries: plan.plan!, ended: false });
  expect(currentPlan([user("go", 2), plan], false)?.ended).toBe(true);
  expect(currentPlan([plan, user("next", 1)], true)?.ended).toBe(true);
  // A plan with no steps is no plan.
  expect(currentPlan([{ ...plan, plan: [] }], true)).toBeUndefined();
});
