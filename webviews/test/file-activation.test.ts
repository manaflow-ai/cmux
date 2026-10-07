import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { treeFileActivation, treeFileRowPath } from "../src/file-activation";

test("a tree file click expands a collapsed file, collapses one in place, and otherwise scrolls", () => {
  expect(treeFileActivation(true, false)).toBe("expand");
  expect(treeFileActivation(true, true)).toBe("expand");
  expect(treeFileActivation(false, true)).toBe("collapse");
  expect(treeFileActivation(false, false)).toBe("scroll");
});

test("only a plain click on a file row activates; folders, sticky rows and modified clicks do not", () => {
  const dom = new JSDOM(`
    <button data-type="item" data-item-type="file" data-item-path="src/a.ts"><span id="file-label">a.ts</span></button>
    <button data-type="item" data-item-type="folder" data-item-path="src/"><span id="folder-label">src</span></button>
    <button data-type="item" data-item-type="file" data-item-path="src/b.ts" data-file-tree-sticky-row="true"><span id="sticky-label">b</span></button>
  `);
  const doc = dom.window.document;
  const pathOf = (id: string) => {
    const path: EventTarget[] = [];
    for (let node: Element | null = doc.getElementById(id); node != null; node = node.parentElement) {
      path.push(node);
    }
    return () => path;
  };
  expect(treeFileRowPath({ button: 0, composedPath: pathOf("file-label") })).toBe("src/a.ts");
  expect(treeFileRowPath({ button: 0, composedPath: pathOf("folder-label") })).toBeNull();
  expect(treeFileRowPath({ button: 0, composedPath: pathOf("sticky-label") })).toBeNull();
  expect(treeFileRowPath({ button: 0, shiftKey: true, composedPath: pathOf("file-label") })).toBeNull();
  expect(treeFileRowPath({ button: 0, metaKey: true, composedPath: pathOf("file-label") })).toBeNull();
  expect(treeFileRowPath({ button: 2, composedPath: pathOf("file-label") })).toBeNull();
  dom.window.close();
});
