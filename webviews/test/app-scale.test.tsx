import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { closeFileSearch, FilesSidebarBackdrop, shouldDismissFileSearch } from "../src/App";
import { JumpToFilePalette } from "../src/DiffToolbar";
import { JUMP_ROW_CAP, jumpToFileRows } from "../src/toolbar-model";
import type { DiffItem } from "../src/diff-stream";
import { createDiffViewerLabelResolver } from "../src/labels";

test("large diff jump-to-file rows stay bounded", () => {
  const items = Array.from({ length: 10_000 }, (_, index) => ({
    id: `src/file-${index}.ts`,
    type: "diff",
    fileDiff: { name: `src/file-${index}.ts`, hunks: [] },
    version: 0,
  })) as DiffItem[];
  const { rows, hidden } = jumpToFileRows(items, "", "Untitled");
  expect(rows).toHaveLength(JUMP_ROW_CAP);
  expect(hidden).toBe(10_000 - JUMP_ROW_CAP);
  const markup = renderToStaticMarkup(
    <JumpToFilePalette items={items} label={createDiffViewerLabelResolver(undefined)} onJump={() => {}} />,
  );
  const dom = new JSDOM(markup);
  // Closed, the palette is one button; rows exist only while it is open.
  expect(dom.window.document.querySelectorAll("*").length).toBeLessThan(10);
  expect(dom.window.document.querySelector('[aria-label="Jump to file"]')?.tagName).toBe("BUTTON");
  dom.window.close();
});

test("mobile file drawer backdrop is an accessible close control", () => {
  const label = createDiffViewerLabelResolver(undefined);
  const markup = renderToStaticMarkup(<FilesSidebarBackdrop label={label} onClose={() => {}} open={true} />);
  const dom = new JSDOM(markup);
  const backdrop = dom.window.document.getElementById("files-sidebar-backdrop");
  expect(backdrop?.tagName).toBe("BUTTON");
  expect(backdrop?.getAttribute("aria-controls")).toBe("files-sidebar");
  expect(backdrop?.getAttribute("aria-label")).toBe("Hide file search");
  dom.window.close();

  let closed = false;
  const control = FilesSidebarBackdrop({
    label,
    onClose: () => {
      closed = true;
    },
    open: true,
  }) as any;
  control.props.onClick();
  expect(closed).toBe(true);
  expect(FilesSidebarBackdrop({ label, onClose: () => {}, open: false })).toBeNull();
});

test("mobile file drawer dismisses Escape without changing wide search behavior", () => {
  expect(shouldDismissFileSearch("Escape", true)).toBe(true);
  expect(shouldDismissFileSearch("Escape", false)).toBe(false);
  expect(shouldDismissFileSearch("Enter", true)).toBe(false);

  const dom = new JSDOM('<button id="jump-search-button">Jump</button>');
  const actions: any[] = [];
  closeFileSearch((action) => actions.push(action), dom.window.document);
  expect(actions).toEqual([{ type: "set-file-search-open", open: false }]);
  expect(dom.window.document.activeElement?.id).toBe("jump-search-button");
  dom.window.close();
});
