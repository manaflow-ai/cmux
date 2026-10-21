// Obsidian's Markdown syntax in the editor, drawn the way Obsidian's Live Preview draws it
// (MARKDOWN-OBSIDIAN-PARITY, PARITY.md): the file's text never changes; decorations style the
// syntax and hide its markers while the caret is outside it.
//
// - `==highlight==`, `%%comment%%`, `#tag`
// - `[[note]]`, `[[note#heading|alias]]`, `![[image.png|300]]` (Cmd-click opens the note)
// - callouts: a quote whose first line is `[!type]` (`[!type]-` folded, `+` open), with a title
// - `$inline math$` and a `$$ … $$` paragraph, typeset by KaTeX (loaded on first use)
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey, type EditorState } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import { isPointerSelecting, pointerChanged } from "./pointerSelect";

const key = new PluginKey<{ folded: Set<number>; decorations: DecorationSet }>("cmuxMarkdownObsidian");

/** The meta a fold toggle dispatches: the callout's position. */
const FOLD_META = "cmuxCalloutFold";

/** Callout types Obsidian knows, with its aliases (each draws as its canonical type). */
const CALLOUT_ALIASES: Record<string, string> = {
  summary: "abstract",
  tldr: "abstract",
  hint: "tip",
  important: "tip",
  check: "success",
  done: "success",
  help: "question",
  faq: "question",
  caution: "warning",
  attention: "warning",
  fail: "failure",
  missing: "failure",
  error: "danger",
  cite: "quote",
};

/** Image files an embed `![[…]]` draws as an image. */
const IMAGE_EMBED = /\.(png|jpe?g|gif|svg|webp|avif|bmp)$/i;

/** The link a wikilink target opens: `note` is `note.md`, a heading is a GitHub-style anchor. */
export function wikilinkHref(target: string): string {
  const [rawPath = "", heading] = target.split("#", 2);
  const path = rawPath.trim();
  const file = path && !/\.[a-z0-9]+$/i.test(path) ? `${path}.md` : path;
  const anchor = heading
    ? `#${heading
        .trim()
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\s-]/gu, "")
        .replace(/\s/g, "-")}`
    : "";
  return `${encodeURI(file)}${anchor}`;
}

/** Widths from an Obsidian size suffix: `300` or `300x200`. */
export function imageSize(suffix: string | undefined): { width?: number; height?: number } {
  const match = /^\s*(\d+)(?:\s*x\s*(\d+))?\s*$/.exec(suffix ?? "");
  if (!match) return {};
  return { width: Number(match[1]), height: match[2] ? Number(match[2]) : undefined };
}

// KaTeX loads with the first equation drawn: a file without math never pays for it.
type KaTeX = typeof import("katex").default;
let katex: KaTeX | null = null;
let loading: Promise<void> | null = null;
const waiting = new Set<() => void>();
function loadKaTeX(ready: () => void): void {
  waiting.add(ready);
  loading ??= Promise.all([import("katex"), import("katex/dist/katex.min.css").catch(() => undefined)])
    .then(([module]) => {
      katex = module.default;
      for (const run of waiting) run();
      waiting.clear();
    })
    .catch(() => {
      loading = null;
    });
}

function typeset(tex: string, display: boolean): HTMLElement {
  const element = document.createElement(display ? "div" : "span");
  element.className = `md-math ${display ? "md-math-block" : "md-math-inline"}`;
  element.contentEditable = "false";
  try {
    element.innerHTML = katex!.renderToString(tex, {
      displayMode: display,
      output: "htmlAndMathml",
      throwOnError: true,
      strict: "ignore",
      trust: false,
      maxSize: 50,
      maxExpand: 500,
    });
  } catch {
    element.classList.add("md-math-error");
    element.textContent = tex;
  }
  return element;
}

interface Piece {
  /** Text of the textblock with non-text inline nodes and inline code as U+FFFC. */
  text: string;
  /** The document position of `text[0]`. */
  start: number;
}

/** A textblock's text, index for index with document positions. */
function blockText(node: ProseNode, pos: number): Piece {
  let text = "";
  node.forEach((child) => {
    if (child.isText && !child.marks.some((mark) => mark.type.spec.code)) text += child.text;
    // A line break (a hardbreak node, also for a soft break in the file) is a newline.
    else if (child.type.name === "hardbreak" || child.type.name === "hard_break") text += "\n";
    else text += "￼".repeat(child.nodeSize);
  });
  return { text, start: pos + 1 };
}

const PATTERNS = {
  highlight: /==(?=[^\s=])([^=\n]*?[^\s=])==/g,
  comment: /%%[\s\S]*?%%/g,
  tag: /(^|[\s(])(#[\p{L}\p{N}_\-/]*[\p{L}_\-/][\p{L}\p{N}_\-/]*)/gu,
  wikilink: /(!?)\[\[([^\]|\n￼]+?)(?:\|([^\]\n￼]*))?\]\]/g,
  math: /(?<![\\$\w])\$(?=[^\s$])([^$\n￼]*?[^\s$\\])\$(?![\w$])/g,
};

