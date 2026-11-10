import { useEffect, useRef, useState } from "react";
import { readFileSearch, type FileMatch, type FileSearchSource } from "./fileSearchModel";

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
  // A mention never spans a line, so only the caret's line is read: per key, not per draft.
  const line = markdown.lastIndexOf("\n", at - 1) + 1;
  const before = markdown.slice(line, at);
  const found = /(^|\s|&#x20;|&#32;|&nbsp;)@((?:\\.|(?!&#x20;|&#32;|&nbsp;)[^\s\\@])*)$/i.exec(before);
  if (!found) return undefined;
  const start = line + before.length - found[2]!.length - 1;
  // An odd number of backticks before it: inside a code span.
  if ((markdown.slice(0, start).match(/`/g)?.length ?? 0) % 2 === 1) return undefined;
  return { start, query: found[2]!.replace(/\\(.)/g, "$1") };
}

/// Where the caret, counted in the characters the prompt shows, falls in its markdown: a
/// backslash escape and a character reference (the serializer's `&#x20;`) each show as one, and so
/// does an attachment placed in the text: the editor counts its atom as one place, the markdown
/// holds its whole token (attachments.ts inlineToken).
/// The prompt's every render asks this for the caret, so it runs over the plain stretches between
/// escapes natively: a caret at the end of a 200,000-character draft took one regex per character.
const ESCAPE_START = /[\\&\uFFFC]/g;
const ESCAPE = /\\[!-/:-@[-`{-~]|&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);|\uFFFC[\w.~%-]+\uFFFC/iy;
// perf-hot: 1ms composer-draft-typing
export function markdownOffset(markdown: string, shown: number): number {
  let index = 0;
  let count = 0;
  while (count < shown && index < markdown.length) {
    // Only `\`, `&` and U+FFFC can start an escape: every character before the next one shows as one.
    ESCAPE_START.lastIndex = index;
    const next = ESCAPE_START.exec(markdown)?.index ?? markdown.length;
    if (next - index >= shown - count) return index + (shown - count);
    count += next - index;
    index = next;
    if (index >= markdown.length) break;
    ESCAPE.lastIndex = index;
    index += ESCAPE.exec(markdown)?.[0].length ?? 1;
    count += 1;
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
