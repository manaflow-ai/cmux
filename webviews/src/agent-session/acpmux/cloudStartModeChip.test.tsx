// A new chat whose first send starts it on a Cloud machine: the Mode chip names the mode that machine
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

const FOLDER = "/Users/test/cloud-proof";

/// A new chat on `harness` (family `family`) before its first send, with Cloud picked as where it runs.
function cloudNewChat(harness: string, family: string, cloud = true): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    link: "connected",
    emitReason: "test",
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [{ id: harness, name: harness, family, models: [] }],
    origin: "local",
    summary: { sessionId: "", harness, turnCount: 0, cwd: FOLDER },
    ...(cloud ? { startsOnCloud: true as const } : {}),
  };
}

/// The chip's text for `snapshot`, after this Mac's acpmux answered `kept` for its harness (none: a
/// fresh viewer, nothing answered or asked yet).
async function chipText(
  snapshot: AcpmuxSnapshot,
  kept?: { modeId: string; name: string },
): Promise<string | undefined> {
  await teardown();
  const container = installDom();
  const harness = snapshot.summary?.harness;
  if (kept && harness) rememberStartMode(harness, FOLDER, kept);
  root = createRoot(container);
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
  return container.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent?.trim();
}

const BYPASS = { modeId: "bypassPermissions", name: "Bypass permissions" };
const MANUAL = { modeId: "default", name: "Manual" };

test("a Claude Cloud start names Auto when new chats start in full access", async () => {
  expect(await chipText(cloudNewChat("claude", "claude"), BYPASS)).toBe("Auto");
});

test("a Claude Cloud start names Auto on its first frame, before any start-mode answer", async () => {
  // A fresh viewer: no answer kept, none asked yet. The default level is full access, so the chip
  // never shows Manual and then flips once the chat reports.
  expect(await chipText(cloudNewChat("claude", "claude"))).toBe("Auto");
});

test("a Codex Cloud start names Full access by default", async () => {
  expect(await chipText(cloudNewChat("codex", "codex"))).toBe("Full access");
  expect(await chipText(cloudNewChat("codex", "codex"), { modeId: "agent-full-access", name: "Full access" })).toBe(
    "Full access",
  );
});

test("a person whose new chats ask keeps the asking mode on a Cloud start", async () => {
  // acpmux on this Mac answered the person's `ask` level: Claude Code's Manual; Codex's Ask.
  expect(await chipText(cloudNewChat("claude", "claude"), MANUAL)).toBe("Manual");
  expect(await chipText(cloudNewChat("codex", "codex"), { modeId: "agent", name: "Ask for approval" })).toBe("Ask");
});

test("a new chat on this Mac still names this Mac's start mode", async () => {
  expect(await chipText(cloudNewChat("claude", "claude", false), MANUAL)).toBe("Manual");
  expect(await chipText(cloudNewChat("claude", "claude", false), BYPASS)).toBe("Bypass permissions");
});
