// Settings > Advanced > Extensions: one row per installed extension with the daemon's meter
// (`cmux apps meters`), and while safe mode is on the bisect's steps (`cmux safe-mode bisect`),
// each sent to the host and drawn from its answer. With no extension installed there is no card.
import { afterAll, afterEach, expect, test } from "bun:test";
import type { ExtensionMeter } from "./ops";
import type { MockOptions } from "./mockProvider";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const meter = (app: string, extra: Partial<ExtensionMeter> = {}): ExtensionMeter => ({
  app,
  step: "normal",
  host: "running",
  crashes: 0,
  mounts: 1,
  widgets: 0,
  slowedMounts: 0,
  batches: { in: 40, out: 31 },
  held: 9,
  ...extra,
});
const card = () => page!.container.querySelector<HTMLElement>('[data-card="extensions"]');
const row = (app: string) => card()!.querySelector<HTMLElement>(`[data-extension-meter="${app}"]`)!;
const steps = () =>
  [...card()!.querySelectorAll<HTMLButtonElement>("[data-bisect-step]")].map((b) => b.dataset.bisectStep);
const step = (verb: string) => card()!.querySelector<HTMLButtonElement>(`[data-bisect-step="${verb}"]`)!;

async function open(mock?: MockOptions) {
  page = await renderPage({ path: "/settings/advanced", mock });
  await settle();
  return page;
}

test("no extension installed: Advanced draws no Extensions card", async () => {
  await open();
  expect(card()).toBeNull();
});

test("each installed extension is one row with its meter in words, and no bisect outside safe mode", async () => {
  await open({
    extensions: {
      meters: [meter("acme/notes"), meter("local/spy", { step: "paused", paused: "over its batch rate", crashes: 2 })],
    },
  });
  expect(row("acme/notes").textContent).toContain("Running · 1 views · 40 updates, 9 held");
  expect(row("acme/notes").querySelector("[data-meter-step]")!.textContent).toBe("Normal");
  expect(row("local/spy").dataset.step).toBe("paused");
  expect(row("local/spy").textContent).toContain("Paused (over its batch rate)");
  expect(row("local/spy").textContent).toContain("2 crashes");
  expect(card()!.querySelector("[data-extension-bisect]")).toBeNull();
});

test("in safe mode the bisect runs to the broken extension and ends", async () => {
  page = await open({
    extensions: { meters: ["a/one", "a/two", "a/three", "a/four"].map((app) => meter(app)), safeMode: true },
  });
  expect(steps()).toEqual(["start"]);
  await click(step("start"));
  await settle();
  expect(card()!.textContent).toContain("Running: a/four, a/one.");
  expect(steps()).toEqual(["good", "bad", "reset"]);
  await click(step("bad"));
  await settle();
  await click(step("good"));
  await settle();
  expect(card()!.textContent).toContain("a/one breaks cmux.");
  expect(steps()).toEqual(["reset"]);
  await click(step("reset"));
  await settle();
  expect(steps()).toEqual(["start"]);
  expect(page.provider.bisectSteps).toEqual(["start", "bad", "good", "reset"]);
});
