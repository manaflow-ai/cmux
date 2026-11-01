// Whether a transcript block (an edit's diff, a command's Shell block, a call's output) wraps its
// long lines. Each kind of block has its own choice: prose (a Markdown or text file) wraps by
// default, code does not, and output wraps as a terminal transcript does. The wrap button in a
// block's header flips its kind's choice for every block of that kind, and the choice is the
// viewer's, kept in localStorage across chats and panes (in step by the `storage` event).
import { useSyncExternalStore } from "react";

export type BlockKind = "prose" | "code" | "output";

const DEFAULTS: Readonly<Record<BlockKind, boolean>> = { prose: true, code: false, output: true };
const KEY = "cmux.agentPane.blockWrap";

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
      const choice = (value as Record<string, unknown>)[kind];
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
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(fallback));
  } catch {
    // Storage off: the page's copy still holds it.
  }
  for (const listener of listeners) listener();
}

/// Whether blocks of `kind` wrap now (outside React: the chat menu's Wrap lines row).
export function blockWrapOf(kind: BlockKind): boolean {
  return current()[kind] ?? DEFAULTS[kind];
}

/// Whether blocks of `kind` wrap, and the toggle the block's wrap button calls.
export function useBlockWrap(kind: BlockKind): [wrap: boolean, toggle: () => void] {
  const wrap = useSyncExternalStore(subscribe, () => current()[kind] ?? DEFAULTS[kind]);
  return [wrap, () => setBlockWrap(kind, !wrap)];
}
