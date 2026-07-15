import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { FeedApp } from "../src/feed/App";

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
  (window as any).webkit = { messageHandlers: { cmuxFeed: { postMessage: async (message: any) => {
    calls.push(message);
    if (message.method === "feed.subscribe") {
      return { ok: true, value: {
        copy: {
          actionable: "Actionable", activity: "All Activity", allowAll: "All tools",
          allowAlways: "Always Allow", allowBypass: "Bypass",
          allowOnce: "Allow Once", deny: "Deny", emptyActionable: "No pending decisions",
          emptyActivity: "No activity yet", feed: "Feed", loadOlder: "Load older activity",
          loadingOlder: "Loading older activity...", planAuto: "Auto", planManual: "Manual",
          planUltraplan: "Ultraplan", questionPlaceholder: "Type something...",
          questionSubmit: "Submit All Answers", requestFailed: "Native bridge request failed.",
        },
        hasMore: false,
        isLoadingOlder: false,
        items: [{
          created_at: "2026-07-13T12:00:00Z", id: "item-1", kind: "permissionRequest",
          request_id: "request-1", source: "claude", status: "pending", tool_name: "Bash",
          tool_input: "echo ok", workstream_id: "claude-session",
          allowed_permission_modes: ["deny", "once", "always", "all"],
        }],
      } };
    }
    return { ok: true, value: { accepted: true } };
  } } } };

  const container = document.getElementById("root")!;
  root = createRoot(container);
  flushSync(() => root?.render(<FeedApp />));
  await waitFor(() => container.textContent?.includes("Bash") === true);
  const allowOnce = [...container.querySelectorAll("button")].find((button) => button.textContent === "Allow Once")!;
  allowOnce.click();
  await waitFor(() => calls.some((call: any) => call.method === "feed.permission.reply"));
  expect(calls).toContainEqual({ method: "feed.permission.reply", params: { itemId: "item-1", mode: "once" } });
});

async function waitFor(predicate: () => boolean, timeout = 1_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("condition not met");
}
