// The idle probe (`debug.agent_pane idle_probe`) counts a page's timers by call site and puts the
// page's own functions back when its window ends; a second probe while one runs is refused, so it
// can never save the first one's wrappers and leave them installed.
/// <reference types="bun" />
import { afterAll, beforeAll, expect, test } from "bun:test";
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

test("a probe counts timeouts by call site and restores the page's functions", async () => {
  const { idleProbe } = await import("../src/agent-session/acpmux/idleProbe");
  const before = { raf: window.requestAnimationFrame, timeout: window.setTimeout, interval: window.setInterval };
  const running = idleProbe({ ms: 150 });
  window.setTimeout(() => undefined, 5);
  window.setTimeout(() => undefined, 5);
  const result = (await running) as { per_second: { timeouts: number }; timeouts: { count: number }[] };
  expect(result.timeouts.reduce((sum, site) => sum + site.count, 0)).toBe(2);
  expect(window.requestAnimationFrame).toBe(before.raf);
  expect(window.setTimeout).toBe(before.timeout);
  expect(window.setInterval).toBe(before.interval);
});

test("a second probe while one runs is refused and the first still restores", async () => {
  const { idleProbe } = await import("../src/agent-session/acpmux/idleProbe");
  const original = window.setTimeout;
  const first = idleProbe({ ms: 200 });
  const second = await idleProbe({ ms: 100 });
  expect(second).toEqual({ error: "an idle probe is already running" });
  await first;
  expect(window.setTimeout).toBe(original);
});
