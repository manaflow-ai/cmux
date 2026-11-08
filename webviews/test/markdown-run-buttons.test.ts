// Run buttons in the Markdown viewer (runButtons.ts): a shell block gets Run in its language row,
// a click sends its command (session prompts stripped), a destructive command asks first, and a
// block of another language gets none.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";

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

const DOC =
  "# Deploy\n\n```bash\nnpm ci\n```\n\n```console\n$ make\nok\n```\n\n```sh\nrm -rf dist\n```\n\n```json\n{}\n```\n";

async function setup() {
  const sent: string[] = [];
  const root = document.createElement("div");
  document.body.append(root);
  const editor = new MarkdownEditor({
    root,
    host: {
      openLink: () => {},
      imageURL: (src) => src,
      label: (key) => key,
      run: { runBlock: (command) => sent.push(command), label: (key) => key },
    },
  });
  editors.push(editor);
  await editor.create();
  editor.load(DOC);
  return { root, sent };
}

const click = (element: Element | null | undefined) =>
  element!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));

describe("Run buttons", () => {
  test("shell blocks get Run; other languages none", async () => {
    const { root } = await setup();
    const blocks = [...root.querySelectorAll(".md-code")];
    expect(blocks.map((block) => !!block.querySelector(".md-run-button"))).toEqual([true, true, true, false]);
  });

  test("Run sends the block's command; a console block sends its prompt lines", async () => {
    const { root, sent } = await setup();
    const blocks = root.querySelectorAll(".md-code");
    click(blocks[0]!.querySelector(".md-run-button"));
    click(blocks[1]!.querySelector(".md-run-button"));
    expect(sent).toEqual(["npm ci", "make"]);
    expect(blocks[0]!.querySelector(".md-run")!.getAttribute("data-state")).toBe("sent");
  });

  test("a destructive command asks first; Cancel sends nothing, Run sends it", async () => {
    const { root, sent } = await setup();
    const block = root.querySelectorAll(".md-code")[2]!;
    click(block.querySelector(".md-run-button"));
    expect(sent).toEqual([]);
    expect(block.querySelector(".md-run")!.getAttribute("data-state")).toBe("ask");
    expect(block.querySelector(".md-run-ask")!.textContent).toBe("runAsk");
    click([...block.querySelectorAll(".md-run-button")].at(-1));
    expect(sent).toEqual([]);
    expect(block.querySelector(".md-run")!.hasAttribute("data-state")).toBe(false);
    click(block.querySelector(".md-run-button"));
    click(block.querySelector(".md-run-confirm"));
    expect(sent).toEqual(["rm -rf dist"]);
  });
});
