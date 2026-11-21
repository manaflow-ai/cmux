import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { FileReviewControls, FileTreeContextMenu, fileOpener, fileTreeRowPath } from "../src/App";
import type { DiffItem } from "../src/diff-stream";
import { createDiffViewerLabelResolver } from "../src/labels";

const label = createDiffViewerLabelResolver(undefined);
const modified = { id: "src/a.ts", type: "diff", fileDiff: { name: "src/a.ts", type: "change" } } as DiffItem;
const deleted = { id: "old.ts", type: "diff", fileDiff: { name: "old.ts", type: "deleted" } } as DiffItem;
const originalWindow = (globalThis as any).window;
const originalDocument = (globalThis as any).document;

let dom: JSDOM;
let root: Root | null = null;
let posted: unknown[] = [];

afterEach(async () => {
  flushSync(() => root?.unmount());
  root = null;
  // React flushes passive effects on a later tick, and they read `window`.
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom.window.close();
  (globalThis as any).window = originalWindow;
  (globalThis as any).document = originalDocument;
});

function setUpDom(): Document {
  dom = new JSDOM("<!doctype html><body><div id='root'></div></body>");
  posted = [];
  (dom.window as any).webkit = {
    messageHandlers: { cmuxDiffComments: { postMessage: async (message: unknown) => (posted.push(message), { ok: true, value: {} }) } },
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  return dom.window.document;
}

function render(element: React.ReactNode): Document {
  const doc = setUpDom();
  root = createRoot(doc.getElementById("root")!);
  flushSync(() => root!.render(element));
  return doc;
}

test("fileOpener asks the host to open the file, and has nothing to open for a deleted file", () => {
  setUpDom();
  expect(fileOpener("/repo", deleted)).toBeUndefined();
  fileOpener("/repo", modified)!();
  expect(posted).toHaveLength(1);
  expect(posted[0]).toMatchObject({ method: "file.open", params: { repoRoot: "/repo", path: "src/a.ts" } });
});

test("file header Open file opens the file without toggling the header", () => {
  let opened = 0;
  let headerClicks = 0;
  const doc = render(
    <FileReviewControls item={modified} label={label} onLoadDiff={() => {}} onOpenFile={() => opened++} onToggleViewed={() => {}} viewedState="unviewed" />,
  );
  doc.body.addEventListener("click", () => headerClicks++);
  doc.querySelector<HTMLButtonElement>('button[aria-label="Open file"]')!.click();
  expect([opened, headerClicks]).toEqual([1, 0]);
});

test("file header has no Open file when the file cannot be opened", () => {
  const doc = render(<FileReviewControls item={deleted} label={label} onLoadDiff={() => {}} onToggleViewed={() => {}} viewedState="unviewed" />);
  expect(doc.querySelector('button[aria-label="Open file"]')).toBeNull();
});

test("file tree menu Open file opens the file and closes the menu", () => {
  let opened = 0;
  let closed = 0;
  const doc = render(<FileTreeContextMenu close={() => closed++} label={label} onOpenFile={() => opened++} onToggleViewed={() => {}} viewed={false} />);
  const items = Array.from(doc.querySelectorAll<HTMLButtonElement>(".menu-item"));
  items.find((item) => item.textContent === "Open file")!.click();
  expect([opened, closed]).toEqual([1, 1]);
});

test("file tree menu has no Open file when the file cannot be opened", () => {
  const doc = render(<FileTreeContextMenu close={() => {}} label={label} onToggleViewed={() => {}} viewed={false} />);
  expect(Array.from(doc.querySelectorAll(".menu-item"), (item) => item.textContent)).toEqual(["Mark as viewed"]);
});

test("fileTreeRowPath finds the file row an event passed through, not a folder row", () => {
  const doc = setUpDom();
  const row = (type: string, path: string) => {
    const element = doc.createElement("button");
    element.dataset.itemType = type;
    element.dataset.itemPath = path;
    return [doc.createElement("span"), element, doc.body, doc, dom.window];
  };
  expect(fileTreeRowPath(row("file", "src/a.ts"))).toBe("src/a.ts");
  expect(fileTreeRowPath(row("folder", "src/"))).toBeUndefined();
});
