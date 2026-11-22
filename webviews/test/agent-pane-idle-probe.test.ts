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

test("a probe counts host pushes by method and puts the transport's receive back", async () => {
  const { idleProbe } = await import("../src/agent-session/acpmux/idleProbe");
  const got: unknown[] = [];
  const transport = { receive: (event: unknown) => void got.push(event) };
  const original = transport.receive;
  (window as unknown as { cmuxAcpmuxTransport: unknown }).cmuxAcpmuxTransport = transport;
  const running = idleProbe({ ms: 150 });
  const frame = (update: string) =>
    JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { update: { sessionUpdate: update } } });
  transport.receive({ connection: 1, frames: [frame("usage_update"), frame("usage_update"), '{"id":3,"result":{}}'] });
  const result = (await running) as { pushes: { site: string; count: number; sample: string }[] };
  expect(result.pushes).toEqual([
    { site: "session/update usage_update", count: 2, sample: "" },
    { site: "reply", count: 1, sample: "" },
  ]);
  expect(got).toHaveLength(1);
  expect(transport.receive).toBe(original);
  delete (window as unknown as { cmuxAcpmuxTransport?: unknown }).cmuxAcpmuxTransport;
});

test("posts between two counts keep only the methods that grew", async () => {
  const { postsBetween } = await import("../src/agent-session/acpmux/idleProbe");
  expect([...postsBetween({ a: 2, b: 1 }, { a: 5, b: 1, c: 1 }).entries()]).toEqual([
    ["a", { count: 3, sample: "" }],
    ["c", { count: 1, sample: "" }],
  ]);
});
