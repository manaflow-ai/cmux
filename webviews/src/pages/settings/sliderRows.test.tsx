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
      mock: { values: { "appearance.background": "goya-saturn", "appearance.theme": "Dracula" } },
    });
    await changeValue(slider(OPACITY), "0.55");
    await fire(slider(OPACITY), "pointerup");
    const rows = page.store.getSnapshot().rows;
    expect(rows.get(OPACITY)?.value).toBe(0.55);
    expect(rows.get("appearance.background")?.value).toBe("goya-saturn");
    expect(rows.get("appearance.theme")?.value).toBe("Dracula");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: OPACITY, value: 0.55 }]);
  });

  test("over a background picture the window opacity slider stops at 95%", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "goya-saturn" } },
    });
    expect(slider(OPACITY).max).toBe("0.95");
  });

  // Leo, 10-19: "the knob, the slider still doesn't work". Over a picture the window never paints
  // below the legibility floor (0.82 to 1.0 for the bundled themes), so the slider's travel below
  // it moved nothing. The slider now starts at the floor the app reports, on the step grid, and
  // says why it starts there.
  test("over a background picture the slider starts at the legibility floor the app reports", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "goya-saturn" } },
    });
    await run(() => page!.provider.setHost({ ...page!.provider.host, derived_min: { [OPACITY]: 0.62 } }));
    expect(slider(OPACITY).min).toBe("0.65");
    expect(slider(OPACITY).max).toBe("0.95");
    expect(rowElement(page.container, OPACITY).textContent).toContain("65%");
  });

  // A floor at or above 95% leaves the slider no travel: it is disabled, not a thumb that cannot move.
  test("over a picture whose floor reaches 95% the slider is disabled", async () => {
    page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { "appearance.background": "goya-saturn" } },
    });
    await run(() => page!.provider.setHost({ ...page!.provider.host, derived_min: { [OPACITY]: 0.93 } }));
    expect(slider(OPACITY).min).toBe("0.95");
    expect(slider(OPACITY).disabled).toBe(true);
    expect(rowElement(page.container, OPACITY).textContent).toContain("95%");
  });

  test("without a picture the window opacity slider keeps its whole range", async () => {
    page = await renderPage({ path: "/settings/appearance", mock: { values: { "appearance.background": "none" } } });
    await run(() => page!.provider.setHost({ ...page!.provider.host, derived_min: {} }));
    expect(slider(OPACITY).min).toBe("0");
    expect(slider(OPACITY).max).toBe("1");
  });
});
