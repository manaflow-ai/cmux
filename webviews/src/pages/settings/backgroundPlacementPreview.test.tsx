// The Background card's placement preview (Leo, 2026-11-22: "we also want people to be able to
// reposition the images easily"): it shows for one picture that stays, a drag writes one placement
// on pointer up, Fill / Fit and Reset write at once, and a centered fill removes the picture's entry.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const writes = (page: Awaited<ReturnType<typeof renderPage>>, op: string) =>
  page.provider.log
    .filter((entry) => entry.op === op)
    .map((entry) => entry.params as { key?: string; value?: unknown })
    .filter((params) => params.key === "appearance.backgroundPlacement");

const preview = (page: Awaited<ReturnType<typeof renderPage>>) =>
  page.container.querySelector<HTMLElement>('[data-card="backdrop"] .placement-preview');

test("a picture shows the preview; a shuffle or No wallpaper does not", async () => {
  const shuffle = await renderPage({
    path: "/settings/appearance",
    mock: { values: { "appearance.background": "daily" } },
  });
  expect(preview(shuffle)).toBeNull();
  shuffle.unmount?.();
  const none = await renderPage({
    path: "/settings/appearance",
    mock: { values: { "appearance.background": "none" } },
  });
  expect(preview(none)).toBeNull();
  none.unmount?.();
  const page = await renderPage({
    path: "/settings/appearance",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  const shown = preview(page)!;
  expect(shown).not.toBeNull();
  expect(shown.querySelector("img")!.getAttribute("src")).toBe("backdrop/starryNight");
  // Unset is a centered fill: Fill is chosen and there is nothing to reset.
  expect(shown.querySelector<HTMLInputElement>('input[value="fill"]')!.checked).toBe(true);
  expect(shown.querySelector("button")).toBeNull();
  page.unmount?.();
});

test("Fit writes the picture's entry; Reset removes the key", async () => {
  const page = await renderPage({
    path: "/settings/appearance",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  await act(async () => preview(page)!.querySelector<HTMLInputElement>('input[value="fit"]')!.click());
  await settle();
  expect(writes(page, "cmux.settings.set").at(-1)).toMatchObject({ value: { starryNight: "fit" } });
  const reset = preview(page)!.querySelector<HTMLButtonElement>("button")!;
  expect(reset.textContent).toBe("Reset");
  await act(async () => reset.click());
  await settle();
  expect(writes(page, "cmux.settings.reset").length).toBe(1);
  page.unmount?.();
});

test("a drag writes once, on pointer up, keeping other pictures' entries", async () => {
  const page = await renderPage({
    path: "/settings/appearance",
    mock: {
      values: {
        "appearance.background": "starryNight",
        "appearance.backgroundPlacement": { other: "fit 0 0" },
      },
    },
  });
  const shown = preview(page)!;
  const frame = shown.querySelector<HTMLElement>(".placement-frame")!;
  // The picture loads: 2000 by 1000 points, wider than the 16:10 frame, so Fill has room sideways.
  const image = shown.querySelector("img")!;
  Object.defineProperty(image, "naturalWidth", { value: 2000 });
  Object.defineProperty(image, "naturalHeight", { value: 1000 });
  await act(async () => image.dispatchEvent(new window.Event("load")));
  const pointer = (type: string, x: number) =>
    frame.dispatchEvent(new window.MouseEvent(type, { bubbles: true, button: 0, clientX: x, clientY: 0 }));
  await act(async () => pointer("pointerdown", 100));
  await act(async () => pointer("pointermove", 200));
  await act(async () => pointer("pointermove", 300));
  // Nothing is written while the drag runs.
  expect(writes(page, "cmux.settings.set").length).toBe(0);
  await act(async () => pointer("pointerup", 300));
  await settle();
  // 200 points right, with 400 of room to the left: the picture's left edge.
  const set = writes(page, "cmux.settings.set");
  expect(set.length).toBe(1);
  expect(set[0]).toMatchObject({ value: { other: "fit 0 0", starryNight: "fill 0 0.5" } });
  // The arrow keys step it back.
  await act(async () => frame.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })));
  await settle();
  expect(writes(page, "cmux.settings.set").at(-1)).toMatchObject({ value: { starryNight: "fill 0.2 0.5" } });
  page.unmount?.();
});

test("Light & Dark previews and places the side the window shows now, as the app keys it", async () => {
  // The test page's window is light (no prefers-color-scheme: dark), so the light side is drawn.
  const page = await renderPage({
    path: "/settings/appearance",
    mock: {
      values: {
        "appearance.background": "appearance",
        "appearance.backgroundLight": "starryNight",
        "appearance.backgroundDark": "munch-scream",
      },
    },
  });
  const shown = preview(page)!;
  expect(shown).not.toBeNull();
  expect(shown.querySelector("img")!.getAttribute("src")).toBe("backdrop/starryNight");
  await act(async () => shown.querySelector<HTMLInputElement>('input[value="fit"]')!.click());
  await settle();
  // Keyed by the picture drawn, never by the mode.
  expect(writes(page, "cmux.settings.set").at(-1)).toMatchObject({ value: { starryNight: "fit" } });
  page.unmount?.();
});
