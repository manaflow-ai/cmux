import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import type { ComputerUsePreview } from "./computerUsePreview";

const frame = "data:image/jpeg;base64,AA==";
const icon = "data:image/png;base64,AA==";
const running: ComputerUsePreview = { session: "cua_t1", app: "Calculator", done: false, frame };
const markup = (preview: ComputerUsePreview) =>
  renderToStaticMarkup(<ComputerUsePreviewCard preview={preview} onOpen={() => undefined} onClose={() => undefined} />);

test("a running card names the app with the live dot", () => {
  const html = markup(running);
  expect(html).toContain('<span class="acpmux-cu-preview__app">Calculator</span>');
  expect(html).toContain("acpmux-cu-preview__live");
  expect(html).not.toContain("acpmux-cu-preview__badge");
});

test("with no name the card has no title row and never says Unknown app", () => {
  const html = markup({ ...running, app: "" });
  expect(html).not.toContain("acpmux-cu-preview__title");
  expect(html).not.toContain("Unknown app");
  expect(html).toContain("data-untitled");
  expect(html).toContain('aria-label="Live app preview. Open in Agent Activity"');
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
