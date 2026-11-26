// The bounded heading id and list order syncs (commonmarkSync.ts) leave the document exactly as
// Milkdown's own do: two editors, one with the stock commonmark preset and one with
// `boundedCommonmark`, take the same edits, and their documents are equal after each. The heading
// anchors and broken-link marks, carried from edit to edit (headingIndex.ts), are checked after each
// against a walk of the whole document.
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
  links: typeof import("../src/pages/markdown/links");
  linkEditing: typeof import("../src/pages/markdown/linkEditing");
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
    links: await import("../src/pages/markdown/links"),
    linkEditing: await import("../src/pages/markdown/linkEditing"),
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
    .use(
      kit.linkEditing.brokenLinkPlugin({
        resolved: () => ({ exists: true }),
        requestLinks: () => {},
        linkLabel: (key) => key,
      }),
    )
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

/** Every heading's GitHub anchor, by a walk of the whole document (`headingTargets` before the index). */
function walkedTargets(doc: ProseNode) {
  const slugger = new kit.links.Slugger();
  const out: Array<{ slug: string; text: string; level: number; pos: number }> = [];
  doc.descendants((node, pos) => {
    if (node.type.name !== "heading") return !node.isTextblock;
    out.push({ slug: slugger.slug(node.textContent), text: node.textContent, level: Number(node.attrs.level), pos });
    return false;
  });
  return out;
}

/** The broken-link marks drawn, and those a walk of the whole document finds. */
function brokenLinks(state: EditorState) {
  const plugin = state.plugins.find(
    (candidate) => (candidate as unknown as { key: string }).key === "cmuxMarkdownLinks$",
  );
  const drawn = (plugin!.getState(state) as import("@milkdown/kit/prose/view").DecorationSet)
    .find()
    .map((decoration) => [decoration.from, decoration.to]);
  const slugs = new Set(walkedTargets(state.doc).map((target) => target.slug));
  const walked: number[][] = [];
  state.doc.descendants((node, pos) => {
    const mark = node.isText && node.marks.find((candidate) => candidate.type.name === "link");
    if (!mark) return true;
    const link = kit.links.parseLink(String(mark.attrs.href));
    const anchor = link.anchor.trim();
    if (link.kind === "anchor" && !slugs.has(anchor) && !slugs.has(kit.links.githubSlug(anchor)))
      walked.push([pos, pos + node.nodeSize]);
    return true;
  });
  return { drawn: drawn.sort((a, b) => a[0]! - b[0]!), walked };
}

/** Expects equal documents (ids and labels included), and the bounded side's anchors and broken links as a walk finds them. */
function same(sides: [Side, Side], what: string) {
  expect({ what, doc: sides[1].view.state.doc.toJSON() }).toEqual({ what, doc: sides[0].view.state.doc.toJSON() });
  const { doc } = sides[1].view.state;
  expect({ what, targets: kit.links.headingTargets(doc) }).toEqual({ what, targets: walkedTargets(doc) });
  for (const target of walkedTargets(doc))
    expect({ what, found: kit.links.findHeading(doc, target.slug) }).toEqual({ what, found: target });
  const { drawn, walked } = brokenLinks(sides[1].view.state);
  expect({ what, broken: drawn }).toEqual({ what, broken: walked });
}

/** Applies `edit` to both and expects the same results (`same`). */
function both(sides: [Side, Side], edit: (state: EditorState, side: Side) => Transaction | null, what: string) {
  for (const current of sides) {
    const tr = edit(current.view.state, current);
    if (tr) current.view.dispatch(tr);
  }
  same(sides, what);
}

