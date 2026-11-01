import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

// Leo, 10-19: "the slider doesnt work and just reverts to 'ghostty'"; "these sliders the moment
// you click it just jumps". An unset slider rests on the live value, a release anywhere writes it,
// and the thumb never snaps back while the write is in flight.
const restore = installDom();
afterAll(() => restore());
const { changeValue, fire, ops, renderPage, rowElement, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

describe("slider rows", () => {
  const OPACITY = "appearance.backgroundOpacity";
  const SURFACE = "appearance.surfaces.sidebar.opacity";
  const slider = (key: string) =>
    rowElement(page!.container, key).querySelector<HTMLInputElement>('input[type="range"]')!;
  const field = (key: string) => rowElement(page!.container, key).querySelector<HTMLInputElement>("input.number")!;

  test("Interface Size always offers Reset, and a changed size resets through the owner", async () => {
    const key = "appearance.metrics.chromeFontSize";
    page = await renderPage({ path: "/settings/appearance" });
    const reset = () => rowElement(page!.container, key).querySelector<HTMLButtonElement>(".reset-button")!;
    expect(reset().getAttribute("aria-hidden")).toBeNull();
    expect(reset().disabled).toBe(true);
    await changeValue(slider(key), "16");
    await fire(slider(key), "change");
    expect(reset().disabled).toBe(false);
    await fire(reset(), "click");
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key }]);
    expect(page.store.getSnapshot().rows.get(key)?.customized).toBe(false);
    expect(reset().disabled).toBe(true);
  });

  test("an unset surface opacity rests on the window's opacity, dimmed, with a badge", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.provider.setHost({ ...page!.provider.host, derived: { [OPACITY]: 0.8 } }));
    expect(slider(SURFACE).value).toBe("0.8");
    expect(field(SURFACE).value).toBe("80");
    expect(field(SURFACE).hasAttribute("data-inherited")).toBe(true);
    expect(rowElement(page.container, SURFACE).querySelector(".inherit-badge")?.textContent).toBe("Inherits window");
    // A window value the person set wins over the derived one.
    await run(() => page!.store.set(OPACITY, 0.6));
    expect(slider(SURFACE).value).toBe("0.6");
    expect(field(SURFACE).value).toBe("60");
  });

  test("the unset window opacity shows the derived number, never the 'Ghostty' label", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.provider.setHost({ ...page!.provider.host, derived: { [OPACITY]: 0.35 } }));
    const row = rowElement(page.container, OPACITY);
    expect(field(OPACITY).value).toBe("35");
    expect(row.querySelector(".inherit-badge")?.textContent).toBe("Automatic");
  });

  test("a drag released off the slider still writes once (the native change event)", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await changeValue(slider(SURFACE), "0.45");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    // No pointerup reaches the slider: the pointer was released over another element.
    await fire(slider(SURFACE), "change");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: SURFACE, value: 0.45 }]);
    expect(ops(page.provider, "cmux.settings.preview.end")).toEqual([{ key: SURFACE }]);
    await fire(slider(SURFACE), "pointerup");
    await fire(slider(SURFACE), "blur");
    expect(ops(page.provider, "cmux.settings.set")).toHaveLength(1);
  });

  test("on release the thumb keeps the released value while the write is in flight", async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await run(() => page!.provider.setHost({ ...page!.provider.host, derived: { [OPACITY]: 1 } }));
    let finish: () => void = () => {};
    const gate = new Promise<void>((resolve) => (finish = resolve));
    const set = page.store.set.bind(page.store);
    page.store.set = async (key, value) => {
      await gate;
      return set(key, value);
    };
    await changeValue(slider(OPACITY), "0.5");
    await fire(slider(OPACITY), "pointerup");
    // Before the fix the thumb jumped back to the unset 100% and the field to its label here.
    expect(slider(OPACITY).value).toBe("0.5");
    expect(field(OPACITY).value).toBe("50");
    finish();
    await run(() => gate);
    expect(slider(OPACITY).value).toBe("0.5");
  });

  test("an opacity write changes neither the theme nor the background", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "friedrich-forest-moonlight", "appearance.theme": "Dracula" } },
    });
    await changeValue(slider(OPACITY), "0.55");
    await fire(slider(OPACITY), "pointerup");
    const rows = page.store.getSnapshot().rows;
    expect(rows.get(OPACITY)?.value).toBe(0.55);
    expect(rows.get("appearance.background")?.value).toBe("friedrich-forest-moonlight");
    expect(rows.get("appearance.theme")?.value).toBe("Dracula");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: OPACITY, value: 0.55 }]);
  });

  test("over a background picture the window opacity slider reaches 100%", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "friedrich-forest-moonlight" } },
    });
    expect(slider(OPACITY).max).toBe("1");
  });

  // Leo, 10-20: readability over a picture comes from opacity, blur and glass, never from the
  // picture, so there is no legibility floor: the slider's whole travel changes the window.
  test("over a background picture the slider keeps its whole travel", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "friedrich-forest-moonlight" } },
    });
    // A host that still sends a floor (an older app) does not narrow the slider.
    const olderHost = { ...page!.provider.host, derived_min: { [OPACITY]: 0.62 } };
    await run(() => page!.provider.setHost(olderHost));
    expect(slider(OPACITY).min).toBe("0");
    expect(slider(OPACITY).max).toBe("1");
    expect(slider(OPACITY).disabled).toBe(false);
  });

  test("without a picture the window opacity slider keeps its whole range", async () => {
    page = await renderPage({ path: "/settings/appearance", mock: { values: { "appearance.background": "none" } } });
    expect(slider(OPACITY).min).toBe("0");
    expect(slider(OPACITY).max).toBe("1");
  });
});
