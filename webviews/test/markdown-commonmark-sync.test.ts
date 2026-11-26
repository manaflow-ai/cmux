// The bounded heading id and list order syncs (commonmarkSync.ts) leave the document exactly as
// Milkdown's own do: two editors, one with the stock commonmark preset and one with
// `boundedCommonmark`, take the same edits, and their documents are equal after each.
import { beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Node as ProseNode, Slice } from "@milkdown/kit/prose/model";
import type { EditorState, Transaction } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

setDefaultTimeout(120_000);

type Kit = {
  core: typeof import("@milkdown/kit/core");
  commonmark: typeof import("@milkdown/kit/preset/commonmark");
  gfm: typeof import("@milkdown/kit/preset/gfm");
  history: typeof import("@milkdown/kit/plugin/history");
  proseHistory: typeof import("@milkdown/kit/prose/history");
  model: typeof import("@milkdown/kit/prose/model");
  state: typeof import("@milkdown/kit/prose/state");
  sync: typeof import("../src/pages/markdown/commonmarkSync");
};
let kit: Kit;

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
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const rects = () => Object.assign([box()], { item: () => box() });
  for (const prototype of [dom.window.Range.prototype, dom.window.Element.prototype] as unknown as Array<
    Record<string, unknown>
  >) {
    prototype.getClientRects = rects;
    prototype.getBoundingClientRect = box;
  }
  kit = {
    core: await import("@milkdown/kit/core"),
    commonmark: await import("@milkdown/kit/preset/commonmark"),
    gfm: await import("@milkdown/kit/preset/gfm"),
    history: await import("@milkdown/kit/plugin/history"),
    proseHistory: await import("@milkdown/kit/prose/history"),
    model: await import("@milkdown/kit/prose/model"),
    state: await import("@milkdown/kit/prose/state"),
    sync: await import("../src/pages/markdown/commonmarkSync"),
  };
});

type Side = { view: EditorView; parse: (markdown: string) => ProseNode };

async function side(bounded: boolean, markdown: string): Promise<Side> {
  const { Editor, rootCtx, defaultValueCtx, editorViewCtx, parserCtx } = kit.core;
  const root = document.createElement("div");
  document.body.append(root);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, root);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(bounded ? kit.sync.boundedCommonmark : kit.commonmark.commonmark)
    .use(kit.gfm.gfm)
    .use(kit.history.history)
    .create();
  let out!: Side;
  editor.action((ctx) => {
    const parser = ctx.get(parserCtx);
    out = { view: ctx.get(editorViewCtx), parse: (text) => parser(text) };
  });
  return out;
}

/** Both editors over `markdown`: Milkdown's syncs, and the bounded ones. */
async function pair(markdown: string): Promise<[Side, Side]> {
  return [await side(false, markdown), await side(true, markdown)];
}

/** Applies `edit` to both and expects equal documents (ids and labels included). */
function both(sides: [Side, Side], edit: (state: EditorState, side: Side) => Transaction | null, what: string) {
  for (const current of sides) {
    const tr = edit(current.view.state, current);
    if (tr) current.view.dispatch(tr);
  }
  expect({ what, doc: sides[1].view.state.doc.toJSON() }).toEqual({ what, doc: sides[0].view.state.doc.toJSON() });
}

function command(
  sides: [Side, Side],
  run: (state: EditorState, dispatch: (tr: Transaction) => void) => boolean,
  what: string,
) {
  for (const current of sides) run(current.view.state, (tr) => current.view.dispatch(tr));
  expect({ what, doc: sides[1].view.state.doc.toJSON() }).toEqual({ what, doc: sides[0].view.state.doc.toJSON() });
}

/** The position just after the first `needle` in the document's text, or -1. */
function after(doc: ProseNode, needle: string): number {
  let pos = -1;
  doc.descendants((node, at) => {
    if (pos >= 0) return false;
    if (node.isText && node.text!.includes(needle)) pos = at + node.text!.indexOf(needle) + needle.length;
    return true;
  });
  return pos;
}

/** Each top-level block's start, in order. */
function starts(doc: ProseNode): number[] {
  const out: number[] = [];
  doc.forEach((_node, offset) => out.push(offset));
  return out;
}