function command(
  sides: [Side, Side],
  run: (state: EditorState, dispatch: (tr: Transaction) => void) => boolean,
  what: string,
) {
  for (const current of sides) run(current.view.state, (tr) => current.view.dispatch(tr));
  same(sides, what);
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
  "## Setup 1",
  "links [s](#setup) [s1](#setup-1) [s2](#setup-2) [s11](#setup-1-1) [n](#notes) [N](#Notes) [t](#title) [u](#usage-1) [x](#setupx)",
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
  const words = ["Setup", "Notes", "Title", "x", " ", "Usage", "1", "-1", "## Setup"];
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

/** The position of the `nth` heading whose text is `text`. */
function heading(doc: ProseNode, text: string, nth = 0): number {
  const found: number[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name === "heading" && node.textContent === text) found.push(pos);
    return !node.isTextblock;
  });
  expect(found.length).toBeGreaterThan(nth);
  return found[nth]!;
}

test("heading renames, repeats and deletes leave Milkdown's ids and a walk's anchors", async () => {
  const sides = await pair(DOCUMENT);
  const { undo, redo } = kit.proseHistory;
  const rename =
    (text: string, to: string, nth = 0) =>
    (state: EditorState) => {
      const pos = heading(state.doc, text, nth);
      return state.tr.insertText(to, pos + 1, pos + 1 + text.length);
    };
  // "Setup" twice, then "Setup 1": Milkdown's `setup-#2`, GitHub's `setup-1` and `setup-1-1`.
  both(sides, rename("Notes", "Setup"), "rename a heading onto a repeated id");
  let title = "Title";
  for (const key of ["x", "-", "1"]) {
    const typed = title;
    both(
      sides,
      (state) => state.tr.insertText(key, heading(state.doc, typed) + 1 + typed.length),
      `type ${key} in a heading`,
    );
    title += key;
  }
  both(sides, rename("Titlex-1", "Setup-1"), "rename onto a GitHub suffix of another heading");
  both(sides, rename("Usage", "Setup"), "rename an earlier heading onto the same id");
  both(
    sides,
    (state) => {
      const pos = heading(state.doc, "Setup");
      return state.tr.delete(pos, pos + state.doc.nodeAt(pos)!.nodeSize);
    },
    "delete the first of the headings with an id",
  );
  both(
    sides,
    (state) => {
      const pos = heading(state.doc, "Setup");
      return state.tr.delete(pos + 1, pos + 1 + "Setup".length);
    },
    "empty the first of the headings with an id",
  );
  both(sides, rename("Quoted", "Setup 1"), "rename a quoted heading onto another's id");
  both(
    sides,
    (state) => state.tr.setNodeMarkup(heading(state.doc, "Setup 1"), undefined, { level: 4, id: "" }),
    "change a heading's level",
  );
  both(
    sides,
    (state) => {
      const pos = state.doc.resolve(after(state.doc, "intro")).before(1);
      return state.tr.setBlockType(pos + 1, pos + 1, state.schema.nodes.heading!, { level: 2 });
    },
    "make a paragraph a heading",
  );
  for (let i = 0; i < 12; i++) command(sides, undo, `undo ${i}`);
  for (let i = 0; i < 5; i++) command(sides, redo, `redo ${i}`);
  both(sides, rename("Setup", "Notes", 1), "rename after undo and redo");
});

/** Each heading's text and id, in order. */
function headingIds(doc: ProseNode): Array<[string, unknown]> {
  const out: Array<[string, unknown]> = [];
  doc.descendants((node) => {
    if (node.type.name === "heading") out.push([node.textContent, node.attrs.id]);
    return !node.isTextblock;
  });
  return out;
}

