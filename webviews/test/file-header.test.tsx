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
import { createDiffViewerLabelResolver, loadDiffViewerLabels } from "../src/labels";
import { resolveFileIcon } from "../src/file-icons";
import { diffStatSpriteSheet, diffStatSymbolId } from "../src/file-tree-stats";
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
  const order = Array.from(doc.querySelector(".file-header")!.children).map((child) => child.classList[0]);
  expect(order.indexOf("file-header-caret")).toBe(order.indexOf("file-header-path") + 1);
});

function renderToggleHeader(collapsed: boolean, fileDiff: any = swiftDiff) {
  const calls = { toggles: 0, viewed: 0, loads: 0 };
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
        onLoadDiff={() => (calls.loads += 1)}
        onToggleCollapsed={() => (calls.toggles += 1)}
        onToggleViewed={() => (calls.viewed += 1)}
        viewedState="unviewed"
      />,
    ),
  );
  const doc = dom.window.document;
  const bar = doc.querySelector<HTMLElement>(".file-header")!;
  const click = (element: Element) =>
    element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
  const key = (element: Element, keyName: string) => {
    const event = new dom!.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: keyName });
    element.dispatchEvent(event);
    return event;
  };
  return { bar, calls, click, doc, key };
}

test("the whole header bar is one focusable toggle that reports the expanded state", () => {
  const expanded = renderToggleHeader(false);
  expect(expanded.bar.getAttribute("role")).toBe("button");
  expect(expanded.bar.tabIndex).toBe(0);
  expect(expanded.bar.getAttribute("aria-expanded")).toBe("true");
  expect(expanded.bar.getAttribute("aria-label")).toBe("Collapse SidebarBridge.swift");
  // The caret is the bar's visual state, not a second tab stop.
  const caret = expanded.doc.querySelector(".file-header-caret")!;
  expect(caret.tagName).not.toBe("BUTTON");
  expect(caret.getAttribute("aria-hidden")).toBe("true");
  expect(expanded.doc.querySelectorAll(".file-header [tabindex='0']").length).toBe(0);

  flushSync(() => root?.unmount());
  root = null;
  const collapsed = renderToggleHeader(true);
  expect(collapsed.bar.getAttribute("aria-expanded")).toBe("false");
  expect(collapsed.bar.getAttribute("aria-label")).toBe("Expand SidebarBridge.swift");
});

test("a click anywhere on the header bar toggles the file", () => {
  const { bar, calls, click, doc } = renderToggleHeader(false);
  click(bar);
  click(doc.querySelector(".file-header-name")!);
  click(doc.querySelector(".file-header-directory")!);
  click(doc.querySelector(".file-header-caret")!);
  click(doc.querySelector(".file-header-spacer")!);
  click(doc.querySelector(".file-header-additions")!);
  click(doc.querySelector(".cmux-file-icon")!);
  expect(calls.toggles).toBe(7);
});

test("controls inside the header bar keep their own action and do not toggle", () => {
  const { calls, click, doc } = renderToggleHeader(true, {
    ...swiftDiff,
    cmuxDeferredReason: "generated",
  });
  click(doc.querySelector(".file-review-viewed")!);
  click(doc.querySelector(".file-review-eye")!);
  click(doc.querySelector(".file-review-load")!);
  expect(calls).toEqual({ toggles: 0, viewed: 2, loads: 1 });

  // Any other control placed in the bar (an open or "..." menu button, a
  // link, an element marked as a control) is excluded the same way.
  const bar = doc.querySelector(".file-header")!;
  for (const markup of [
    "<button type='button'>Open</button>",
    "<a href='#x'>code</a>",
    "<span role='menuitem'>More</span>",
    "<span data-file-header-control>Generated file</span>",
  ]) {
    const holder = doc.createElement("span");
    holder.innerHTML = markup;
    bar.appendChild(holder);
    click(holder.firstElementChild!);
  }
  expect(calls.toggles).toBe(0);
});

