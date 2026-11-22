// l10n-allow-file: test fixture pull requests and checks, not shipped UI.
// Changes' Fix failing checks button (experiment `changes-fix-checks-button`, off by default): it
// counts only the branch's own reds, shows only where Labs' Fix Failing Checks would, names the base
// reds it leaves out, and its Preview arm sends acpmux's message to the chat it was read for.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChangesSection } from "../src/agent-session/acpmux/session-info/ChangesSection";
import type { SessionInfoPullRequestStatus } from "../src/agent-session/acpmux/session-info/changesSectionModel";
import { fixChecksButton } from "../src/agent-session/acpmux/session-info/fixChecks.experiment";
import { fixChecksPreview, ownFailing } from "../src/agent-session/acpmux/session-info/fixChecks";
import type { FixChecksActions } from "../src/agent-session/acpmux/session-info/FixChecksButton";
import type { PrFeedbackKind } from "../src/agent-session/acpmux/session-info/prFeedback";
import type { SummaryPullRequest } from "../src/agent-session/acpmux/summary/sessionSummary";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  delete globalThis.cmuxExperiments;
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
});

const pr = (repo: string, number: number, state: SummaryPullRequest["state"] = "open"): SummaryPullRequest => ({
  url: `https://github.com/${repo}/pull/${number}`,
  repo,
  number,
  state,
  opened: true,

const ANSWER = {
  kind: "checks",
  empty: false,
  draft: "Fix the failing checks on example/project#42. These 2 fail on this branch only: lint, unit-tests.",
  checks: {
    own: [
      { name: "lint", workflow: "CI", step: "Run vp lint", url: "https://example.test/job/2" },
      { name: "unit-tests", workflow: "CI" },
      { workflow: "nameless" },
    ],
    onBase: ["e2e", ""],
    pending: 0,
  },
};

async function render(
  container: HTMLElement,
  look: string | undefined,
  pullRequests: readonly SummaryPullRequest[],
  statuses: Record<string, SessionInfoPullRequestStatus>,
  onDraftFeedback?: (url: string, kind: PrFeedbackKind) => void,
  fixChecks?: FixChecksActions,
) {
  globalThis.cmuxExperiments = look ? { [fixChecksButton.id]: look } : {};
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <ChangesSection
        pullRequests={pullRequests}
        statuses={statuses}
        onDraftFeedback={onDraftFeedback}
        fixChecks={fixChecks}
      />,
    );
  });
}

const buttons = (container: HTMLElement) => [...container.querySelectorAll<HTMLButtonElement>(".acpmux-session-info-fix")];
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("the count is the branch's own reds: failing less those failing on base too", () => {
  expect(ownFailing(3, 1)).toBe(2);
  expect(ownFailing(2, 2)).toBe(0);
  expect(ownFailing(1, 5)).toBe(0);
  expect(ownFailing(4, -1)).toBe(4);
  // Failing with no count stays unknown: the button then names no number.
  expect(ownFailing(-1, 0)).toBe(-1);
});

test("acpmux's answer becomes what the button says it sends and leaves out", () => {
  expect(fixChecksPreview(ANSWER)).toEqual({
    draft: ANSWER.draft,
    empty: false,
    own: [
      { name: "lint", url: "https://example.test/job/2", step: "Run vp lint" },
      { name: "unit-tests" },
    ],
    onBase: ["e2e"],
  });
  expect(fixChecksPreview({ draft: "No failing checks of this branch's own.", empty: true })).toEqual({
    draft: "No failing checks of this branch's own.",
    empty: true,
    own: [],
    onBase: [],
  });
  for (const bad of [undefined, null, "text", {}, { draft: "  " }, { draft: 3 }]) expect(fixChecksPreview(bad)).toBeUndefined();
});

test("off by default: no button, whatever the row's reds", async () => {
  expect(fixChecksButton.defaultArm).toBe("off");
  const container = installDom();
  const own = pr("example/project", 42);
  await render(container, undefined, [own], { [own.url]: { state: "open", checks: "failing", failing: 3, failingOnBase: 1 } }, () => undefined);
  expect(buttons(container)).toHaveLength(0);
});

test("it shows only where the ⋯ menu offers Fix Failing Checks, and counts the own reds", async () => {
  const container = installDom();
  const own = pr("example/project", 42);
  const base = pr("example/project", 43);
  const merged = pr("example/project", 44, "merged");
  const unknown = pr("example/project", 45);
  const statuses: Record<string, SessionInfoPullRequestStatus> = {
    [own.url]: { state: "open", checks: "failing", failing: 3, failingOnBase: 1 },
    [base.url]: { state: "open", checks: "failing", failing: 2, failingOnBase: 2 },
    [merged.url]: { state: "merged", checks: "failing", failing: 1 },
    [unknown.url]: { state: "open", checks: "failing" },
  };
  // Without Labs (no draft callback), no button even with the arm on.
  await render(container, "quiet", [own, base, merged, unknown], statuses);
  expect(buttons(container)).toHaveLength(0);
  const drafted: string[] = [];
  await render(container, "quiet", [own, base, merged, unknown], statuses, (url, kind) => drafted.push(`${kind} ${url}`));
  expect(buttons(container).map((button) => button.textContent)).toEqual(["Fix 2 failing checks", "Fix Failing Checks"]);
  await act(async () => buttons(container)[0]!.click());
  expect(drafted).toEqual([`checks ${own.url}`]);
});

test("one own red reads in the singular", async () => {
  const container = installDom();
  const own = pr("example/project", 42);
  await render(container, "quiet", [own], { [own.url]: { state: "open", checks: "failing", failing: 2, failingOnBase: 1 } }, () => undefined);
  expect(buttons(container)[0]!.textContent).toBe("Fix 1 failing check");
});

test("Preview reads acpmux's message, names the base red not sent, and Send sends it to the chat read for", async () => {
  const container = installDom();
  const own = pr("example/project", 42);
  const sent: string[] = [];
  let shown = true;
  const reads: string[] = [];
  const actions: FixChecksActions = {
    read: (url) => {
      reads.push(url);
      return { answer: Promise.resolve(ANSWER), stillShown: () => shown };
    },
    send: (markdown) => sent.push(markdown),
  };
  const drafted: string[] = [];
  const statuses = { [own.url]: { state: "open", checks: "failing", failing: 3, failingOnBase: 1 } };
  await render(container, "preview", [own], statuses, (url) => drafted.push(url), actions);
  await act(async () => buttons(container)[0]!.click());
  await settle();
  const body = dom!.window.document.body;
  expect(body.querySelector(".acpmux-session-info-fix__draft")?.textContent).toBe(ANSWER.draft);
  expect(body.querySelector(".acpmux-session-info-fix__base")?.textContent).toBe("Failing on base too, not sente2e");
  const send = () => body.querySelector<HTMLButtonElement>(".acpmux-session-info-fix__send")!;
  await act(async () => send().click());
  expect(sent).toEqual([ANSWER.draft]);
  expect(drafted).toEqual([]);
  // A chat left after the read gets nothing sent.
  shown = false;
  await act(async () => buttons(container)[0]!.click());
  await settle();
  await act(async () => send().click());
  expect(sent).toEqual([ANSWER.draft]);
  // One read per counts, not per open.
  expect(reads).toEqual([own.url]);
});