// A deliberate divergence from Milkdown: its syncHeadingIdPlugin counts ids in a plain object, so a
// heading whose id is an Object.prototype key ("constructor", "__proto__": its id generator
// lowercases, so "toString" or "hasOwnProperty" is "tostring" or "hasownproperty", no key) counts
// as a repeat from the first and gets an id like `constructor-#function Object() {…}1`. Here it
// gets its own id, and `-#2` on for repeats. The equivalence tests above never type these words.
test("headings whose ids are Object.prototype keys get their own ids and -#n repeats", async () => {
  const markdown = [
    "# Constructor",
    "# \\_\\_proto\\_\\_",
    "# toString",
    "# constructor",
    "# hasOwnProperty",
    "# \\_\\_proto\\_\\_",
    "# valueOf",
    "# CONSTRUCTOR",
  ].join("\n\n");
  const { view } = await side(true, markdown);
  const expected: Array<[string, string]> = [
    ["Constructor", "constructor"],
    ["__proto__", "__proto__"],
    ["toString", "tostring"],
    ["constructor", "constructor-#2"],
    ["hasOwnProperty", "hasownproperty"],
    ["__proto__", "__proto__-#2"],
    ["valueOf", "valueof"],
    ["CONSTRUCTOR", "constructor-#3"],
  ];
  expect(headingIds(view.state.doc)).toEqual(expected);
  // Edits: a heading renamed onto one of them, and the first of a repeated id deleted.
  const rename = (text: string, to: string) => {
    const pos = heading(view.state.doc, text);
    view.dispatch(view.state.tr.insertText(to, pos + 1, pos + 1 + text.length));
  };
  rename("toString", "Constructor");
  expect(headingIds(view.state.doc)).toEqual([
    ["Constructor", "constructor"],
    ["__proto__", "__proto__"],
    ["Constructor", "constructor-#2"],
    ["constructor", "constructor-#3"],
    ["hasOwnProperty", "hasownproperty"],
    ["__proto__", "__proto__-#2"],
    ["valueOf", "valueof"],
    ["CONSTRUCTOR", "constructor-#4"],
  ]);
  const first = heading(view.state.doc, "__proto__");
  view.dispatch(view.state.tr.delete(first, first + view.state.doc.nodeAt(first)!.nodeSize));
  expect(headingIds(view.state.doc).filter(([text]) => text === "__proto__")).toEqual([["__proto__", "__proto__"]]);
  // The GitHub anchors of the same headings, as a walk finds them.
  expect(kit.links.headingTargets(view.state.doc)).toEqual(walkedTargets(view.state.doc));
});

/** Each list item's text, listType and label, in order. */
function listItems(doc: ProseNode): Array<[string, unknown, unknown]> {
  const out: Array<[string, unknown, unknown]> = [];
  doc.descendants((node) => {
    if (node.type.name === "list_item") out.push([node.textContent, node.attrs.listType, node.attrs.label]);
    return true;
  });
  return out;
}

// A deliberate divergence from Milkdown: its syncListOrderPlugin sets `changed` from the label
// check after the listType check set it, so an item of an ordered list with listType "bullet" and
// the right label is left a bullet. Here it is made "ordered". The equivalence tests above give
// bullet items only the parsed "•" label, never a right one.
test("an ordered list's bullet item with the right label is made ordered", async () => {
  const { view } = await side(true, "1. one\n2. two\n\nintro text\n\nend text");
  const setItem = (text: string, attrs: Record<string, unknown>, outOfHistory: boolean) => {
    const pos = view.state.doc.resolve(after(view.state.doc, text)).before(2);
    const item = view.state.doc.nodeAt(pos)!;
    const tr = view.state.tr.setNodeMarkup(pos, undefined, { ...item.attrs, ...attrs });
    view.dispatch(outOfHistory ? tr.setMeta("addToHistory", false) : tr);
  };
  // A document in sync: the edit's own block is walked.
  setItem("one", { listType: "bullet", label: "1." }, false);
  expect(listItems(view.state.doc)).toEqual([
    ["one", "ordered", "1."],
    ["two", "ordered", "2."],
  ]);
  // Out of sync (a change kept out of the history): the next edit walks the whole document.
  setItem("two", { listType: "bullet", label: "2." }, true);
  view.dispatch(view.state.tr.insertText("x", after(view.state.doc, "intro")));
  expect(listItems(view.state.doc)).toEqual([
    ["one", "ordered", "1."],
    ["two", "ordered", "2."],
  ]);
});
