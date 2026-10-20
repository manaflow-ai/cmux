// cmux-web-test-timeout: 240
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, fire, ops, renderPage, rowElement, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

// a249: over a background picture the window keeps its legibility floor, so values below it
// painted the same tint and the slider's low end moved nothing.
test("over a picture the Opacity slider starts at the legibility floor the host derives", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  const row = rowElement(page.container, "appearance.backgroundOpacity");
  const slider = () => row.querySelector<HTMLInputElement>('input[type="range"]')!;
  expect(slider().min).toBe("0");
  await run(() =>
    page!.provider.setHost({
      ...page!.provider.host,
      derived: { "appearance.backgroundOpacity": 0.7 },
      derived_min: { "appearance.backgroundOpacity": 0.62 },
    }),
  );
  // Snapped up to the slider's 5% step.
  expect(slider().min).toBe("0.65");
  await changeValue(slider(), "0.2");
  await fire(slider(), "pointerup");
  const previews = ops(page.provider, "cmux.settings.preview") as Array<{ value: number }>;
  expect(previews.map((params) => params.value)).toEqual([0.65]);
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "appearance.backgroundOpacity", value: 0.65 }]);
}, 60_000);

test("without a picture the Opacity slider keeps the schema's full range", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  const row = rowElement(page.container, "appearance.backgroundOpacity");
  const slider = row.querySelector<HTMLInputElement>('input[type="range"]')!;
  expect(slider.min).toBe("0");
  expect(slider.max).toBe("1");
}, 60_000);