/**
 * Whether the selection reveals the syntax over [from, to]: a caret inside it or at an edge, or a
 * selection that lies inside it. A selection that only crosses it (a drag over a paragraph, Cmd-A)
 * reveals nothing, so the text it selects does not move (MARKDOWN-SELECTION).
 */
function touches(state: EditorState, from: number, to: number): boolean {
  const { from: a, to: b } = state.selection;
  return a >= from && b <= to;
}

function decorate(
  state: EditorState,
  folded: Set<number>,
  host: ObsidianHost,
  view: () => EditorView | null,
): DecorationSet {
  const decorations: Decoration[] = [];
  const hide = (from: number, to: number) =>
    decorations.push(Decoration.inline(from, to, { class: "md-syntax-hidden" }));
  const syntax = (from: number, to: number) => decorations.push(Decoration.inline(from, to, { class: "md-syntax" }));

  state.doc.descendants((node, pos, parent) => {
    if (node.type.spec.code) return false;

    // Callouts: a quote whose first paragraph starts with `[!type]`.
    if (node.type.name === "blockquote") {
      const first = node.firstChild;
      const firstText = first?.isTextblock ? blockText(first, pos + 1).text : "";
      const match = /^\[!([\w-]+)\]([+-]?)[ \t]*([^\n]*)/.exec(firstText);
      if (match && first) {
        const written = match[1]!.toLowerCase();
        const type = CALLOUT_ALIASES[written] ?? written;
        const isFolded = folded.has(pos) ? match[2] !== "-" : match[2] === "-";
        decorations.push(
          Decoration.node(pos, pos + node.nodeSize, {
            class: `md-callout${isFolded ? " md-callout-folded" : ""}${match[2] ? " md-callout-foldable" : ""}`,
            "data-callout": type,
          }),
        );
        const titleStart = pos + 1;
        decorations.push(Decoration.node(titleStart, titleStart + first.nodeSize, { class: "md-callout-title" }));
        const markerFrom = titleStart + 1;
        const markerTo = markerFrom + match[0].length - match[3]!.length;
        if (!touches(state, titleStart, titleStart + first.nodeSize)) hide(markerFrom, markerTo);
        else syntax(markerFrom, markerTo);
        decorations.push(
          Decoration.widget(
            markerFrom,
            () => {
              const icon = document.createElement("span");
              icon.className = "md-callout-icon";
              icon.contentEditable = "false";
              icon.setAttribute("aria-hidden", "true");
              return icon;
            },
            { side: -1, key: `icon-${type}`, ignoreSelection: true },
          ),
        );
        // The quote's first line is the title; the rest of that paragraph is body, as in Obsidian.
        const lineEnd = firstText.indexOf("\n");
        if (lineEnd >= 0)
          decorations.push(
            Decoration.inline(markerFrom + lineEnd, titleStart + first.nodeSize - 1, { class: "md-callout-body" }),
          );
        if (!match[3]!.trim())
          decorations.push(
            Decoration.widget(
              markerTo,
              () => {
                const title = document.createElement("span");
                title.className = "md-callout-default-title";
                title.contentEditable = "false";
                title.textContent = written.charAt(0).toUpperCase() + written.slice(1);
                return title;
              },
              { side: 1, key: `title-${written}` },
            ),
          );
        if (match[2])
          decorations.push(
            Decoration.widget(
              lineEnd >= 0 ? markerFrom + lineEnd : titleStart + first.nodeSize - 1,
              () => {
                const fold = document.createElement("button");
                fold.type = "button";
                fold.className = "md-callout-fold";
                fold.contentEditable = "false";
                // ui-allow: the fold button sits inside the editable text, where Tab belongs to the editor; a click folds it.
                fold.tabIndex = -1;
                fold.setAttribute("aria-expanded", String(!isFolded));
                fold.addEventListener("mousedown", (event) => {
                  event.preventDefault();
                  const editor = view();
                  editor?.dispatch(editor.state.tr.setMeta(FOLD_META, pos));
                });
                return fold;
              },
              { side: 1, key: `fold-${isFolded}`, ignoreSelection: true },
            ),
          );
      }
      return true;
    }

    if (!node.isTextblock) return true;
    const { text, start } = blockText(node, pos);

    // A `$$ … $$` paragraph is display math.
    const block = node.type.name === "paragraph" ? /^\$\$([\s\S]+?)\$\$$/.exec(text.trim()) : null;
    if (block && parent?.type.name !== "table_cell") {
      if (!touches(state, pos, pos + node.nodeSize)) {
        decorations.push(Decoration.node(pos, pos + node.nodeSize, { class: "md-math-source-hidden" }));
        const tex = block[1]!.trim();
        if (katex) decorations.push(Decoration.widget(pos, () => typeset(tex, true), { side: -1, key: `mb:${tex}` }));
        else loadKaTeX(() => refresh(view()));
      }
      return false;
    }

    for (const match of text.matchAll(PATTERNS.comment)) {
      const from = start + match.index!;
      decorations.push(Decoration.inline(from, from + match[0].length, { class: "md-comment" }));
    }

    for (const match of text.matchAll(PATTERNS.highlight)) {
      const from = start + match.index!;
      const to = from + match[0].length;
      decorations.push(Decoration.inline(from + 2, to - 2, { class: "md-highlight" }));
      if (touches(state, from, to)) {
        syntax(from, from + 2);
        syntax(to - 2, to);
      } else {
        hide(from, from + 2);
        hide(to - 2, to);
      }
    }

    for (const match of text.matchAll(PATTERNS.tag)) {
      const from = start + match.index! + match[1]!.length;
      decorations.push(Decoration.inline(from, from + match[2]!.length, { class: "md-tag" }));
    }

    for (const match of text.matchAll(PATTERNS.wikilink)) {
      const from = start + match.index!;
      const to = from + match[0].length;
      const embed = match[1] === "!";
      const target = match[2]!.trim();
      const alias = match[3];
      const open = from + match[1]!.length + 2;
      const labelFrom = alias !== undefined ? open + match[2]!.length + 1 : open;
      const labelTo = to - 2;
      const revealed = touches(state, from, to);
      if (embed && IMAGE_EMBED.test(target) && !revealed) {
        const size = imageSize(alias);
        hide(from, to);
        decorations.push(
          Decoration.widget(
            from,
            () => {
              const image = document.createElement("img");
              image.className = "md-embed-image";
              image.src = host.imageURL(target);
              image.alt = target;
              if (size.width) image.width = size.width;
              if (size.height) image.height = size.height;
              return image;
            },
            { side: -1, key: `embed:${target}:${alias ?? ""}` },
          ),
        );
        continue;
      }
      decorations.push(
        Decoration.inline(revealed ? open : labelFrom, revealed ? labelTo : labelTo, {
          class: `md-wikilink${embed ? " md-embed" : ""}`,
          "data-href": wikilinkHref(target),
        }),
      );
      if (revealed) {
        syntax(from, open);
        syntax(labelTo, to);
      } else {
        hide(from, labelFrom);
        hide(labelTo, to);
      }
    }

    for (const match of text.matchAll(PATTERNS.math)) {
      const from = start + match.index!;
      const to = from + match[0].length;
      if (touches(state, from, to)) continue;
      const tex = match[1]!;
      if (!katex) {
        loadKaTeX(() => refresh(view()));
        continue;
      }
      hide(from, to);
      decorations.push(Decoration.widget(from, () => typeset(tex, false), { side: -1, key: `mi:${tex}` }));
    }
    return false;
  });
  return DecorationSet.create(state.doc, decorations);
}

