import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { FileReviewControls, FileTreeContextMenu, fileTreeDoubleClickPath } from "../src/App";
import { openRepositoryFile } from "../src/comments/bridge";
import type { DiffItem } from "../src/diff-stream";
import { createDiffViewerLabelResolver } from "../src/labels";

const label = createDiffViewerLabelResolver(undefined);
const modified: DiffItem = { id: "src/a.ts", type: "diff", fileDiff: { name: "src/a.ts", type: "change" } } as DiffItem;
const deleted: DiffItem = { id: "old.ts", type: "diff", fileDiff: { name: "old.ts", type: "deleted" } } as DiffItem;

let root: Root | null = null;
let dom: JSDOM | null = null;
let posted: any[] = [];
const originalWindow = (globalThis as any).window;
const originalDocument = (globalThis as any).document;

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  (globalThis as any).window = originalWindow;
  (globalThis as any).document = originalDocument;
});

function render(element: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");
  posted = [];
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiffComments: {
        async postMessage(message: unknown) {
          posted.push(message);
          return { ok: true, value: {} };
        },
      },
    },
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  root = createRoot(dom.window.document.getElementById("root")!);
  flushSync(() => root?.render(element));
  return dom.window.document;
}

const openFile = (path: string) => void openRepositoryFile("/repo", path);

test("file header Open file posts the file path to the host without toggling the header", () => {
  let headerClicks = 0;
  const doc = render(
    <FileReviewControls item={modified} label={label} onLoadDiff={() => {}} onOpenFile={openFile} onToggleViewed={() => {}} viewedState="unviewed" />,
  );
  doc.body.addEventListener("click", () => headerClicks++);
  const button = doc.querySelector<HTMLButtonElement>('button[aria-label="Open file"]');
  expect(button).not.toBeNull();
  button!.click();
  expect(headerClicks).toBe(0);
  expect(posted).toHaveLength(1);
  expect(posted[0]).toMatchObject({ method: "file.open", params: { repoRoot: "/repo", path: "src/a.ts" } });
});

test("file header has no Open file for a deleted file or without the host", () => {
  const doc = render(
    <>
      <FileReviewControls item={deleted} label={label} onLoadDiff={() => {}} onOpenFile={openFile} onToggleViewed={() => {}} viewedState="unviewed" />
      <FileReviewControls item={modified} label={label} onLoadDiff={() => {}} onToggleViewed={() => {}} viewedState="unviewed" />
    </>,
  );
  expect(doc.querySelector('button[aria-label="Open file"]')).toBeNull();
});

test("file tree menu Open file posts the file path and closes the menu", () => {
  let closed = 0;
  const doc = render(
    <FileTreeContextMenu close={() => closed++} item={modified} label={label} onOpenFile={openFile} onToggleViewed={() => {}} viewed={false} />,
  );
  const item = Array.from(doc.querySelectorAll<HTMLButtonElement>(".menu-item")).find((button) => button.textContent === "Open file");
  expect(item).toBeDefined();
  item!.click();
  expect(closed).toBe(1);
  expect(posted[0]).toMatchObject({ method: "file.open", params: { repoRoot: "/repo", path: "src/a.ts" } });
});

test("file tree menu has no Open file for a deleted file", () => {
  const doc = render(
    <FileTreeContextMenu close={() => {}} item={deleted} label={label} onOpenFile={openFile} onToggleViewed={() => {}} viewed={false} />,
  );
  const labels = Array.from(doc.querySelectorAll(".menu-item")).map((button) => button.textContent);
  expect(labels).toEqual(["Mark as viewed"]);
});

test("double click opens a file tree row, not a folder, a deleted file or empty space", () => {
  const doc = new JSDOM("<!doctype html><body></body>").window.document;
  const row = (type: string, path: string) => {
    const button = doc.createElement("button");
    button.dataset.itemType = type;
    button.dataset.itemPath = path;
    const label = doc.createElement("span");
    button.append(label);
    return [label, button, doc.body];
  };
  const items = new Map([["src/a.ts", modified], ["old.ts", deleted]]);
  expect(fileTreeDoubleClickPath(row("file", "src/a.ts"), items)).toBe("src/a.ts");
  expect(fileTreeDoubleClickPath(row("folder", "src/"), items)).toBeNull();
  expect(fileTreeDoubleClickPath(row("file", "old.ts"), items)).toBeNull();
  expect(fileTreeDoubleClickPath([doc.body], items)).toBeNull();
});
