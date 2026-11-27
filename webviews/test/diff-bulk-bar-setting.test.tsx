// Settings > Diff Viewer > Stage All and Revert All Bar (`diff.showBulkActions`): off, the floating
// bar leaves out Stage all and Revert all, and still shows Undo and a failure notice after a revert.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { DiffBulkBar } from "../src/diff-viewer/RevertControls";
import { createDiffViewerLabelResolver } from "../src/labels";

const label = createDiffViewerLabelResolver(undefined, { language: "en" });
const noop = () => {};
const revert = (extra: Record<string, unknown> = {}) =>
  ({ busy: false, stageAll: noop, revertAll: noop, ...extra }) as unknown as Parameters<
    typeof DiffBulkBar
  >[0]["revert"];
const bar = (props: Partial<Parameters<typeof DiffBulkBar>[0]>) =>
  renderToStaticMarkup(<DiffBulkBar revert={revert()} label={label} {...props} />);

test("on (the default), the bar offers Stage all and Revert all", () => {
  const html = bar({});
  expect(html).toContain("Stage all");
  expect(html).toContain("Revert all");
});

test("off, there is no bar while there is nothing else to show", () => {
  expect(bar({ showActions: false })).toBe("");
});

test("off, Undo and a failure notice still show", () => {
  const undo = bar({ showActions: false, revert: revert({ undo: noop }) });
  expect(undo).toContain("Undo");
  expect(undo).not.toContain("Stage all");
  expect(undo).not.toContain("Revert all");
  expect(bar({ showActions: false, revert: revert({ notice: "Revert failed" }) })).toContain("Revert failed");
});