const DOCUMENT = [
  "# Title",
  "intro text",
  "## Setup",
  "1. install\n2. configure\n3. run",
  "## Usage",
  "- [ ] task\n- item",
  "5. five\n6. six",
  "## Setup",
  "| a | b |\n| --- | --- |\n| c | d |",
  "> ## Quoted\n>\n> 1. inside\n> 2. quote",
  "## Notes",
  "end text",
].join("\n\n");

test("named edits leave the same document as Milkdown's syncs", async () => {
  const sides = await pair(DOCUMENT);
  const { TextSelection } = kit.state;
  const { undo, redo } = kit.proseHistory;
  both(sides, (state) => state.tr.insertText("x", after(state.doc, "intro")), "insert in a paragraph");
  both(sides, (state) => state.tr.insertText("y", after(state.doc, "configure")), "insert in an ordered item");
  both(
    sides,
    (state) => state.tr.delete(after(state.doc, "Usage") - 2, after(state.doc, "Usage")),
    "delete in a heading",
  );
  both(sides, (state) => state.tr.split(after(state.doc, "inst"), 2), "split an ordered item");
  both(sides, (state) => state.tr.split(after(state.doc, "intro")), "split a paragraph");
  both(
    sides,
    (state) => {
      // Joins the list after "## Usage"'s task list with the ordered list below it.
      const at = state.doc.resolve(after(state.doc, "five")).before(1);
      return state.tr.join(at);
    },
    "join two lists",
  );
  both(
    sides,
    (state) => {
      // Moves the first top-level block (the title) to before the last one.
      const blocks = starts(state.doc);
      const first = state.doc.child(0);
      const tr = state.tr.delete(0, first.nodeSize);
      return tr.insert(blocks[blocks.length - 1]! - first.nodeSize, first);
    },
    "move a block",
  );
  // A heading renamed to the text of a later one: that one's id becomes `-#2`.
  both(
    sides,
    (state) => {
      const from = after(state.doc, "Notes") - "Notes".length;
      return state.tr.insertText("Setup", from, from + "Notes".length);
    },
    "rename a heading onto a later one's id",
  );
  both(
    sides,
    (state) => {
      const to = after(state.doc, "Usa");
      return state.tr.insertText("Setup", to - 3, to);
    },
    "rename an earlier heading onto the same id",
  );
  both(
    sides,
    (state, current) => {
      const pasted = current.parse(Array.from({ length: 40 }, (_, i) => `## Setup\n\n1. p${i}\n2. q${i}`).join("\n\n"));
      const at = starts(state.doc)[3]!;
      const slice = new kit.model.Slice(pasted.content, 0, 0) as Slice;
      return state.tr.setSelection(TextSelection.near(state.doc.resolve(at + 1))).replaceSelection(slice);
    },
    "paste a large block",
  );
  for (let i = 0; i < 6; i++) command(sides, undo, `undo ${i}`);
  for (let i = 0; i < 4; i++) command(sides, redo, `redo ${i}`);
  both(sides, (state) => state.tr.insertText("z", after(state.doc, "end")), "insert after undo and redo");
});

/** A small seeded generator: the same edits for both editors, the same each run. */
function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

