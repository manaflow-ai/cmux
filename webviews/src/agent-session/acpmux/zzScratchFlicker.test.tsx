// scratch
// starts it in from the first frame. On the person's own Cloud machine that is their start level for
// new chats (`agents.defaultPermissionMode`, full access unless they set otherwise), as on this Mac
// (cmux-tui agent_session_start.rs `start_policy`, `cloud_default_mode`): Claude Code's Auto, Full
// access for Codex. Lawrence 2026-11-20: "cloud mode should default in bypass permissions/auto mode",
// then "we need to support auto mode for cloud mode for claude harness".
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import { ComposerPickers } from "./ComposerPickers";
import { rememberStartMode, resetStartModesForTests } from "./startMode";
import { clearCloudModePick } from "./cloudModePick";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "getComputedStyle",
    "MutationObserver",
    "ResizeObserver",
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
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  resetStartModesForTests();
  clearCloudModePick();
  return dom.window.document.getElementById("root")!;
}

async function teardown(): Promise<void> {
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
  resetStartModesForTests();
  clearCloudModePick();
}

afterEach(teardown);
const FOLDER = "/Users/test/proj";
const MODES = {
  currentModeId: "bypassPermissions",
  availableModes: [
    { id: "default", name: "Default" },
    { id: "acceptEdits", name: "Accept Edits" },
    { id: "plan", name: "Plan Mode" },
    { id: "bypassPermissions", name: "Bypass Permissions" },
  ],
};
function snap(extra: Partial<AcpmuxSnapshot>, summary: any): AcpmuxSnapshot {
  return {
    type: "snapshot", protocolVersion: 1, rows: [], sessions: [], connection: "test", isWorking: false, queue: [],
    canLoadOlder: false, catalog: [{ id: "claude", name: "Claude Code", family: "claude", models: [] }], origin: "local",
    ...(summary ? { summary: { harness: "claude", family: "claude", cwd: FOLDER, turnCount: 0, ...summary } } : {}),
    ...extra,
  } as AcpmuxSnapshot;
}
async function seq(name: string, snaps: AcpmuxSnapshot[], kept?: any) {
  await teardown();
  const container = installDom();
  if (kept !== undefined) rememberStartMode("claude", FOLDER, kept);
  root = createRoot(container);
  const out: string[] = [];
  for (const s of snaps) {
    await act(async () => {
      root!.render(<ComposerPickers snapshot={s} harnessesListed onModel={() => undefined} onMode={() => undefined} onEffort={() => undefined} showPlan />);
    });
    const el = container.querySelector(".acpmux-mode");
    out.push(el ? (el.querySelector(".acpmux-mode-text")?.textContent?.trim() ?? `<${el.className}|${el.getAttribute("data-fit-title")}>`) : "-");
  }
  console.log(name, JSON.stringify(out));
}
test("sequences", async () => {
  const BY = { modeId: "bypassPermissions", name: "Bypass permissions" };
  // New tab -> session id w/o modes -> modes
  await seq("newtab-fresh", [snap({}, { sessionId: "" }), snap({ sessionId: "s1" }, { sessionId: "s1" }), snap({ sessionId: "s1" }, { sessionId: "s1", modes: MODES })]);
  await seq("newtab-kept", [snap({}, { sessionId: "" }), snap({ sessionId: "s1" }, { sessionId: "s1" }), snap({ sessionId: "s1" }, { sessionId: "s1", modes: MODES })], BY);
  await seq("newtab-null", [snap({}, { sessionId: "" }), snap({ sessionId: "s1" }, { sessionId: "s1", modes: MODES })], null);
  // opening a listed chat: no summary, then summary w/o modes, then with
  const row = { sessionId: "s2", harness: "claude", unsent: false } as any;
  await seq("open-ran", [snap({ sessionId: "s2", sessions: [row] }, undefined), snap({ sessionId: "s2", sessions: [row] }, { sessionId: "s2", turnCount: 3 }), snap({ sessionId: "s2", sessions: [row] }, { sessionId: "s2", turnCount: 3, modes: MODES })], BY);
  const row2 = { sessionId: "s3", harness: "claude", unsent: true } as any;
  await seq("open-unsent", [snap({ sessionId: "s3", sessions: [row2] }, undefined), snap({ sessionId: "s3", sessions: [row2] }, { sessionId: "s3" }), snap({ sessionId: "s3", sessions: [row2] }, { sessionId: "s3", modes: MODES })], BY);
  await seq("open-unsent-default", [snap({ sessionId: "s3", sessions: [row2] }, undefined), snap({ sessionId: "s3", sessions: [row2] }, { sessionId: "s3", modes: { ...MODES, currentModeId: "default" } })], BY);
});
