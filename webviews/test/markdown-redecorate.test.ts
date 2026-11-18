// The decoration plugins (GitHub references, task checkboxes, code colors, broken links, Obsidian
// syntax) redraw only the top-level blocks a change touched (redecorate.ts). Found by
// bench/markdown-viewer-stress.bench.ts: a reload of a 1 MB file appended to took 250 ms, most of
// it drawing every block's decorations again. Leo, 2026-11-17: "we should be stress testing
// everything that isn't already stress tested".
import { afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EditorState } from "@milkdown/kit/prose/state";
import type { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";

setDefaultTimeout(60_000);
let MarkdownEditor: typeof Editor;

beforeAll(async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
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
  scope.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
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

async function editor(): Promise<Editor> {
  const root = document.createElement("div");
  document.body.append(root);
  const next = new MarkdownEditor({
    root,
    host: {
      openLink: () => {},
      imageURL: (src) => src,
      label: (key) => key,
      githubRepository: "owner/repo",
      // Every word of a code block is a token.
      highlight: (code) =>
        [...code.matchAll(/\w+/g)].map((m) => ({ from: m.index!, to: m.index! + m[0].length, style: "color: red" })),
      links: {
        resolved: (path) => ({ exists: !path.includes("missing") }),
        requestLinks: () => {},
        linkLabel: (key) => key,
      },
    },
  });
  editors.push(next);
  await next.create();
  return next;
}

/** `count` parts with a reference, a task, a code block, a link, a broken link and Obsidian syntax. */
function parts(count: number, from = 0): string {
  const out: string[] = [];
  for (let i = from; i < from + count; i++)
    out.push(
      `## Part ${i}\n\nSee #${i + 1} and ==mark ${i}== with #tag${i}.\n\n- [ ] task ${i}\n- [x] done ${i}\n\n` +
        `[ok](notes/${i}.md) and [gone](missing/${i}.md) and [anchor](#part-${i})\n\n\`\`\`ts\nlet x${i} = ${i};\n\`\`\`\n\n`,
    );
  return out.join("");
}

/** Every plugin's decorations in `state` (but the active block, which is the selection's), as plain lines, sorted. */
function drawn(state: EditorState): string[] {
  const out: string[] = [];
  for (const plugin of state.plugins) {
    const set = plugin.props.decorations?.call(plugin, state) as DecorationSet | undefined;
    if (!set?.find) continue;
    const name = plugin.spec.key ? String((plugin.spec.key as unknown as { key: string }).key) : "";
    if (name.startsWith("cmuxMarkdownActive")) continue;
    for (const decoration of set.find()) out.push(describe(name, decoration));
  }
  return out.sort();
}

function describe(plugin: string, decoration: Decoration): string {
  const { from, to } = decoration;
  const type = (decoration as unknown as { type: { attrs?: unknown; spec?: { key?: string } } }).type;
  return `${plugin} ${from}-${to} ${JSON.stringify(type.attrs ?? type.spec?.key ?? "")}`;
}

/** The plugins' decorations by their types: `find` copies a decoration to its position, but the
 * type (its spec and attributes) is shared until the decoration is drawn again. */
function objects(state: EditorState): Set<unknown> {
  const out = new Set<unknown>();
  for (const plugin of state.plugins) {
    const set = plugin.props.decorations?.call(plugin, state) as DecorationSet | undefined;
    if (set?.find) for (const decoration of set.find()) out.add((decoration as unknown as { type: unknown }).type);
  }
  return out;
}

test("an append reload draws only the new blocks, and ends as a whole draw", async () => {
  const text = parts(40);
  const reloaded = await editor();
  reloaded.load(text);
  const view = reloaded.editorView()!;
  const before = objects(view.state);
  expect(before.size).toBeGreaterThan(40 * 8);
  const appended = `${text}${parts(1, 40)}`;
  reloaded.load(appended);
  const after = objects(view.state);
  // Every decoration of the blocks before the append is the same object: they were not drawn again.
  let kept = 0;
  for (const decoration of before) if (after.has(decoration)) kept++;
  expect(kept).toBeGreaterThan(before.size * 0.9);
  // And the decorations are the ones a whole draw gives.
  const whole = await editor();
  whole.load(appended);
  expect(drawn(view.state)).toEqual(drawn(whole.editorView()!.state));
});

test("an edit in the middle redraws its block; the others keep theirs", async () => {
  const text = parts(40);
  const edited = await editor();
  edited.load(text);
  const view = edited.editorView()!;
  const before = objects(view.state);
  const at = text.indexOf("See #21");
  const changed = `${text.slice(0, at)}See #99 and ==new== with ${text.slice(at + "See #21 and ==mark 20== with ".length)}`;
  edited.load(changed);
  let kept = 0;
  for (const decoration of before) if (objects(view.state).has(decoration)) kept++;
  expect(kept).toBeGreaterThan(before.size * 0.9);
  const whole = await editor();
  whole.load(changed);
  expect(drawn(view.state)).toEqual(drawn(whole.editorView()!.state));
});

test("a heading renamed redraws every anchor link", async () => {
  const text = parts(10);
  const edited = await editor();
  edited.load(text);
  const renamed = text.replace("## Part 7\n", "## Chapter 7\n");
  edited.load(renamed);
  const whole = await editor();
  whole.load(renamed);
  const lines = drawn(edited.editorView()!.state);
  expect(lines).toEqual(drawn(whole.editorView()!.state));
  // The anchor to the renamed heading is broken now.
  expect(lines.filter((line) => line.includes("md-link-broken")).length).toBe(11);
});

test("moving the caret redraws the syntax around it, not the whole document", async () => {
  const text = parts(40);
  const moved = await editor();
  moved.load(text);
  const view = moved.editorView()!;
  const before = objects(view.state);
  const { TextSelection } = await import("@milkdown/kit/prose/state");
  const mark = view.state.doc.textBetween(0, view.state.doc.content.size, "\n").indexOf("==mark 30==");
  let pos = 0;
  view.state.doc.descendants((node, at) => {
    if (pos || !node.isText || !node.text!.includes("==mark 30==")) return !pos;
    pos = at + node.text!.indexOf("==mark 30==") + 3;
    return false;
  });
  expect(mark).toBeGreaterThan(0);
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  let kept = 0;
  for (const decoration of before) if (objects(view.state).has(decoration)) kept++;
  expect(kept).toBeGreaterThan(before.size * 0.9);
  // The highlight under the caret shows its markers.
  const whole = await editor();
  whole.load(text);
  const wholeView = whole.editorView()!;
  wholeView.dispatch(wholeView.state.tr.setSelection(TextSelection.create(wholeView.state.doc, pos)));
  expect(drawn(view.state)).toEqual(drawn(wholeView.state));
});

test("a whole draw joined from chunks is the set one create gives", async () => {
  const { Schema } = await import("@milkdown/kit/prose/model");
  const { Decoration, DecorationSet } = await import("@milkdown/kit/prose/view");
  const { decorateAll } = await import("../src/pages/markdown/redecorate");
  const schema = new Schema({
    nodes: {
      doc: { content: "block+" },
      paragraph: { group: "block", content: "text*" },
      quote: { group: "block", content: "block+" },
      text: {},
    },
  });
  // 500 blocks (8 chunks), every third a quote around a paragraph.
  const blocks = Array.from({ length: 500 }, (_, i) => {
    const paragraph = schema.nodes.paragraph.create(null, schema.text(`block ${i}`));
    return i % 3 ? paragraph : schema.nodes.quote.create(null, paragraph);
  });
  const doc = schema.nodes.doc.create(null, blocks);
  // A node decoration on each top-level block, an inline one in its text and a widget at its start.
  const draw = (from: number, to: number) => {
    const out: Decoration[] = [];
    doc.forEach((node, pos) => {
      if (pos < from || pos >= to) return;
      out.push(Decoration.node(pos, pos + node.nodeSize, { class: "block" }));
      const text = pos + (node.type.name === "quote" ? 2 : 1);
      out.push(Decoration.inline(text, text + 5, { class: "word" }));
      out.push(Decoration.widget(pos, () => document.createElement("span"), { key: `w${pos}` }));
    });
    return out;
  };
  const joined = decorateAll(doc, draw);
  const whole = DecorationSet.create(doc, draw(0, doc.content.size));
  const lines = (set: DecorationSet) =>
    set
      .find()
      .map(
        (d) => `${d.from}-${d.to} ${JSON.stringify((d as unknown as { type: { attrs?: unknown } }).type.attrs ?? "")}`,
      );
  expect(lines(joined)).toEqual(lines(whole));
  expect(lines(joined).length).toBe(1_500);
  // It finds a range in the middle as one set does.
  const middle = (set: DecorationSet) => set.find(2_000, 2_400).map((d) => `${d.from}-${d.to}`);
  expect(middle(joined)).toEqual(middle(whole));
});
