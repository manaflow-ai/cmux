// Regression coverage for the opt-in missing-agent recovery presentation.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SwitchNotice } from "./SwitchNotice";
import { StartFailure } from "./newtab/StartFailure";
import { setStartRecoveryPreview } from "./startRecoveryPreview";
import { SIGN_IN_REQUIRED } from "./startRefusal";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "PointerEvent",
  "KeyboardEvent",
  "FocusEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    PointerEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(async () => {
  act(() => setStartRecoveryPreview(false));
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function notice(ran: string[], harness = "claude", local = true) {
  return (
    <SwitchNotice
      switching={{
        harness,
        name: harness === "claude" ? "Claude Code" : "Codex",
        phase: "failed",
        error: `spawn ${harness} ENOENT`,
      }}
      installs={local}
      onRetry={() => ran.push("retry")}
      onAction={(action) => ran.push(`${harness}:${action}`)}
    />
  );
}

async function enable() {
  await act(async () => {
    setStartRecoveryPreview(true);
  });
}

async function click(doc: Document, selector: string) {
  const button = doc.querySelector<HTMLButtonElement>(selector);
  expect(button).toBeTruthy();
  await act(async () => button!.click());
}

test("Labs defaults off: existing install notice remains without a dialog or side effect", async () => {
  const ran: string[] = [];
  const doc = render(notice(ran));
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
  expect(doc.querySelector(".acpmux-host-error-message")?.textContent).toContain("isn't installed");
  expect(ran).toEqual([]);
});

test("Labs on: one explicit Install invokes the existing chat action, keeping the notice", async () => {
  const ran: string[] = [];
  const doc = render(notice(ran));
  await enable();
  expect(doc.querySelector('[role="dialog"]')?.textContent).toContain("Claude Code isn't installed");
  expect(ran).toEqual([]);
  await click(doc, '[role="dialog"] button[data-variant="solid"]');
  expect(ran).toEqual(["claude:install"]);
  expect(doc.querySelector(".acpmux-host-error-message")).toBeTruthy();
});

test("dismissal does not install; a new selection uses its own action", async () => {
  const ran: string[] = [];
  const doc = render(notice(ran));
  await enable();
  await click(doc, '[role="dialog"] button[data-variant="subtle"]');
  expect(ran).toEqual([]);
  await act(async () => root!.render(notice(ran, "codex")));
  expect(doc.querySelector('[role="dialog"]')?.textContent).toContain("Codex isn't installed");
  await click(doc, '[role="dialog"] button[data-variant="solid"]');
  expect(ran).toEqual(["codex:install"]);
});

test("remote missing agents never offer local installation in the experiment", async () => {
  const doc = render(notice([], "claude", false));
  await enable();
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
});

test("turning Labs off removes an open recovery dialog", async () => {
  const doc = render(notice([]));
  await enable();
  expect(doc.querySelector('[role="dialog"]')).toBeTruthy();
  await act(async () => setStartRecoveryPreview(false));
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
});

test("New Tab delegates setup once; an owner retaining failure keeps retry/dismiss", async () => {
  const ran: string[] = [];
  const doc = render(
    <StartFailure
      failure={{
        harness: "claude",
        error: "spawn claude ENOENT",
        local: true,
        retry: () => ran.push("retry"),
      }}
      name="Claude Code"
      onInstall={() => ran.push("setup-failed")}
      onDismiss={() => ran.push("dismiss")}
    />,
  );
  await enable();
  await click(doc, '[role="dialog"] button[data-variant="solid"]');
  expect(ran).toEqual(["setup-failed"]);
  const notice = doc.querySelector(".acpmux-start-failure")!;
  expect(notice.textContent).toContain("Retry");
  expect(notice.textContent).toContain("Dismiss");
  expect(notice.textContent).toContain("isn't installed");
});

test("unknown authentication, quota and outdated CLI failures do not open install recovery", async () => {
  const doc = render(
    <SwitchNotice
      switching={{
        harness: "claude",
        name: "Claude Code",
        phase: "failed",
        error: "usage limit exceeded",
      }}
      onRetry={() => {}}
      onAction={() => {}}
    />,
  );
  await enable();
  for (const error of ["usage limit exceeded", "authentication status unknown", "CLI version is outdated"]) {
    await act(async () =>
      root!.render(
        <SwitchNotice
          switching={{ harness: "claude", name: "Claude Code", phase: "failed", error }}
          onRetry={() => {}}
          onAction={() => {}}
        />,
      ),
    );
    expect(doc.querySelector('[role="dialog"]')).toBeNull();
  }
});

function signedOut(ran: string[], props: { installs?: boolean; runsLogin?: boolean } = {}) {
  return (
    <SwitchNotice
      switching={{
        harness: "codex",
        name: "Codex",
        phase: "failed",
        code: SIGN_IN_REQUIRED,
        error: "Codex isn't signed in on this machine.",
      }}
      installs={props.installs ?? true}
      runsLogin={props.runsLogin ?? true}
      onRetry={() => ran.push("retry")}
      onAction={(action) => ran.push(`codex:${action}`)}
    />
  );
}

test("signed out on this Mac: Labs off draws no dialog; the card's Sign in stays", async () => {
  const ran: string[] = [];
  const doc = render(signedOut(ran));
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
  expect(doc.querySelector(".acpmux-host-error-actions")?.textContent).toContain("Codex");
  expect(ran).toEqual([]);
});

test("signed out on this Mac, Labs on: Sign in runs the card's own sign-in once, never Install", async () => {
  const ran: string[] = [];
  const doc = render(signedOut(ran));
  await enable();
  const dialog = doc.querySelector('[role="dialog"]');
  expect(dialog).toBeTruthy();
  expect(dialog?.querySelector('button[data-variant="solid"]')?.textContent).toContain("Codex");
  expect(ran).toEqual([]);
  await click(doc, '[role="dialog"] button[data-variant="solid"]');
  expect(ran).toEqual(["codex:signIn"]);
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
  expect(doc.querySelector(".acpmux-host-error-message")).toBeTruthy();
});

test("signed out: dismissal signs nothing in; Retry stays on the card", async () => {
  const ran: string[] = [];
  const doc = render(signedOut(ran));
  await enable();
  await click(doc, '[role="dialog"] button[data-variant="subtle"]');
  expect(ran).toEqual([]);
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
  expect(doc.querySelector(".acpmux-host-error-actions")?.textContent).toContain("Retry");
});

test("signed out with no login command, or on another machine, opens no sign-in dialog", async () => {
  const doc = render(signedOut([], { runsLogin: false }));
  await enable();
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
  await act(async () => root!.render(signedOut([], { installs: false })));
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
});
