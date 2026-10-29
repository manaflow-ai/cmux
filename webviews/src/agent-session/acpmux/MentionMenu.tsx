import { useEffect, useState } from "react";
import {
  readFileSearch,
  type FileMatch,
  type FileSearchSource,
  type Run,
} from "./fileSearchModel";
import type { MentionItem } from "./mentionItems";
import { useT } from "./i18n";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";
import { useComposerPopup, popupChoice } from "./nativeComposerPopup";

/// How long typing settles before the picker asks again (as Search files does).
const MENTION_DEBOUNCE_MS = 80;

/// The `@` picker (cx-ncc.68): typing `@` at a word start in the prompt lists other chats, then the
/// folders and files of the chat's folder that match what follows, under the caret, the way the
/// Claude and Codex apps do. Picking one writes it in place of what was typed (mentionItems.ts).

/// The `@word` before the caret: where its `@` starts in the markdown and the word typed so far
/// (backslash escapes undone), or undefined when the caret is not in one. An `@` inside a word (an
/// email address) or inside an inline code span is not a mention. The prompt's markdown writes a
/// space after an escaped character as an entity (`\_\_init\_\_.py&#x20;`), which ends the word too.
export function mentionQuery(
  markdown: string,
  at: number,
): { start: number; query: string } | undefined {
  const before = markdown.slice(0, at);
  const found =
    /(^|\s|&#x20;|&#32;|&nbsp;)@((?:\\.|(?!&#x20;|&#32;|&nbsp;)[^\s\\@])*)$/i.exec(
      before,
    );
  if (!found) return undefined;
  const start = before.length - found[2]!.length - 1;
  // An odd number of backticks before it: inside a code span.
  if ((before.slice(0, start).match(/`/g)?.length ?? 0) % 2 === 1)
    return undefined;
  return { start, query: found[2]!.replace(/\\(.)/g, "$1") };
}

/// `@path ` as the prompt's markdown writes it: quoted when the path has a space (an agent reads a
/// mention up to the first one), with markdown's specials escaped so `__init__.py` is not bold.
/// `shown` is what the person sees, for the caret.
export function mentionText(path: string): { markdown: string; shown: string } {
  const shown = `@${/\s/.test(path) ? `"${path}"` : path} `;
  return { markdown: shown.replace(/[\\`*_[\]~<&]/g, "\\$&"), shown };
}

export type MentionState =
  | { kind: "idle" }
  | { kind: "searching"; results: FileMatch[] }
  | { kind: "done"; results: FileMatch[] }
  | { kind: "failed" };

/// The files matching `query` (undefined: the picker is closed), asked of `search` once typing
/// settles; only the newest answer lands.
export function useMentionSearch(
  search: FileSearchSource | undefined,
  query: string | undefined,
): MentionState {
  const [state, setState] = useState<MentionState>({ kind: "idle" });
  const generation = useRef(0);
  useEffect(() => {
    const ask = ++generation.current;
    const text = query?.trim();
    if (!search || !text) {
      setState({ kind: "idle" });
      return;
    }
    setState((current) => ({
      kind: "searching",
      results:
        current.kind === "done" || current.kind === "searching"
          ? current.results
          : [],
    }));
    const timer = setTimeout(() => {
      search(text).then(
        (reply) => {
          if (ask !== generation.current) return;
          const result = readFileSearch(reply);
          setState(
            result
              ? { kind: "done", results: result.results }
              : { kind: "failed" },
          );
        },
        () => {
          if (ask === generation.current) setState({ kind: "failed" });
        },
      );
    }, MENTION_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [search, query]);
  return state;
}

const NONE: FileMatch[] = [];
export const mentionResults = (state: MentionState): FileMatch[] =>
  state.kind === "done" || state.kind === "searching" ? state.results : NONE;

/// The picker under the prompt, styled as the slash menu: other chats, folders, then files
/// (mentionItems.ts), each with its icon, its name with the matched letters bold and its project or
/// folder muted beside it. The prompt keeps focus and its keys (Composer.tsx): arrows move, Return
/// or Tab picks, Esc closes. `state` is the file search's, undefined in a chat whose folder cannot be
/// searched (a remote chat), which lists chats only and says nothing of files. `active` -1: no row.

export function MentionMenu({
  state,
  items,
  active,
  query = "",
  anchor,
  onSearch,
  onHover,
  onPick,
}: {
  state: MentionState | undefined;
  items: readonly MentionItem[];
  active: number;
  query?: string;
  anchor: () => HTMLElement | null;
  onSearch?(value: string): void;
  onHover(index: number): void;
  onPick(item: MentionItem): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(true);
  const note = !state
    ? undefined
    : state.kind === "idle"
      ? t("files.hint")
      : state.kind === "failed"
        ? t("files.failed")
        : items.length === 0
          ? t(state.kind === "searching" ? "files.searching" : "files.none")
          : undefined;
  const rows: NativePopupRow[] = items.length
    ? items.map((item) =>
        popupChoice(
          item.key,
          item.kind === "session" ? item.title : item.path,
          {
            description: item.kind === "session" ? item.project : item.path,
            checked: false,
          },
        ),
      )
    : note
      ? [{ id: "note", kind: "text", label: note }]
      : [];
  useEffect(() => setOpen(true), [items.length]);
  useComposerPopup({
    open,
    anchor,
    model: {
      side: "top",
      align: "start",
      width: 420,
      title: t("files.search"),
      search: { id: "query", value: query, placeholder: t("files.search") },
      rows,
      highlighted: items[active]?.key,
    },
    onEvent: (event: NativePopupEvent) => {
      if (event.type === "search") {
        if (event.value !== undefined) onSearch?.(event.value);
        return;
      }
      if (event.type === "highlight" && event.id) {
        const index = items.findIndex((item) => item.key === event.id);
        if (index >= 0) onHover(index);
        return;
      }
      if (event.type === "pick" && event.id) {
        const item = items.find((candidate) => candidate.key === event.id);
        if (item) onPick(item);
      }
    },
    onDismiss: () => setOpen(false),
  });
}
