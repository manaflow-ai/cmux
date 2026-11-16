// Lawrence, 2026-11-15: "sometimes logos in settings doesnt load fast". Each category icon in the sidebar
// is a CSS mask over the host's drawing of its SF Symbol (`symbol-bold/<name>`, MenuSymbolImages): one
// request per icon that the browser makes only when it first paints the row. The page reported its first
// frame before those answers came, so the sidebar showed with empty icon slots and the icons popped in.
// Worse, a parked spare drew its sidebar before any claim, when the host had no drawing to give: those
// requests failed, WebKit kept the failures, and most rows of a page claimed from the pool never showed an
// icon. The page now loads every icon once claimed, masks the rows with them only then, and its paint
// report waits for them.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
// The page as the app serves it (`cmux-page:`, where the host draws the symbols); jsdom keeps its http
// address, which sessionStorage needs.
const served = window.location;
(globalThis as Record<string, unknown>).location = new Proxy(served, {
  get: (target, key) => (key === "protocol" ? "cmux-page:" : Reflect.get(target, key, target)),
});

/** An image the test answers: decoded only once the test says so. */
const decoded = new Set<string>();
const pending: Array<() => void> = [];
class HeldImage {
  src = "";
  decode(): Promise<void> {
    return new Promise((resolve) =>
      pending.push(() => {
        decoded.add(this.src);
        resolve();
      }),
    );
  }
}
(globalThis as Record<string, unknown>).Image = HeldImage;

const { act } = await import("react");
const { createMockClient } = await import("./mockProvider");
const { mountSettingsPage } = await import("./mount");
const { PAINT_AFTER_NAME } = await import("../shared/paintGate");

const scope = globalThis as Record<string, unknown>;
let unmount: (() => void) | undefined;
afterEach(() => {
  act(() => unmount?.());
  unmount = undefined;
  document.body.replaceChildren();
  delete scope[PAINT_AFTER_NAME];
});

test("Settings reports its first frame only once every sidebar icon it draws is loaded", async () => {
  const root = document.createElement("div");
  document.body.append(root);
  let reported = false;
  await act(async () => {
    void mountSettingsPage(root, createMockClient().client).then((stop) => (unmount = stop));
  });
  const gate = scope[PAINT_AFTER_NAME] as Promise<unknown> | undefined;
  expect(gate).toBeDefined();
  void gate!.then(() => (reported = true));
  // Let the page's reads answer and React draw the sidebar.
  for (let turn = 0; turn < 50 && document.querySelectorAll(".section-symbol").length === 0; turn++)
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 5)));
  const icons = () => [...document.querySelectorAll<HTMLElement>(".section-symbol")];
  const drawn = icons().map((icon) => icon.dataset.symbol);
  expect(drawn.length).toBeGreaterThan(10);
  // No row asks for its icon on its own before the page loaded them: a parked spare (no host drawing to
  // read yet) got 404s that WebKit kept, and those rows never showed an icon.
  expect(
    icons()
      .filter((icon) => icon.style.maskImage !== "")
      .map((icon) => icon.dataset.symbol),
  ).toEqual([]);
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 20)));
  expect(reported).toBe(false);
  // The host answers every icon: the first frame comes, with each icon the sidebar draws.
  await act(async () => {
    for (const answer of pending.splice(0)) answer();
    await gate;
  });
  expect(reported).toBe(true);
  const loaded = [...decoded].map((src) => decodeURIComponent(decodeURIComponent(src.replace(/^.*symbol-bold\//, ""))));
  expect(drawn.filter((symbol) => !loaded.includes(symbol!))).toEqual([]);
  expect(
    icons()
      .filter((icon) => !icon.style.maskImage.includes("symbol-bold/"))
      .map((icon) => icon.dataset.symbol),
  ).toEqual([]);
});
