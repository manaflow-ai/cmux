// nxdog51: an unset number field showed its default label ("Ghostty config") cut to "Ghostty".
// The field sizes itself to the longer of its label and its value: a hidden copy in the same grid
// cell sets its width, in every language, so no label is clipped and typing never shrinks it.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, rowElement } = await import("./testing");

test("an unset number field is as wide as its default label, in the longest language too", async () => {
  for (const locale of ["en", "it", "ja"]) {
    const page = await renderPage({ path: "/settings/terminal", locale });
    const row = rowElement(page.container, "terminal.fontSize");
    const field = row.querySelector<HTMLInputElement>("input.number")!;
    const sizer = field.parentElement!;
    expect(sizer.classList.contains("number-sizer")).toBe(true);
    expect(field.placeholder.length > 0).toBe(true);
    expect(sizer.dataset.value).toBe(field.placeholder);
    page.unmount();
  }
});

// Standup 2026-11-11: nothing moves on interaction. Typing over the label kept the field at the
// typed value's width, so the field shrank and the slider beside it slid right.
test("a typed value keeps the label's width, so the slider beside it stays put", async () => {
  const page = await renderPage({ path: "/settings/terminal" });
  const field = rowElement(page.container, "terminal.fontSize").querySelector<HTMLInputElement>("input.number")!;
  const label = field.placeholder;
  await changeValue(field, "14");
  expect(field.parentElement!.dataset.value).toBe(label);
  page.unmount();
});
