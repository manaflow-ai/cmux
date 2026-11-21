// Whether a transcript block (an edit's diff, a command's Shell block, a call's output) wraps its
// long lines. Each kind of block has its own choice: prose (a Markdown or text file) wraps by
// default, and code does not. A call's output wraps down unless it is a table: Leo, 2026-11-11, on a
// Shell card whose one long output line ran off the right edge: "shouldn't this be... not
// horizontally scrolled? as in, it goes down instead of to the right?" A table (`ps`, `ls -l`, a
// test summary) keeps each printed row on its own line, columns aligned, the block scrolling
// sideways for what runs past (Leo, 2026-11-04, on a Shell card's folded `ps` output: "why isn't
// this just prettified by default?"); `outputWraps` tells the two apart. The wrap button in a
// block's header flips its kind's choice for every block of that kind, and the choice is the
// viewer's, kept in localStorage across chats and panes (in step by the `storage` event); until the
// viewer picks, each output block follows its own shape.
import { useSyncExternalStore } from "react";

export type BlockKind = "prose" | "code" | "output";

const DEFAULTS: Readonly<Record<BlockKind, boolean>> = { prose: true, code: false, output: true };
const KEY = "cmux.agentPane.blockWrap";
/// Each kind's field in storage. Output's choice was made against one fixed default (aligned, until
/// 2026-11-11); its field is new, so that choice does not pin every block to it now that output
/// follows its shape.
const FIELD: Readonly<Record<BlockKind, string>> = { prose: "prose", code: "code", output: "outputByShape" };

/// The lines `outputWraps` reads: enough for a table's header and rows, never a whole huge log.
const SHAPE_LINES = 200;
/// A table's column gap: two or more spaces, or a tab, between two printed characters (leading
/// indentation is not a gap). Box-drawing characters draw a tree or a diagram, which wrapping breaks.
const COLUMN_GAP = /\S(?: {2,}|\t+)\S|[\u2500-\u257f]/;

/// Whether an output block wraps until the viewer picks: everything but a table, which is at least
/// two rows with a column gap, and at least half its printed rows.
export function outputWraps(text: string | undefined): boolean {
  if (!text) return true;
  let rows = 0;
  let gapped = 0;
  let start = 0;
  for (let read = 0; read < SHAPE_LINES && start <= text.length; read++) {
    const end = text.indexOf("\n", start);
    const line = text.slice(start, end < 0 ? text.length : end);
    if (line.trim()) {
      rows++;
      if (COLUMN_GAP.test(line)) gapped++;
    }
    if (end < 0) break;
    start = end + 1;
  }
  return !(gapped >= 2 && gapped * 2 >= rows);
}

/// Files read as prose: wrapped by default, with a hanging indent.
const PROSE = new Set(["md", "markdown", "mdx", "txt", "text", "rst", "adoc", "asciidoc", "org", "tex"]);

/// The kind of an edit's block, from its file's name.
export function fileBlockKind(path: string): BlockKind {
  const name = path.split("/").pop() ?? path;
  const dot = name.lastIndexOf(".");
  return dot > 0 && PROSE.has(name.slice(dot + 1).toLowerCase()) ? "prose" : "code";
}

type Choices = Readonly<Partial<Record<BlockKind, boolean>>>;

function read(): Choices {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(KEY) ?? "{}");
    if (!value || typeof value !== "object") return {};
    const choices: Partial<Record<BlockKind, boolean>> = {};
    for (const kind of Object.keys(DEFAULTS) as BlockKind[]) {
      const choice = (value as Record<string, unknown>)[FIELD[kind]];
      if (typeof choice === "boolean") choices[kind] = choice;
    }
    return choices;
  } catch {
    return {};
  }
}

/// The page's copy, for a page with no storage (a private window); storage's when there is one.
let fallback: Choices = {};
const listeners = new Set<() => void>();
function current(): Choices {
  try {
    return globalThis.localStorage ? read() : fallback;
  } catch {
    return fallback;
  }
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    if (event.key === KEY) listener();
  };
  globalThis.addEventListener?.("storage", onStorage);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", onStorage);
  };
}

/// Sets `kind`'s choice for every block of that kind, and remembers it.
export function setBlockWrap(kind: BlockKind, wrap: boolean) {
  fallback = { ...current(), [kind]: wrap };
  const stored: Record<string, boolean> = {};
  for (const [each, choice] of Object.entries(fallback) as [BlockKind, boolean][]) stored[FIELD[each]] = choice;
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(stored));
  } catch {
    // Storage off: the page's copy still holds it.
  }
  for (const listener of listeners) listener();
}

/// Whether blocks of `kind` wrap now (outside React: the chat menu's Wrap lines row).
export function blockWrapOf(kind: BlockKind): boolean {
  return current()[kind] ?? DEFAULTS[kind];
}

/// Whether blocks of `kind` wrap, and the toggle the block's wrap button calls. `shaped` is what this
/// block does until the viewer picks (an output's `outputWraps`); the kind's default otherwise.
export function useBlockWrap(kind: BlockKind, shaped?: boolean): [wrap: boolean, toggle: () => void] {
  const wrap = useSyncExternalStore(subscribe, () => current()[kind] ?? shaped ?? DEFAULTS[kind]);
  return [wrap, () => setBlockWrap(kind, !wrap)];
}
