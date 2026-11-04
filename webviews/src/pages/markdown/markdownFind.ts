// Find in the markdown page (Cmd-F; user, 2026-10-31: "cmd f doesnt work in markdown"). The state
// is the code editor's (editorFind.ts `EditorFind`, behind the shared find pill); this file is the
// search over what the page shows. Rich text: the rendered document's text, one run per block (a
// paragraph, heading, list item, table cell, code block), so a match may span bold, links and code
// colors inside it; matches are painted with CSS custom highlights, never by rewriting the editor's
// DOM. Source: the text area's lines; the active match is its selection.
import { foldFind } from "../../find/fold";
import type { FindRange, FindTarget } from "../editor/editorFind";

/** The highlight names styles.css paints. */
export const MARKDOWN_FIND_HIGHLIGHT = "cmux-md-find";
export const MARKDOWN_FIND_ACTIVE_HIGHLIGHT = "cmux-md-find-active";

/** Elements whose text is one run. A match never crosses from one into the next. */
const BLOCKS = "p, h1, h2, h3, h4, h5, h6, li, td, th, pre, blockquote, dt, dd, figcaption, summary";
/** Text the reader does not see as the document's: hidden parts, drawn diagrams, widget chrome. */
const SKIPPED = "script, style, svg, [hidden], [aria-hidden='true'], [data-find-skip]";

export interface MarkdownFindView {
  mode(): "rich" | "source";
  /** The rendered document (`.md-doc`), null before the editor mounts. */
  doc(): HTMLElement | null;
  /** The source text area, null in rich mode. */
  source(): HTMLTextAreaElement | null;
  /** The scroll box both sit in (`.md-scroll`). */
  scroller(): HTMLElement | null;
}

/** One searchable run: consecutive text nodes of one block, and their joined text. */
interface Run {
  nodes: Text[];
  text: string;
}

function collectRuns(root: HTMLElement): Run[] {
  const runs: Run[] = [];
  // The block that holds the last text node: text joins its run only while the block is the same,
  // so a nested block (a list in a list item) and the text after it each start a new run.
  let owner: Element | null = null;
  const visit = (node: Node) => {
    if (node.nodeType === 3) {
      const text = (node as Text).data;
      if (!text) return;
      const block = node.parentElement?.closest(BLOCKS) ?? root;
      if (block === owner && runs.length) {
        const run = runs[runs.length - 1]!;
        run.nodes.push(node as Text);
        run.text += text;
      } else runs.push({ nodes: [node as Text], text });
      owner = block;
      return;
    }
    if (node.nodeType !== 1 || (node as Element).matches(SKIPPED)) return;
    for (let child = node.firstChild; child; child = child.nextSibling) visit(child);
  };
  for (let child = root.firstChild; child; child = child.nextSibling) visit(child);
  return runs;
}

/** Where offset `at` of a run's text lies; an end on a node boundary stays in the node before it. */
function locate(run: Run, at: number, end: boolean): [Text, number] {
  let rest = at;
  for (const [index, node] of run.nodes.entries()) {
    const length = node.data.length;
    if (rest < length || (end && rest === length) || index === run.nodes.length - 1)
      return [node, Math.min(rest, length)];
    rest -= length;
  }
  return [run.nodes[0]!, 0];
}

function rangeOf(run: Run, match: FindRange): Range {
  const range = run.nodes[0]!.ownerDocument.createRange();
  range.setStart(...locate(run, match.startColumn - 1, false));
  range.setEnd(...locate(run, match.endColumn - 1, true));
  return range;
}

function occurrences(text: string, query: string, matchCase: boolean, line: number, into: FindRange[]) {
  const hay = matchCase ? text : foldFind(text);
  const needle = matchCase ? query : foldFind(query);
  if (!needle) return;
  for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + needle.length)) {
    into.push({ startLineNumber: line, startColumn: at + 1, endLineNumber: line, endColumn: at + 1 + needle.length });
  }
}

type HighlightRegistry = { set(name: string, value: unknown): void; delete(name: string): void };
type HighlightConstructor = new (...ranges: Range[]) => { priority: number };

function highlights(): { registry: HighlightRegistry; Highlight: HighlightConstructor } | null {
  const registry = (globalThis.CSS as unknown as { highlights?: HighlightRegistry } | undefined)?.highlights;
  const Highlight = (globalThis as unknown as { Highlight?: HighlightConstructor }).Highlight;
  return registry && Highlight ? { registry, Highlight } : null;
}

/** Room the find pill takes over the top of the scroll box, kept clear when a match scrolls in. */
const PILL_CLEARANCE = 56;

/** Scrolls `match` into `scroller`'s view when it is not already in it, a third from the top. */
function reveal(scroller: HTMLElement, match: Range) {
  const rect = match.getBoundingClientRect();
  const box = scroller.getBoundingClientRect();
  if (rect.top < box.top + PILL_CLEARANCE || rect.bottom > box.bottom - 16) {
    scroller.scrollTop += rect.top - box.top - Math.max(PILL_CLEARANCE, scroller.clientHeight / 3);
  }
  // A wide table or code block scrolls sideways in its own box (styles.css): bring the match in.
  for (
    let element = match.startContainer.parentElement;
    element && element !== scroller;
    element = element.parentElement
  ) {
    if (element.scrollWidth <= element.clientWidth) continue;
    const outer = element.getBoundingClientRect();
    if (rect.left < outer.left || rect.right > outer.right)
      element.scrollLeft += rect.left - outer.left - outer.width / 3;
    break;
  }
}

