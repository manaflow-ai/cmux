// nxdog51: an unset number field showed its default label ("Ghostty config") cut to "Ghostty".
// The field sizes itself to the text it shows: a hidden copy of the placeholder (or the typed
// value) in the same grid cell sets its width, in every language, so no label is clipped.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, rowElement } = await import("./testing");

test("an unset number field is as wide as its default label, in the longest language too", async () => {
  for (const locale of ["en", "it", "ja"]) {
    const page = await renderPage({ path: "/settings/appearance", locale });
    const row = rowElement(page.container, "terminal.fontSize");
    const field = row.querySelector<HTMLInputElement>("input.number")!;
    const sizer = field.parentElement!;
    expect(sizer.classList.contains("number-sizer")).toBe(true);
    expect(field.placeholder.length > 0).toBe(true);
    expect(sizer.dataset.value).toBe(field.placeholder);
    page.unmount();
  }
});

test("a typed value sizes the field instead of the label", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  const field = rowElement(page.container, "terminal.fontSize").querySelector<HTMLInputElement>("input.number")!;
  await changeValue(field, "14");
  expect(field.parentElement!.dataset.value).toBe("14");
  page.unmount();
});
