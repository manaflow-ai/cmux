import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { JumpSelect } from "../src/App";
import type { DiffItem } from "../src/diff-stream";
import { createDiffViewerLabelResolver } from "../src/labels";

test("large diff navigation keeps the rendered DOM bounded", () => {
  const items = Array.from({ length: 10_000 }, (_, index) => ({
    id: `src/file-${index}.ts`,
    type: "diff",
    fileDiff: { name: `src/file-${index}.ts`, hunks: [] },
    version: 0,
  })) as DiffItem[];
  const markup = renderToStaticMarkup(
    <JumpSelect
      items={items}
      label={createDiffViewerLabelResolver(undefined)}
      onJump={() => {}}
      selectedItemId=""
    />,
  );
  const dom = new JSDOM(markup);
  expect(dom.window.document.querySelectorAll("option")).toHaveLength(0);
  expect(dom.window.document.querySelector('[aria-label="Jump to file"]')).toBeTruthy();
  expect(dom.window.document.querySelectorAll("*").length).toBeLessThan(10);
  dom.window.close();
});
