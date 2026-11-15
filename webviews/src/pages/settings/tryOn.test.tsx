// The try-on bar: while a customization is tried on, Settings shows its time left with Keep and
// Revert Now; with none, nothing. The revert itself is the engine's (cmux-customize try_on.rs).
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage, run } = await import("./testing");
const { timeLeft } = await import("./components/TryOnBar");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const tryOn = (leftMs: number) => ({
  generation: 7,
  revert_to: 6,
  started_ms: Date.now() - 60_000,
  expires_ms: Date.now() + leftMs,
  label: "profile night",
  origin: "cli",
});

const bar = (page: Rendered) => page.container.querySelector<HTMLElement>("[data-try-on]");

test("no try-on, no bar", async () => {
  page = await renderPage();
  await run(() => undefined);
  expect(bar(page)).toBeNull();
});

test("a try-on shows its label, its time left, Keep and Revert Now", async () => {
  page = await renderPage({ mock: { tryOn: tryOn(9 * 60_000 + 30_000) } });
  await run(() => undefined);
  const shown = bar(page)!;
  expect(shown).not.toBeNull();
  expect(shown.textContent).toContain("Trying on profile night");
  expect(shown.querySelector("[data-try-on-left]")!.textContent).toMatch(/^Goes back in 9:(29|30)$/);
  expect(shown.querySelector("[data-try-on-keep]")!.textContent).toBe("Keep");
  expect(shown.querySelector("[data-try-on-revert]")!.textContent).toBe("Revert Now");
});

test("Keep runs `customize keep` and the bar goes", async () => {
  page = await renderPage({ mock: { tryOn: tryOn(5 * 60_000) } });
  await run(() => undefined);
  await click(bar(page)!.querySelector("[data-try-on-keep]")!);
  await run(() => undefined);
  expect(page.provider.customizeVerbs).toEqual(["keep"]);
  expect(bar(page)).toBeNull();
});

test("Revert Now runs `customize revert` and the bar goes", async () => {
  page = await renderPage({ mock: { tryOn: tryOn(5 * 60_000) } });
  await run(() => undefined);
  await click(bar(page)!.querySelector("[data-try-on-revert]")!);
  await run(() => undefined);
  expect(page.provider.customizeVerbs).toEqual(["revert"]);
  expect(bar(page)).toBeNull();
});

test("the time left reads in minutes and seconds, rounded up", () => {
  expect(timeLeft(9 * 60_000 + 5_000)).toBe("9:05");
  expect(timeLeft(41_200)).toBe("0:42");
  expect(timeLeft(1)).toBe("0:01");
  expect(timeLeft(-5)).toBe("0:00");
});