/** The find target over the markdown page `view` (both modes). */
export function markdownFindTarget(view: MarkdownFindView): FindTarget {
  /** The runs the last search read, so `show` maps its matches onto the same nodes. */
  let runs: Run[] = [];
  /** Where the shown active match starts: a longer query searches on from it (as the code editor's
   * selection does), not from the top of the screen it was scrolled to. */
  let shown: { lineNumber: number; column: number } | null = null;

  const sourceLines = () => (view.source()?.value ?? "").split("\n");
  /** The 0-based offset in the source text of 1-based `line`, `column`. */
  const sourceOffset = (line: number, column: number) => {
    const lines = sourceLines();
    let offset = 0;
    for (let index = 0; index < line - 1 && index < lines.length; index++) offset += lines[index]!.length + 1;
    return offset + column - 1;
  };

  const clear = () => {
    const api = highlights();
    api?.registry.delete(MARKDOWN_FIND_HIGHLIGHT);
    api?.registry.delete(MARKDOWN_FIND_ACTIVE_HIGHLIGHT);
  };

  return {
    findMatches(query, matchCase) {
      const matches: FindRange[] = [];
      if (view.mode() === "source") {
        runs = [];
        sourceLines().forEach((line, index) => occurrences(line, query, matchCase, index + 1, matches));
        return matches;
      }
      const doc = view.doc();
      runs = doc ? collectRuns(doc) : [];
      runs.forEach((run, index) => occurrences(run.text, query, matchCase, index + 1, matches));
      return matches;
    },

    caret() {
      if (view.mode() === "source") {
        const source = view.source();
        const at = source?.selectionStart ?? 0;
        const before = (source?.value ?? "").slice(0, at).split("\n");
        return { lineNumber: before.length, column: before[before.length - 1]!.length + 1 };
      }
      if (shown) return shown;
      const doc = view.doc();
      const selection = doc?.ownerDocument.getSelection();
      const anchor = selection?.rangeCount ? selection.getRangeAt(0) : null;
      if (doc && anchor && doc.contains(anchor.startContainer)) {
        const runs = collectRuns(doc);
        for (const [index, run] of runs.entries()) {
          let offset = 0;
          for (const node of run.nodes) {
            if (node === anchor.startContainer)
              return { lineNumber: index + 1, column: offset + anchor.startOffset + 1 };
            offset += node.data.length;
          }
        }
      }
      // No caret in the document: the search starts at the first block on screen, as a browser's does.
      const scroller = view.scroller();
      if (doc && scroller) {
        const top = scroller.getBoundingClientRect().top;
        const runs = collectRuns(doc);
        for (const [index, run] of runs.entries()) {
          const parent = run.nodes[0]!.parentElement;
          if (parent && parent.getBoundingClientRect().bottom > top) return { lineNumber: index + 1, column: 1 };
        }
      }
      return { lineNumber: 1, column: 1 };
    },

    selectedText() {
      if (view.mode() === "source") {
        const source = view.source();
        return source ? source.value.slice(source.selectionStart, source.selectionEnd).split("\n")[0]! : "";
      }
      const doc = view.doc();
      const selection = doc?.ownerDocument.getSelection();
      if (!doc || !selection?.rangeCount || !doc.contains(selection.anchorNode)) return "";
      return selection.toString().split("\n")[0]!.trim();
    },

    show(matches, active) {
      const match = matches[active];
      shown = match ? { lineNumber: match.startLineNumber, column: match.startColumn } : null;
      if (view.mode() === "source") {
        clear();
        const source = view.source();
        if (!source || !match) return;
        const start = sourceOffset(match.startLineNumber, match.startColumn);
        source.setSelectionRange(start, start + (match.endColumn - match.startColumn));
        // The text area scrolls itself to its selection only while focused: put the line in view.
        const lineHeight =
          parseFloat(source.ownerDocument.defaultView?.getComputedStyle(source).lineHeight ?? "") || 20;
        const top = (match.startLineNumber - 1) * lineHeight;
        if (top < source.scrollTop + PILL_CLEARANCE || top > source.scrollTop + source.clientHeight - lineHeight * 2) {
          source.scrollTop = Math.max(0, top - source.clientHeight / 3);
        }
        return;
      }
      const api = highlights();
      if (!matches.length) return clear();
      const ranges = matches.map((match) => {
        const run = runs[match.startLineNumber - 1];
        return run ? rangeOf(run, match) : null;
      });
      const current = ranges[active] ?? null;
      if (api) {
        api.registry.set(
          MARKDOWN_FIND_HIGHLIGHT,
          new api.Highlight(...ranges.filter((range): range is Range => range !== null && range !== current)),
        );
        if (current) {
          const highlight = new api.Highlight(current);
          highlight.priority = 1;
          api.registry.set(MARKDOWN_FIND_ACTIVE_HIGHLIGHT, highlight);
        } else api.registry.delete(MARKDOWN_FIND_ACTIVE_HIGHLIGHT);
      }
      const scroller = view.scroller();
      if (current && scroller) reveal(scroller, current);
    },

    focus() {
      if (view.mode() === "source") return view.source()?.focus({ preventScroll: true });
      view.doc()?.querySelector<HTMLElement>("[contenteditable]")?.focus({ preventScroll: true });
    },
  };
}
