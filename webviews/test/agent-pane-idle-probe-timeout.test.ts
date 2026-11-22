// `debug.agent_pane idle_probe` runs idleProbe in the page through PageWebView.callPageScript, which in
// Chromium is one `Runtime.evaluate` awaiting the promise on CEFTab.devTools' default deadline. A probe
// window at or past that deadline can never answer under Chromium, so the default and the clamp stay
// under it with a margin. The deadline is read from the Swift source: changing either side fails here.
/// <reference types="bun" />
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";

const window = new Window();
const saved: Record<string, unknown> = {};
const names = ["window", "document", "MutationObserver", "performance", "Element"] as const;

beforeAll(() => {
  for (const name of names) saved[name] = (globalThis as Record<string, unknown>)[name];
  Object.assign(globalThis, {
    window,
    document: window.document,
    MutationObserver: window.MutationObserver,
    Element: window.Element,
  });
});

afterAll(() => {
  for (const name of names) (globalThis as Record<string, unknown>)[name] = saved[name];
  void window.happyDOM.close();
});

/** CEFTab.devTools' default deadline in ms, the one callPageScript's `Runtime.evaluate` runs on. */
function chromiumScriptDeadlineMs(): number {
  const swift = readFileSync(
    new URL("../../Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFTab+Events.swift", import.meta.url),
    "utf8",
  );
  const match =
    /public func devTools\(method: String, params: \[String: any Sendable\], timeout: Duration = \.seconds\((\d+(?:\.\d+)?)\)\)/.exec(
      swift,
    );
  if (!match) throw new Error("CEFTab.devTools' default timeout moved: update idleProbe's bound and this test");
  return Number(match[1]) * 1000;
}

test("the probe's default and maximum window end before Chromium's script deadline, with margin", async () => {
  const probe = await import("../src/agent-session/acpmux/idleProbe");
  const deadline = chromiumScriptDeadlineMs();
  expect(deadline).toBe(probe.CHROMIUM_SCRIPT_DEADLINE_MS);
  expect(probe.IDLE_PROBE_DEFAULT_MS).toBeLessThanOrEqual(probe.IDLE_PROBE_MAX_MS);
  // At least 1 s for the page script's hook lookup, wrapping, the summary and the reply.
  expect(probe.IDLE_PROBE_MAX_MS).toBeLessThanOrEqual(deadline - 1000);
});

async function windowAsked(options: { ms?: number }): Promise<number> {
  const { idleProbe } = await import("../src/agent-session/acpmux/idleProbe");
  const original = window.setTimeout;
  let asked = -1;
  // The probe's window is one timeout on the page's own setTimeout: record its delay and end it now.
  window.setTimeout = ((handler: () => void, timeout?: number) => {
    if (asked < 0) asked = timeout ?? 0;
    handler();
    return 0;
  }) as unknown as typeof window.setTimeout;
  try {
    await idleProbe(options);
  } finally {
    window.setTimeout = original;
  }
  return asked;
}

test("a probe asked for longer than the maximum is clamped to it, and no ms takes the default", async () => {
  const probe = await import("../src/agent-session/acpmux/idleProbe");
  expect(await windowAsked({ ms: 30_000 })).toBe(probe.IDLE_PROBE_MAX_MS);
  expect(await windowAsked({})).toBe(probe.IDLE_PROBE_DEFAULT_MS);
  expect(await windowAsked({ ms: 3500 })).toBe(3500);
});
