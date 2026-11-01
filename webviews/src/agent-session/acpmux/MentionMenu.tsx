import { useEffect, useRef, useState } from "react";
import { useEscapingList } from "../../ui/popupHost";
import { readFileSearch, type FileMatch, type FileSearchSource, type Run } from "./fileSearchModel";
import { Icon } from "./icons/Icon";
import type { MentionItem } from "./mentionItems";
import { PickerOption, PickerOptionList } from "../../ui/PickerPrimitives";
import { useT } from "./i18n";

/// How long typing settles before the picker asks again (as Search files does).
const MENTION_DEBOUNCE_MS = 80;

/// The `@` picker (cx-ncc.68): typing `@` at a word start in the prompt lists other chats, then the
/// folders and files of the chat's folder that match what follows, under the caret, the way the
/// Claude and Codex apps do. Picking one writes it in place of what was typed (mentionItems.ts).

/// The `@word` before the caret: where its `@` starts in the markdown and the word typed so far
/// (backslash escapes undone), or undefined when the caret is not in one. An `@` inside a word (an
/// email address) or inside an inline code span is not a mention. The prompt's markdown writes a
/// space after an escaped character as an entity (`\_\_init\_\_.py&#x20;`), which ends the word too.
export function mentionQuery(markdown: string, at: number): { start: number; query: string } | undefined {
  const before = markdown.slice(0, at);
  const found = /(^|\s|&#x20;|&#32;|&nbsp;)@((?:\\.|(?!&#x20;|&#32;|&nbsp;)[^\s\\@])*)$/i.exec(before);
  if (!found) return undefined;
  const start = before.length - found[2]!.length - 1;
  // An odd number of backticks before it: inside a code span.
  if ((before.slice(0, start).match(/`/g)?.length ?? 0) % 2 === 1) return undefined;
  return { start, query: found[2]!.replace(/\\(.)/g, "$1") };
}

/// Where the caret, counted in the characters the prompt shows, falls in its markdown: a
/// backslash escape and a character reference (the serializer's `&#x20;`) each show as one, and so
/// does an attachment placed in the text: the editor counts its atom as one place, the markdown
/// holds its whole token (attachments.ts inlineToken).
export function markdownOffset(markdown: string, shown: number): number {
  let index = 0;
  for (let count = 0; count < shown && index < markdown.length; count++) {
    const escape = /^(\\[!-/:-@[-`{-~]|&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);|\uFFFC[\w.~%-]+\uFFFC)/i.exec(
      markdown.slice(index),
    );
    index += escape ? escape[0].length : 1;
  }
  return index;
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
export function useMentionSearch(search: FileSearchSource | undefined, query: string | undefined): MentionState {
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
      results: current.kind === "done" || current.kind === "searching" ? current.results : [],
    }));
    const timer = setTimeout(() => {
      search(text).then(
        (reply) => {
          if (ask !== generation.current) return;
          const result = readFileSearch(reply);
          setState(result ? { kind: "done", results: result.results } : { kind: "failed" });
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
  onHover,
  onPick,
}: {
  state: MentionState | undefined;
  items: readonly MentionItem[];
  active: number;
  onHover(index: number): void;
  onPick(item: MentionItem): void;
}) {
  const t = useT();
  // Above the composer, or past the window's edge when the pane has no room there (cx-6k6cg).
  const escape = useEscapingList("top", 6);
  useEffect(() => {
    document.getElementById(`acpmux-mention-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [active]);
  // Chats can list before a word is typed; the files' state still says what the search is doing.
  const note = !state
    ? undefined
    : state.kind === "idle"
      ? t("files.hint")
      : state.kind === "failed"
        ? t("files.failed")
        : items.length === 0
          ? t(state.kind === "searching" ? "files.searching" : "files.none")
          : undefined;
  return (
    <PickerOptionList
      ref={escape}
      aria-label={t("files.search")}
      aria-busy={state?.kind === "searching"}
      className="ui-popup ui-glass acpmux-slash-menu acpmux-mention-menu"
      id="acpmux-mention-menu"
    >
      {items.map((item, index) => (
        <PickerOption
          key={item.key}
          id={`acpmux-mention-${index}`}
          type="button"
          // The prompt keeps focus (aria-activedescendant), so no row is a tab stop.
          active={false}
          selected={index === active}
          className={
            index === active
              ? "acpmux-slash-row acpmux-mention-row acpmux-slash-active"
              : "acpmux-slash-row acpmux-mention-row"
          }
          data-mention-kind={item.kind}
          onPointerMove={() => onHover(index)}
          // A mouse-down here would take focus from the prompt.
          onMouseDown={(event) => {
            event.preventDefault();
            onPick(item);
          }}
        >
          <span className="acpmux-mention-icon" data-mention-icon={item.kind}>
            <Icon name={item.kind === "session" ? "agent.chat" : item.kind} size={14} />
          </span>
          <span className="acpmux-slash-name">{runs(item.name)}</span>
          {item.kind === "session"
            ? item.project && <span className="acpmux-slash-description">{item.project}</span>
            : item.dir.length > 0 && <span className="acpmux-slash-description">{runs(item.dir)}</span>}
        </PickerOption>
      ))}
      {note && <output className="acpmux-file-note">{note}</output>}
    </PickerOptionList>
  );
}

function runs(parts: readonly Run[]) {
  return parts.map((part, index) => (part.matched ? <b key={index}>{part.text}</b> : part.text));
}
