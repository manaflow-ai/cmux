// The access chip across a chat's load-in: a session acpmux attached reports its id before its
// modes. The chip keeps the start mode through that gap, never blanking between "Bypass
// permissions" and the reported mode (Leo 2026-11-26: "the bypass permissions appears then
// disappears after it loaded in").
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import { ComposerPickers } from "./ComposerPickers";
import { rememberStartMode, resetStartModesForTests } from "./startMode";
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
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "MutationObserver",
  "ResizeObserver",
] as const;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
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
  resetStartModesForTests();
});

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

function snap(
  harness: { id: string; family: string; modeless?: true },
  sessionId: string,
  modes?: typeof MODES,
): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [
      {
        id: harness.id,
        name: harness.id,
        family: harness.family,
        models: [],
        ...(harness.modeless ? { modeless: true } : {}),
      },
    ],
    origin: "local",
    ...(sessionId ? { sessionId } : {}),
    summary: {
      sessionId,
      harness: harness.id,
      family: harness.family,
      cwd: FOLDER,
      turnCount: 0,
      ...(modes ? { modes } : {}),
    },
  } as AcpmuxSnapshot;
}

/// The access chip's text after each snapshot ("-": no chip).
async function chipFrames(snapshots: AcpmuxSnapshot[]): Promise<string[]> {
  const container = installDom();
  rememberStartMode(snapshots[0]!.summary!.harness!, FOLDER, {
    modeId: "bypassPermissions",
    name: "Bypass permissions",
  });
  root = createRoot(container);
  const frames: string[] = [];
  for (const snapshot of snapshots) {
    await act(async () => {
      root!.render(
        <ComposerPickers
          snapshot={snapshot}
          harnessesListed
          onModel={() => undefined}
          onMode={() => undefined}
          onEffort={() => undefined}
          showPlan
        />,
      );
    });
    const chip = container.querySelector(".acpmux-mode");
    frames.push(chip ? (chip.querySelector(".acpmux-mode-text")?.textContent?.trim() ?? "") : "-");
  }
  return frames;
}

const CLAUDE = { id: "claude", family: "claude" };

test("a new Claude chat keeps Bypass permissions while its session attaches before reporting modes", async () => {
  expect(await chipFrames([snap(CLAUDE, ""), snap(CLAUDE, "s1"), snap(CLAUDE, "s1", MODES)])).toEqual([
    "Bypass permissions",
    "Bypass permissions",
    "Bypass permissions",
  ]);
});

test("a harness that reports no modes holds no chip once its session attached", async () => {
  const pi = { id: "pi", family: "pi", modeless: true as const };
  expect((await chipFrames([snap(pi, ""), snap(pi, "s1")])).at(-1)).toBe("-");
});
