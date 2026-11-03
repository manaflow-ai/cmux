import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import type { ComputerUsePreview } from "./computerUsePreview";

const frame = "data:image/jpeg;base64,AA==";
const icon = "data:image/png;base64,AA==";
const running: ComputerUsePreview = { session: "cua_t1", app: "Calculator", done: false, frame };
const markup = (preview: ComputerUsePreview) =>
  renderToStaticMarkup(<ComputerUsePreviewCard preview={preview} onOpen={() => undefined} onClose={() => undefined} />);

test("a running card is only the frame, with no live dot and the app's name in its label", () => {
  const html = markup(running);
  // The window alone: no glass card around it.
  expect(html).toMatch(/^<div class="acpmux-cu-preview">/);
  expect(html).not.toContain("ui-glass");
  expect(html).not.toContain("acpmux-cu-preview__title");
  expect(html).not.toContain(">Calculator<");
  expect(html).toContain('aria-label="Calculator, live. Open in Agent Activity"');
  expect(html).toMatch(/class="acpmux-cu-preview__frame"><img [^>]*\/><\/span>/);
  expect(html).not.toContain("acpmux-cu-preview__live");
  expect(html).not.toContain("acpmux-cu-preview__badge");
});

test("the close button is there and labelled, with no glass", () => {
  const html = markup(running);
  expect(html).toContain('<button type="button" class="acpmux-cu-preview__close" aria-label="Hide Preview">');
});

test("with no name the label names no app and never says Unknown app", () => {
  const html = markup({ ...running, app: "" });
  expect(html).not.toContain("Unknown app");
  expect(html).toContain('aria-label="Live app preview. Open in Agent Activity"');
});

test("done keeps the app's name in its label and drops the live dot", () => {
  const html = markup({ ...running, done: true });
  expect(html).toContain('aria-label="Calculator, done. Open in Agent Activity"');
  expect(html).not.toContain("acpmux-cu-preview__live");
  expect(html).not.toContain(">Calculator<");
});

test("done shows the app's icon with the check on its corner", () => {
  const html = markup({ ...running, done: true, icon });
  expect(html).toMatch(
    /class="acpmux-cu-preview__mark" data-icon=""><img src="data:image\/png;base64,AA=="[^>]*\/><span class="acpmux-cu-preview__check">/,
  );
  expect(html).not.toContain("acpmux-cu-preview__live");
});

test("done with no icon shows the check alone", () => {
  const html = markup({ ...running, done: true });
  expect(html).toContain('<span class="acpmux-cu-preview__mark"><span class="acpmux-cu-preview__check">');
});

test("a running card draws the helper's cursor at the window's scale", () => {
  const html = markup({ ...running, pointer: { x: 0.25, y: 0.75, click: 4, windowWidth: 190 } });
  // 19 points of a 190-point window: 10% of the frame, at least 8px.
  expect(html).toContain(
    'class="acpmux-cu-preview__frame" style="--cu-pointer-x:0.25;--cu-pointer-y:0.75;--cu-pointer-width:max(8px, 10.000%)"',
  );
  expect(html).toContain("acpmux-cu-preview__ripple");
  expect(html).toContain('<stop offset="0" stop-color="#12c7f5"></stop>');
});

test("with no window width the cursor keeps a fixed size", () => {
  const html = markup({ ...running, pointer: { x: 0.5, y: 0.5, click: 1 } });
  expect(html).toContain("--cu-pointer-width:12px");
});

test("a card with no cursor draws none", () => {
  const html = markup(running);
  expect(html).not.toContain("acpmux-cu-preview__arrow");
  expect(html).toMatch(/class="acpmux-cu-preview__frame"><img /);
});
