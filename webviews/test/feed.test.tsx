import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { FeedApp, feedActivityPageSize } from "../src/feed/App";
import { receiveFeedNativeEvent } from "../src/feed/bridge";

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, any>();
for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement"]) {
  originalGlobals.set(key, (globalThis as any)[key]);
}

afterEach(async () => {
  if (root) flushSync(() => root?.unmount());
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) delete (globalThis as any)[key];
    else (globalThis as any)[key] = value;
  }
});

test("Feed React surface invokes the typed permission primitive", async () => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", { url: "file:///feed.html" });
  for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement"]) {
    (globalThis as any)[key] = (dom.window as any)[key] ?? dom.window;
  }
  const calls: unknown[] = [];
  let subscribedSnapshot: any;
  (window as any).webkit = { messageHandlers: { cmuxFeed: { postMessage: async (message: any) => {
    calls.push(message);
    if (message.method === "feed.subscribe") {
      subscribedSnapshot = {
        copy: {
          actionable: "Actionable", activity: "All Activity", allowAll: "All tools",
          allowAlways: "Always Allow", allowBypass: "Bypass",
          allowOnce: "Allow Once", deny: "Deny", emptyActionable: "No pending decisions",
          emptyActionableDescription: "Requests from agents appear here.",
          emptyActivity: "No activity yet", emptyActivityDescription: "Agent activity appears here.",
          feed: "Feed", integrationChecking: "Checking...", integrationDisabled: "Disabled in Settings",
          integrationHint: "Claude and Codex use Settings. Other agents need hooks setup.",
          integrationNeedsSetup: "Setup needed", integrationReady: "Ready",
          integrationsTitle: "Agent integrations", keyboardHelp: "Use J/K to navigate.",
          loadOlder: "Load older activity",
          loadingOlder: "Loading older activity...", planAuto: "Auto", planManual: "Manual",
          planUltraplan: "Ultraplan", questionPlaceholder: "Type something...",
          questionSubmit: "Submit All Answers", requestFailed: "Native bridge request failed.",
        },
        hasMore: false,
        isLoadingOlder: false,
        integrations: [
          { source: "claude", status: "ready" },
          { source: "codex", status: "disabled" },
          { source: "opencode", status: "needsSetup" },
        ],
        sourceIcons: {
          claude: "data:image/png;base64,Y2xhdWRl",
          codex: "data:image/png;base64,Y29kZXg=",
          opencode: "data:image/png;base64,b3BlbmNvZGU=",
        },
        sourceLabels: { claude: "Claude Code", codex: "Codex", opencode: "OpenCode" },
        theme: { background: "#272822", foreground: "#f8f8f2", isLight: false },
        items: [{
          created_at: "2026-07-13T12:00:00Z", id: "item-1", kind: "permissionRequest",
          request_id: "request-1", source: "claude", status: "pending", tool_name: "Bash",
          tool_input: "echo ok", workstream_id: "claude-session",
          allowed_permission_modes: ["deny", "once", "always", "all"],
        }, {
          created_at: "2026-07-13T12:01:00Z", id: "item-2", kind: "toolUse",
          source: "codex", status: "telemetry", title: "Apply patch", workstream_id: "codex-session",
        }, {
          created_at: "2026-07-13T12:02:00Z", id: "item-3", kind: "toolUse",
          source: "opencode", status: "telemetry", title: "Run tests", workstream_id: "opencode-session",
        }, ...Array.from({ length: 45 }, (_, index) => ({
          created_at: "2026-07-13T12:03:00Z", id: `history-${index}`, kind: "toolUse",
          source: "codex", status: "telemetry" as const, title: `History ${index}`, workstream_id: "codex-history",
        }))],
      };
      return { ok: true, value: subscribedSnapshot };
    }
    return { ok: true, value: { accepted: true } };
  } } } };

  const container = document.getElementById("root")!;
  root = createRoot(container);
  flushSync(() => root?.render(<FeedApp />));
  await waitFor(() => container.textContent?.includes("Bash") === true);
  expect(container.querySelector("main")?.getAttribute("style") ?? "").toContain("--feed-background: #272822");
  expect(container.querySelector('[data-feed-source="claude"] .feed-source-logo')).toBeTruthy();
  expect(container.querySelector('[data-feed-source="claude"]')?.textContent).toContain("Claude");
  const actionableTab = [...container.querySelectorAll<HTMLButtonElement>("button")]
    .find((button) => button.textContent === "Actionable")!;
  actionableTab.focus();
  flushSync(() => actionableTab.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "ArrowRight" })));
  expect(document.activeElement?.textContent).toBe("All Activity");
  expect(document.activeElement?.getAttribute("aria-selected")).toBe("true");
  document.activeElement?.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "Tab" }));
  expect(document.activeElement?.textContent).toBe("Deny");
  document.activeElement?.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "Tab", shiftKey: true }));
  expect(document.activeElement?.textContent).toBe("All Activity");
  const loadOlder = [...container.querySelectorAll<HTMLButtonElement>("button")]
    .find((button) => button.textContent === "Load older activity")!;
  loadOlder.focus();
  loadOlder.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "Tab" }));
  expect(document.activeElement?.textContent).toBe("All Activity");
  expect(container.querySelector('[data-feed-source="codex"]')?.textContent).toContain("Codex");
  expect(container.querySelector('[data-feed-source="opencode"]')?.textContent).toContain("OpenCode");
  expect(feedActivityPageSize).toBe(40);
  expect(container.querySelectorAll(".feed-card")).toHaveLength(feedActivityPageSize);
  const cards = [...container.querySelectorAll<HTMLElement>(".feed-card")];
  const keyboardRoot = container.querySelector<HTMLElement>(".feed-keyboard-root")!;
  keyboardRoot.focus();
  keyboardRoot.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "j" }));
  expect(document.activeElement).toBe(cards[0]);
  cards[0]?.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, ctrlKey: true, key: "n" }));
  expect(document.activeElement).toBe(cards[1]);
  cards[1]?.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "ArrowUp" }));
  expect(document.activeElement).toBe(cards[0]);
  cards[0]?.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "End" }));
  expect(document.activeElement).toBe(cards[cards.length - 1]!);
  const input = document.createElement("input");
  keyboardRoot.append(input);
  input.focus();
  input.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, key: "ArrowDown" }));
  expect(document.activeElement).toBe(input);
  input.remove();
  flushSync(() => [...container.querySelectorAll("button")].find((button) => button.textContent === "Load older activity")?.click());
  expect(container.querySelectorAll(".feed-card")).toHaveLength(48);
  const allowOnce = [...container.querySelectorAll("button")].find((button) => button.textContent === "Allow Once")!;
  allowOnce.click();
  await waitFor(() => calls.some((call: any) => call.method === "feed.permission.reply"));
  expect(calls).toContainEqual({ method: "feed.permission.reply", params: { itemId: "item-1", mode: "once" } });
  flushSync(() => receiveFeedNativeEvent({
    snapshot: { ...subscribedSnapshot, items: [] },
    type: "feed.snapshot",
  }));
  expect(container.textContent).toContain("No activity yet");
  expect(container.textContent).toContain("Agent integrations");
  expect(container.textContent).toContain("Claude CodeReady");
  expect(container.textContent).toContain("CodexDisabled in Settings");
  expect(container.textContent).toContain("OpenCodeSetup needed");
  expect(container.textContent).toContain("Use J/K to navigate.");
});

async function waitFor(predicate: () => boolean, timeout = 1_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("condition not met");
}
