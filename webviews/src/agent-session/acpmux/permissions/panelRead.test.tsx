// The permission card's failed read: the chat's requests are read again on their own (autoRetry.ts),
// with nothing at first and one quiet line past the deadline, never a Refresh button (Leo,
// 2026-11-22: "vacuous decisions like that should be just done"). A failed answer keeps Refresh,
// and an answer in doubt keeps Check and retry (retry-prompt-ok: it sends the decision again).
import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import type { PermissionClientState } from "./protocol";
import { importWithDom } from "../../../../test/support/importWithDom";
// The panel's imports reach computerUseState.ts, which installs a window hook on load; this file
// removes it when it is done (test/support/leakDetector.ts).
const hadComputerUseHook = "cmuxAcpmuxComputerUseState" in globalThis;
const { setLastingGrace, LASTING_MS } = await importWithDom(() => import("../../../ui/lasting"));
const { PermissionPanel } = await importWithDom(() => import("./Panel"));

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "CustomEvent",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    CustomEvent: dom.window.CustomEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterAll(() => {
  if (!hadComputerUseHook) delete (globalThis as Record<string, unknown>).cmuxAcpmuxComputerUseState;
});

afterEach(async () => {
  setLastingGrace(LASTING_MS);
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

const readFailed: PermissionClientState = {
  supported: true,
  ready: false,
  groups: [],
  chatAllowance: false,
  loading: false,
  busy: false,
  error: "Permission service is temporarily unavailable.",
};

async function render(state: PermissionClientState): Promise<HTMLElement> {
  const host = installDom();
  root = createRoot(host);
  const none = () => undefined;
  await act(async () => {
    root!.render(
      <PermissionPanel state={state} working onRespond={none} onRetry={none} onRevoke={none} onRefresh={none} />,
    );
  });
  return host;
}

test("a failed read shows nothing before the deadline and no button", async () => {
  const host = await render(readFailed);
  expect(host.querySelector(".acpmux-permission-panel")).toBeNull();
  expect(host.querySelector("button")).toBeNull();
});

test("a lasting failed read shows one quiet line and no button", async () => {
  setLastingGrace(0);
  const host = await render(readFailed);
  expect(host.querySelector("[data-still-trying]")).not.toBeNull();
  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(host.querySelector("button")).toBeNull();
});

test("a failed answer (the read is fine) keeps Refresh", async () => {
  const host = await render({ ...readFailed, ready: true });
  expect(host.querySelector(".acpmux-permission-error button")).not.toBeNull();
  expect(host.querySelector("[data-still-trying]")).toBeNull();
});

test("an answer in doubt keeps Check and retry", async () => {
  const host = await render({ ...readFailed, uncertain: true });
  expect(host.querySelector(".acpmux-permission-error button")).not.toBeNull();
  expect(host.querySelector("[data-still-trying]")).toBeNull();
});
