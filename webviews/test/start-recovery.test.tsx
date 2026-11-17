// The shared start-recovery view (cmuxterm-hq plans/next-ux/ux-start-anyway.md, first slice):
// which failed starts get it (startRecovery.ts), and the view's one sentence, actions, Dismiss and
// focus return, in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { startRecoveryReason } from "../src/agent-session/acpmux/startRecoveryReason";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "Event",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><textarea id=composer></textarea><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    KeyboardEvent: dom.window.KeyboardEvent,
    MouseEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const start = (error: string, code?: string) => ({
  harness: "claude",
  name: "Claude Code",
  error,
  ...(code ? { code } : {}),
});

test("only evidence makes a recovery state; everything else keeps the start-failed card", () => {
  expect(startRecoveryReason(start("x", "harness.not_installed"))).toBe("missing-harness");
  expect(startRecoveryReason(start("spawn claude-agent-acp ENOENT"))).toBe("missing-harness");
  expect(startRecoveryReason(start("connect ECONNREFUSED 104.18.32.47:443"))).toBe("offline");
  expect(startRecoveryReason(start("OAuth token has expired. Please run /login"))).toBe("signed-out");
  // A rejected API key is not a sign-in, quota is not a sign-in, and no words is no state.
  expect(startRecoveryReason(start("401 invalid x-api-key"))).toBeUndefined();
  expect(
    startRecoveryReason(start("429 rate_limit_error: Number of requests has exceeded your rate limit")),
  ).toBeUndefined();
  expect(startRecoveryReason(start(""))).toBeUndefined();
  expect(startRecoveryReason(undefined)).toBeUndefined();
});

async function render(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () => root!.render(node));
  return host.querySelector<HTMLElement>("[data-start-recovery]")!;
}

test("offline: one sentence, Try Again, the raw words under Details, Dismiss returns focus", async () => {
  const { FailedStartRecovery } = await import("../src/agent-session/acpmux/FailedStartRecovery");
  const composer = dom.window.document.getElementById("composer") as HTMLTextAreaElement;
  composer.focus();
  const clicks: string[] = [];
  const view = await render(
    <FailedStartRecovery
      start={{ harness: "codex", name: "Codex", error: "connect ECONNREFUSED 104.18.32.47:443" }}
      reason="offline"
      onRetry={() => clicks.push("retry")}
      onDismiss={() => clicks.push("dismiss")}
    />,
  );
  expect(view.dataset.startRecovery).toBe("offline");
  expect(view.querySelector("svg[aria-hidden=true]")).not.toBeNull();
  expect(view.querySelector('[data-recovery-action="signIn"]')).toBeNull();
  const sentence = view.querySelector(".acpmux-host-error-message")!.textContent!;
  expect(sentence).toContain("Codex");
  expect(sentence).not.toContain("ECONNREFUSED");
  await act(async () => view.querySelector<HTMLButtonElement>('[data-recovery-action="retry"]')!.click());
  view.querySelector<HTMLButtonElement>('[data-recovery-action="dismiss"]')!.focus();
  await act(async () => view.querySelector<HTMLButtonElement>('[data-recovery-action="dismiss"]')!.click());
  expect(clicks).toEqual(["retry", "dismiss"]);
  expect(dom.window.document.activeElement).toBe(composer);
});

test("signed out: Sign In leads, Try Again follows, Escape dismisses", async () => {
  const { FailedStartRecovery } = await import("../src/agent-session/acpmux/FailedStartRecovery");
  const clicks: string[] = [];
  const view = await render(
    <FailedStartRecovery
      start={start("OAuth token has expired. Please run /login")}
      reason="signed-out"
      onSignIn={() => clicks.push("signIn")}
      onRetry={() => clicks.push("retry")}
      onDismiss={() => clicks.push("dismiss")}
    />,
  );
  const buttons = [...view.querySelectorAll<HTMLButtonElement>(".acpmux-host-error-actions button")];
  expect(buttons.map((b) => b.dataset.recoveryAction)).toEqual(["signIn", "retry", "dismiss"]);
  await act(async () => buttons[0]!.click());
  await act(async () => {
    buttons[1]!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(clicks).toEqual(["signIn", "dismiss"]);
});

test("the missing-agent notice draws through the same view and keeps its own hooks", async () => {
  const { MissingHarnessNotice } = await import("../src/agent-session/acpmux/MissingHarnessNotice");
  const view = await render(
    <MissingHarnessNotice name="Claude Code" installable onInstall={() => {}} onSignIn={() => {}} />,
  );
  expect(view.dataset.startRecovery).toBe("missing-harness");
  expect(view.classList.contains("acpmux-missing-harness")).toBe(true);
  expect(view.dataset.missingHarness).toBe("missing");
});