test("a drag that selects text in the path does not toggle the file", () => {
  const { calls, doc } = renderToggleHeader(false);
  const name = doc.querySelector(".file-header-name")!;
  const mouse = (type: string, x: number) =>
    name.dispatchEvent(
      new dom!.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: 8 }),
    );
  // Press, drag across the name, release: a selection, not a toggle.
  mouse("mousedown", 10);
  mouse("mouseup", 70);
  mouse("click", 70);
  expect(calls.toggles).toBe(0);

  // A click that stays in place toggles, even with the old selection still there.
  mouse("mousedown", 30);
  mouse("mouseup", 31);
  mouse("click", 31);
  expect(calls.toggles).toBe(1);
});

test("Enter and Space on the focused bar toggle the file; keys on its controls do not", () => {
  const { bar, calls, doc, key } = renderToggleHeader(false);
  const enter = key(bar, "Enter");
  const space = key(bar, " ");
  expect(calls.toggles).toBe(2);
  expect(enter.defaultPrevented).toBe(true);
  // Space must not also scroll the viewer.
  expect(space.defaultPrevented).toBe(true);
  key(bar, "a");
  key(doc.querySelector(".file-review-viewed")!, "Enter");
  key(doc.querySelector(".file-review-viewed")!, " ");
  expect(calls.toggles).toBe(2);
});

test("the bar's ... menu opens without toggling and acts on the file", async () => {
  const { calls, click, doc } = renderToggleHeader(false);
  const button = doc.querySelector<HTMLElement>(".file-header-menu-button")!;
  expect(button.getAttribute("aria-label")).toBe("More actions for SidebarBridge.swift");
  expect(button.hasAttribute("data-file-header-control")).toBe(true);
  flushSync(() => click(button));
  expect(calls.toggles).toBe(0);
  // The popover places itself after the open render (useAnchoredPopover).
  await new Promise((resolve) => setTimeout(resolve, 0));
  const items = Array.from(doc.querySelectorAll<HTMLElement>(".file-header-menu [role='menuitem']"));
  expect(items.map((item) => item.textContent)).toEqual(["Mark as viewed"]);
  flushSync(() => click(items[0]!));
  expect(calls).toEqual({ toggles: 0, viewed: 1, loads: 0 });
  expect(doc.querySelector(".file-header-menu")).toBeNull();
});

test("the caret label is localized in Japanese", async () => {
  await loadDiffViewerLabels("ja");
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

test("tree rows show only the nonzero +N and -N counts, drawn in their own colors", () => {
  const measure = (text: string) => text.length * 7;
  const both = fileTreeRowDecoration({ added: 75, deleted: 10 }, label, measure);
  expect(both?.title).toBe("Additions 75, Deletions 10");
  expect(both?.icon.name).toBe(diffStatSymbolId({ added: 75, deleted: 10 }));
  expect(fileTreeRowDecoration({ added: 0, deleted: 1 }, label, measure)?.title).toBe("Deletions 1");
  expect(fileTreeRowDecoration(undefined, label, measure)).toBeNull();
  expect(fileTreeRowDecoration({ added: 0, deleted: 0 }, label, measure)).toBeNull();

  const sheet = diffStatSpriteSheet(
    [
      { added: 75, deleted: 10 },
      { added: 75, deleted: 10 },
      { added: 0, deleted: 1 },
    ],
    measure,
  );
  const doc = new JSDOM(`<!doctype html><body>${sheet}</body>`).window.document;
  const symbols = Array.from(doc.querySelectorAll("symbol"));
  expect(symbols.map((symbol) => symbol.id)).toEqual(["cmux-diff-stat-75-10", "cmux-diff-stat-0-1"]);
  const spans = Array.from(symbols[0]!.querySelectorAll("tspan")).map((span) => [
    span.textContent,
    span.getAttribute("style"),
  ]);
  expect(spans).toEqual([
    ["+75", "fill: var(--trees-status-added)"],
    ["-10", "fill: var(--trees-status-deleted)"],
  ]);
  expect(Array.from(symbols[1]!.querySelectorAll("tspan")).map((span) => span.textContent)).toEqual(["-1"]);
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