function refresh(view: EditorView | null): void {
  if (view && !view.isDestroyed) view.dispatch(view.state.tr.setMeta(key, "refresh").setMeta("addToHistory", false));
}

/** What the plugin needs from the page. */
export interface ObsidianHost {
  imageURL(src: string): string;
}

/** The Obsidian syntax decorations (and callout fold state). */
export function obsidianSyntaxPlugin(host: ObsidianHost) {
  return $prose(() => {
    let current: EditorView | null = null;
    const view = () => current;
    return new Plugin<{ folded: Set<number>; decorations: DecorationSet }>({
      key,
      state: {
        init: (_config, state) => ({ folded: new Set(), decorations: decorate(state, new Set(), host, view) }),
        apply(tr, previous, old, state) {
          let folded = previous.folded;
          if (tr.docChanged) folded = new Set([...folded].map((pos) => tr.mapping.map(pos)));
          const toggle = tr.getMeta(FOLD_META) as number | undefined;
          if (toggle !== undefined) {
            folded = new Set(folded);
            if (folded.has(toggle)) folded.delete(toggle);
            else folded.add(toggle);
          }
          // While the button is down, a selection change reveals nothing new (pointerSelect.ts).
          const selectionOnly = !tr.selectionSet || isPointerSelecting(state);
          if (
            !tr.docChanged &&
            selectionOnly &&
            toggle === undefined &&
            !tr.getMeta(key) &&
            !pointerChanged(tr) &&
            old.doc === state.doc
          )
            return previous;
          return { folded, decorations: decorate(state, folded, host, view) };
        },
      },
      view(editorView) {
        current = editorView;
        return { destroy: () => void (current = null) };
      },
      props: {
        decorations: (state) => key.getState(state)?.decorations,
      },
    });
  });
}
