import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import {
  closeFileSearch,
  FilesSidebarBackdrop,
  JumpSelect,
  shouldDismissFileSearch,
} from "../src/App";
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
      onOpenSearch={() => {}}
      searchOpen={false}
      selectedItemId=""
    />,
  );
  const dom = new JSDOM(markup);
  expect(dom.window.document.querySelectorAll("option")).toHaveLength(0);
  const searchButton = dom.window.document.querySelector('[aria-label="Jump to file"]');
  expect(searchButton?.tagName).toBe("BUTTON");
  expect(searchButton?.getAttribute("aria-controls")).toBe("files-sidebar");
  expect(searchButton?.getAttribute("aria-expanded")).toBe("false");
  expect(dom.window.document.querySelectorAll("*").length).toBeLessThan(10);
  dom.window.close();

  let openedSearch = false;
  const control = JumpSelect({
    items,
    label: createDiffViewerLabelResolver(undefined),
    onJump: () => {},
    onOpenSearch: () => {
      openedSearch = true;
    },
    searchOpen: false,
    selectedItemId: "",
  }) as any;
  control.props.onClick();
  expect(openedSearch).toBe(true);
});

test("mobile file drawer backdrop is an accessible close control", () => {
  const label = createDiffViewerLabelResolver(undefined);
  const markup = renderToStaticMarkup(
    <FilesSidebarBackdrop label={label} onClose={() => {}} open={true} />,
  );
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
