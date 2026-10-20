// Comments in the Markdown viewer (viewer-comments-DESIGN.md "Comments in the viewer"): a comment
// the user left shows as a margin marker at the block of its first line, the marker opens a card
// with the quote and the comment, Delete asks the host to forget it, and a reload keeps the markers.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";
import { parseComments, topIndexForLine } from "../src/pages/markdown/comments";

let dom: JSDOM;
let MarkdownEditor: typeof Editor;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Node",
    "Element",
    "getComputedStyle",
    "MutationObserver",
    "DOMParser",
    "Text",
    "requestAnimationFrame",
    "KeyboardEvent",
    "MouseEvent",
    "Event",
  ])
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const rects = () => Object.assign([box()], { item: () => box() });
  for (const prototype of [dom.window.Range.prototype, dom.window.Element.prototype] as unknown as Array<
    Record<string, unknown>
  >) {
    prototype.getClientRects = rects;
    prototype.getBoundingClientRect = box;
  }
  (dom.window.document as unknown as { elementFromPoint: () => null }).elementFromPoint = () => null;
  ({ MarkdownEditor } = await import("../src/pages/markdown/editor"));
});

const editors: Editor[] = [];
afterEach(async () => {
  for (const editor of editors.splice(0)) await editor.destroy();
  document.body.innerHTML = "";
});

const DOC = "# Guide\n\nFirst paragraph.\n\n- one\n- two\n\nLast paragraph.\n";
//           1        2 3                4 5     6     7 8

async function setup(deleted: string[] = []) {
  const root = document.createElement("div");
  document.body.append(root);
  const editor = new MarkdownEditor({
    root,
    host: {
      openLink: () => {},
      imageURL: (src) => src,
      label: (key) => key,
      deleteComment: (id) => deleted.push(id),
    },
  });
  editors.push(editor);
  await editor.create();
  editor.load(DOC);
  return { root, editor };
}

const COMMENTS = {
  v: 1,
  comments: [
    { id: "c1", startLine: 6, endLine: 6, quoted: "two", comment: "Why two?" },
    { id: "c2", startLine: 3, endLine: 3, quoted: "First paragraph.", comment: "Reword this" },
  ],
};

describe("comment markers", () => {
  test("each comment marks the block of its first line", async () => {
    const { root, editor } = await setup();
    editor.setComments(parseComments(COMMENTS));
    const markers = [...root.querySelectorAll<HTMLElement>(".cmux-comment-marker")];
    expect(markers.map((marker) => marker.dataset.commentId)).toEqual(["c2", "c1"]);
    // A marker sits just before the block it marks, in the margin.
    expect(markers[0]!.nextElementSibling?.textContent).toContain("First paragraph");
    expect(markers[1]!.nextElementSibling?.tagName).toBe("UL");
  });

  test("a marker opens its card with the quote and the comment, Delete asks the host", async () => {
    const deleted: string[] = [];
    const { root, editor } = await setup(deleted);
    editor.setComments(parseComments(COMMENTS));
    const marker = root.querySelector<HTMLElement>('.cmux-comment-marker[data-comment-id="c2"]')!;
    expect(root.querySelector(".cmux-comment-card")).toBeNull();
    marker.querySelector("button")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    const card = root.querySelector<HTMLElement>(".cmux-comment-card")!;
    expect(card.textContent).toContain("First paragraph.");
    expect(card.textContent).toContain("Reword this");
    card.querySelector<HTMLElement>(".cmux-comment-delete")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    expect(deleted).toEqual(["c2"]);
  });

  test("loading the file again keeps the markers, and an empty list clears them", async () => {
    const { root, editor } = await setup();
    editor.setComments(parseComments(COMMENTS));
    editor.load(DOC.replace("Last paragraph.", "Last paragraph, edited."));
    expect(root.querySelectorAll(".cmux-comment-marker").length).toBe(2);
    editor.setComments([]);
    expect(root.querySelectorAll(".cmux-comment-marker").length).toBe(0);
  });
});

describe("parseComments and topIndexForLine", () => {
  test("malformed comments are skipped", () => {
    expect(parseComments({ v: 1, comments: [{ id: "a" }, ...COMMENTS.comments] }).map((c) => c.id)).toEqual([
      "c1",
      "c2",
    ]);
    expect(parseComments({ v: 2, comments: COMMENTS.comments })).toEqual([]);
    expect(parseComments(null)).toEqual([]);
  });

  test("a line maps to the block that holds it, a gap line to the block before", () => {
    const at = (text: string): { start: number; end: number; nodes: unknown[] } => ({
      start: DOC.indexOf(text),
      end: DOC.indexOf(text) + text.length,
      nodes: [0],
    });
    const map = {
      text: DOC,
      blocks: [at("# Guide"), at("First paragraph."), at("- one\n- two"), at("Last paragraph.")],
    };
    expect(topIndexForLine(map, 1)).toBe(0);
    expect(topIndexForLine(map, 6)).toBe(2);
    expect(topIndexForLine(map, 7)).toBe(2);
    expect(topIndexForLine(map, 8)).toBe(3);
    expect(topIndexForLine(map, 0)).toBeNull();
  });
});