test("generated edits leave the same document as Milkdown's syncs", async () => {
  const sides = await pair(DOCUMENT);
  const { undo, redo } = kit.proseHistory;
  const next = random(45);
  const words = ["Setup", "Notes", "Title", "x", " ", "Usage", "1"];
  for (let step = 0; step < 200; step++) {
    const kind = Math.floor(next() * 7);
    const at = next();
    const span = next();
    const word = words[Math.floor(next() * words.length)]!;
    const textPositions = (doc: ProseNode) => {
      const out: number[] = [];
      doc.descendants((node, pos) => {
        if (node.isText) for (let i = 0; i <= node.nodeSize; i++) out.push(pos + i);
        return true;
      });
      return out;
    };
    if (kind === 5) {
      command(sides, at < 0.5 ? undo : redo, `step ${step}: ${at < 0.5 ? "undo" : "redo"}`);
      continue;
    }
    both(
      sides,
      (state, current) => {
        const positions = textPositions(state.doc);
        if (!positions.length) return null;
        const pos = positions[Math.floor(at * positions.length)]!;
        try {
          if (kind === 0) return state.tr.insertText(word, pos);
          if (kind === 1) return state.tr.delete(pos, Math.min(pos + 1 + Math.floor(span * 6), state.doc.content.size));
          if (kind === 2) return state.tr.split(pos, 1 + Math.floor(span * 2));
          if (kind === 3) {
            const blocks = starts(state.doc);
            const index = 1 + Math.floor(span * (blocks.length - 1));
            return index < blocks.length ? state.tr.join(blocks[index]!) : null;
          }
          if (kind === 4) {
            const pasted = current.parse(`## ${word}\n\n1. a\n2. b\n\n- c`);
            const blocks = starts(state.doc);
            return state.tr.insert(blocks[Math.floor(span * blocks.length)]!, pasted.content);
          }
          // A block moved: deleted and put back elsewhere in one transaction.
          const blocks = starts(state.doc);
          const from = Math.floor(span * blocks.length);
          const node = state.doc.child(from);
          const tr = state.tr.delete(blocks[from]!, blocks[from]! + node.nodeSize);
          const to = Math.floor(at * tr.doc.childCount);
          let target = 0;
          for (let i = 0; i < to; i++) target += tr.doc.child(i).nodeSize;
          return tr.insert(target, node);
        } catch {
          // An edit the schema refuses (a join of unlike blocks): neither editor takes it.
          return null;
        }
      },
      `step ${step}: kind ${kind}`,
    );
  }
});

test("a document out of sync is walked whole, as Milkdown's syncs walk it", async () => {
  const sides = await pair(DOCUMENT);
  // A list's labels set wrong by a change kept out of the history: list sync skips it.
  both(
    sides,
    (state) => {
      const pos = state.doc.resolve(after(state.doc, "configure")).before(2);
      const item = state.doc.nodeAt(pos)!;
      return state.tr.setNodeMarkup(pos, undefined, { ...item.attrs, label: "9." }).setMeta("addToHistory", false);
    },
    "labels out of sync",
  );
  expect(JSON.stringify(sides[1].view.state.doc.toJSON())).toContain('"label":"9."');
  // A heading renamed during an IME composition: the id sync waits for it to end.
  for (const current of sides) {
    const input = (current.view as unknown as { input: { composing: boolean } }).input;
    input.composing = true;
    const state = current.view.state;
    current.view.dispatch(state.tr.insertText("Renamed", after(state.doc, "Notes") - 5, after(state.doc, "Notes")));
    input.composing = false;
  }
  const notes = (doc: ProseNode) => {
    let id: unknown = null;
    doc.descendants((node) => {
      if (node.type.name === "heading" && node.textContent === "Renamed") id = node.attrs.id;
    });
    return id;
  };
  expect(notes(sides[1].view.state.doc)).toBe("notes");
  // An edit far from both: each sync walks the whole document and puts them right.
  both(sides, (state) => state.tr.insertText("x", after(state.doc, "end")), "an edit elsewhere");
  expect(JSON.stringify(sides[1].view.state.doc.toJSON())).not.toContain('"label":"9."');
  expect(notes(sides[1].view.state.doc)).toBe("renamed");
});

test("a bullet list made ordered is walked again on the next edit, as Milkdown's syncs walk it", async () => {
  const sides = await pair("- one\n\nintro text\n\nend text");
  // The first item of the list ordered and labelled "3." by a change kept out of the history,
  // as an undo (not a generic transaction: neither sync runs) can leave it.
  both(
    sides,
    (state) => {
      const pos = state.doc.resolve(after(state.doc, "one")).before(2);
      const item = state.doc.nodeAt(pos)!;
      return state.tr
        .setNodeMarkup(pos, undefined, { ...item.attrs, listType: "ordered", label: "3." })
        .setMeta("addToHistory", false);
    },
    "an ordered item in a bullet list",
  );
  // Milkdown's walk makes the list ordered, but leaves the item's label for the walk after.
  both(sides, (state) => state.tr.insertText("x", after(state.doc, "intro")), "an edit elsewhere makes it ordered");
  expect(JSON.stringify(sides[1].view.state.doc.toJSON())).toContain('"label":"3."');
  both(sides, (state) => state.tr.insertText("y", after(state.doc, "end")), "the next edit elsewhere");
  expect(JSON.stringify(sides[1].view.state.doc.toJSON())).not.toContain('"label":"3."');
});
