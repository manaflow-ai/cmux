import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { FileHeader, fileTreeRowDecoration } from "../src/App";
import {
  collapsedFileKey,
  MAX_COLLAPSED_FILES,
  sanitizeCollapsedFiles,
  withCollapsedFile,
} from "../src/collapsed-files";
import { createDiffViewerLabelResolver } from "../src/labels";
import { resolveFileIcon } from "../src/file-icons";
import { sanitizeViewerPrefs } from "../src/viewer-prefs";

const label = createDiffViewerLabelResolver(undefined, { language: "en" });
let root: Root | null = null;
let dom: JSDOM | null = null;
const globalKeys = ["window", "document", "Element", "Node", "HTMLElement"] as const;
const originals = new Map<string, unknown>(globalKeys.map((key) => [key, (globalThis as any)[key]]));

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  // Let React's scheduled passive work run while the DOM globals still exist.
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

function renderHeader(collapsed: boolean, onToggleCollapsed: () => void, fileDiff: any): Document {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");
  for (const key of globalKeys) {
    (globalThis as any)[key] = key === "window" ? dom.window : (dom.window as any)[key];
  }
  (globalThis as any).document = dom.window.document;
  root = createRoot(dom.window.document.getElementById("root")!);
  flushSync(() =>
    root?.render(
      <FileHeader
        item={{ id: "a", type: "diff", collapsed, fileDiff } as any}
        label={label}
        onLoadDiff={() => {}}
        onToggleCollapsed={onToggleCollapsed}
        onToggleViewed={() => {}}
        viewedState="unviewed"
      />,
    ),
  );
  return dom.window.document;
}

const swiftDiff = {
  name: "Packages/macOS/CmuxNext/Sources/SidebarBridge.swift",
  type: "change",
  hunks: [{ additionLines: 17, deletionLines: 8 }],
};

test("a file header shows the dim directory, the bright name, the counts and a caret after the name", () => {
  const doc = renderHeader(false, () => {}, swiftDiff);

  expect(doc.querySelector(".file-header-directory")?.textContent).toBe("Packages/macOS/CmuxNext/Sources/");
  expect(doc.querySelector(".file-header-name")?.textContent).toBe("SidebarBridge.swift");
  expect(doc.querySelector(".file-header-additions")?.textContent).toBe("+17");
  expect(doc.querySelector(".file-header-deletions")?.textContent).toBe("-8");
  expect(doc.querySelector(".cmux-file-icon")?.getAttribute("data-icon-token")).toBe("swift");
  const order = Array.from(doc.querySelector(".file-header")!.children).map((child) => child.className);
  expect(order.indexOf("file-header-caret")).toBe(order.indexOf("file-header-path") + 1);
});

test("the caret is a labelled button that reports and toggles the collapsed state", () => {
  let toggles = 0;
  const expanded = renderHeader(false, () => (toggles += 1), swiftDiff);
  const caret = expanded.querySelector<HTMLButtonElement>(".file-header-caret")!;

  expect(caret.tagName).toBe("BUTTON");
  expect(caret.getAttribute("aria-expanded")).toBe("true");
  expect(caret.getAttribute("aria-label")).toBe("Collapse SidebarBridge.swift");
  caret.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  expect(toggles).toBe(1);

  flushSync(() => root?.unmount());
  root = null;
  const collapsed = renderHeader(true, () => {}, swiftDiff);
  const collapsedCaret = collapsed.querySelector(".file-header-caret")!;
  expect(collapsedCaret.getAttribute("aria-expanded")).toBe("false");
  expect(collapsedCaret.getAttribute("aria-label")).toBe("Expand SidebarBridge.swift");
});

test("the caret label is localized in Japanese", () => {
  const ja = createDiffViewerLabelResolver(undefined, { language: "ja" });
  expect(ja("collapseFile").replace("{file}", "a.ts")).toBe("a.ts を折りたたむ");
  expect(ja("expandFile").replace("{file}", "a.ts")).toBe("a.ts を展開");
});

test("a top-level file has no directory part", () => {
  const doc = renderHeader(false, () => {}, { name: "CLAUDE.md", type: "change", hunks: [] });

  expect(doc.querySelector(".file-header-directory")).toBeNull();
  expect(doc.querySelector(".file-header-name")?.textContent).toBe("CLAUDE.md");
  expect(doc.querySelector(".file-header-additions")?.textContent).toBe("+0");
});

test("header icons resolve through the same @pierre/trees icon set as the files tree", () => {
  expect(resolveFileIcon("a/b/main.swift")).toMatchObject({ token: "swift", hue: "orange" });
  expect(resolveFileIcon("README.md").token).toBe("markdown");
  expect(resolveFileIcon("bin/tool").symbol).toBeTruthy();
});

test("tree rows show the viewed mark and only the nonzero +N and -N counts", () => {
  expect(fileTreeRowDecoration({ added: 75, deleted: 10 }, "unviewed", label)?.text).toBe("+75 -10");
  expect(fileTreeRowDecoration({ added: 0, deleted: 1 }, undefined, label)?.text).toBe("-1");
  expect(fileTreeRowDecoration({ added: 18, deleted: 0 }, "viewed", label)).toEqual({
    text: "✓ +18",
    title: "Viewed, Additions 18",
  });
  expect(fileTreeRowDecoration(undefined, undefined, label)).toBeNull();
});

test("collapsed files are keyed by repository, ordered, deduplicated and capped", () => {
  const a = collapsedFileKey("/repo", "a.ts");
  const b = collapsedFileKey("/repo", "b.ts");
  expect(collapsedFileKey("/other", "a.ts")).not.toBe(a);

  expect(withCollapsedFile([a], b, true)).toEqual([a, b]);
  expect(withCollapsedFile([a, b], a, true)).toEqual([b, a]);
  expect(withCollapsedFile([a, b], a, false)).toEqual([b]);

  const many = Array.from({ length: MAX_COLLAPSED_FILES + 5 }, (_, index) => collapsedFileKey("/r", `${index}`));
  const capped = withCollapsedFile(many, collapsedFileKey("/r", "new"), true);
  expect(capped.length).toBe(MAX_COLLAPSED_FILES);
  expect(capped.at(-1)).toBe(collapsedFileKey("/r", "new"));

  expect(sanitizeCollapsedFiles([a, a, 3, "no-separator"])).toEqual([a]);
  expect(sanitizeCollapsedFiles("nope")).toBeUndefined();
});

test("collapsed files persist with the other viewer prefs", () => {
  const key = collapsedFileKey("/repo", "a.ts");
  expect(sanitizeViewerPrefs({ wordWrap: true, collapsedFiles: [key, 7] })).toEqual({
    wordWrap: true,
    collapsedFiles: [key],
  });
  expect(sanitizeViewerPrefs({ collapsedFiles: {} })).toEqual({});
});
