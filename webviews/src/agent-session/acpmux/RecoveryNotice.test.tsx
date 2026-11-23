// The recovery line (RecoveryNotice.tsx): acpmux's resume-at-reset row and restart outcome, drawn.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { RecoveryNotice, type ResumeAtResetAction } from "./RecoveryNotice";
import type { RecoveryStatus } from "./recoveryStatus";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
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
});

async function render(
  container: HTMLElement,
  state: RecoveryStatus | undefined,
  onResumeAtReset?: ResumeAtResetAction,
) {
  root ??= createRoot(container);
  await act(async () => {
    root!.render(
      <NoticeSlot>
        <RecoveryNotice state={state} onResumeAtReset={onResumeAtReset} locale="en-US" />
      </NoticeSlot>,
    );
  });
}

const RESET = Date.UTC(2026, 10, 22, 15, 30);

test("an offered resume at the reset arms on a click, and once armed its Cancel cancels it", async () => {
  const container = installDom();
  const calls: boolean[] = [];
  const action: ResumeAtResetAction = async (cancel) => {
    calls.push(cancel);
  };
  await render(container, { resumeAtReset: { state: "offered", turnId: "cut", resetsAt: RESET } }, action);
  expect(container.querySelector('[data-resume-at-reset="offered"]')).not.toBeNull();
  await act(async () => (container.querySelector('[data-recovery-action="arm"]') as HTMLButtonElement).click());
  expect(calls).toEqual([false]);
  await render(container, { resumeAtReset: { state: "armed", turnId: "cut", resetsAt: RESET } }, action);
  expect(container.textContent).toContain("Resumes once at");
  await act(async () => (container.querySelector('[data-recovery-action="cancel"]') as HTMLButtonElement).click());
  expect(calls).toEqual([false, true]);
});

test("an unknown reset shows no time and no arm: the person retries by hand", async () => {
  const container = installDom();
  await render(container, { resumeAtReset: { state: "unknown_reset", turnId: "cut" } }, async () => {});
  expect(container.querySelector('[data-resume-at-reset="unknown_reset"]')).not.toBeNull();
  expect(container.querySelector("[data-recovery-action]")).toBeNull();
  expect(container.textContent).not.toMatch(/\d:\d\d/);
});

test("a refused arm says so and sends nothing more", async () => {
  const container = installDom();
  let calls = 0;
  await render(container, { resumeAtReset: { state: "offered", turnId: "cut", resetsAt: RESET } }, async () => {
    calls += 1;
    throw new Error("retry.at_reset.permission");
  });
  await act(async () => (container.querySelector('[data-recovery-action="arm"]') as HTMLButtonElement).click());
  expect(calls).toBe(1);
  expect(container.querySelector("[data-recovery-failed]")).not.toBeNull();
});

test("no action is drawn where the pane may not arm it", async () => {
  const container = installDom();
  await render(container, { resumeAtReset: { state: "offered", turnId: "cut", resetsAt: RESET } });
  expect(container.querySelector("[data-recovery-action]")).toBeNull();
});

test("a resumed turn says queued until its continuation starts, then continuing", async () => {
  const container = installDom();
  const resumed = { state: "resumed", nextAction: "none", continuationPromptId: "p1~resume-1" } as const;
  await render(container, { restartOutcome: { ...resumed, delivery: "queued" } });
  expect(container.querySelector('[data-restart-delivery="queued"]')).not.toBeNull();
  expect(container.textContent).toContain("queued");
  await render(container, { restartOutcome: { ...resumed, delivery: "delivered" } });
  expect(container.querySelector('[data-restart-delivery="delivered"]')).not.toBeNull();
  expect(container.textContent).toContain("continuing now");
});

test("a turn waiting for the person names the one next action, with why and unknown tools in Details", async () => {
  const container = installDom();
  await render(container, {
    restartOutcome: {
      state: "waiting_for_user",
      nextAction: "review_then_send",
      why: "trigger",
      unfinishedTools: ["Bash", "Edit"],
      toolsOmitted: true,
    },
  });
  expect(container.querySelector('[data-restart-outcome="waiting_for_user"]')).not.toBeNull();
  expect(container.textContent).toContain("check what it did");
  const tools = container.querySelector("[data-recovery-tools]")!;
  expect(tools.textContent).toContain("outcome unknown");
  expect(tools.textContent).toContain("Bash, Edit, …");
  expect(container.textContent).not.toMatch(/still running/i);
});

test("unable to resume points at Retry", async () => {
  const container = installDom();
  await render(container, {
    restartOutcome: { state: "unable_to_resume", nextAction: "retry", why: "attempts_exhausted" },
  });
  expect(container.textContent).toContain("use Retry");
});
