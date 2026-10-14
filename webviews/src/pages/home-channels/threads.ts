// A thread as an object: a title, a status (open or resolved) and an owner. The page reads every
// field through `threadMeta`, the one place that knows where they come from.
// PLACEHOLDER until the owner keeps threads as objects (hqec-threadobj): the title is the root's
// first line, the owner is the root's author, and the status is open unless this page resolved it
// in this visit (`overrides`, view state; not stored). Wiring the owner's fields is one change here.
import { messageText } from "./model";
import type { HomeMessage } from "./types";

export type ThreadStatus = "open" | "resolved";

export interface ThreadMeta {
  root: string;
  title: string;
  status: ThreadStatus;
  /** The participant id that owns the thread. */
  owner: string;
}

const TITLE_MAX = 72;

/** A short title from the root's text: its first line, without Markdown marks, cut at a word. */
export function titleFrom(text: string): string {
  const line =
    text
      .split("\n")
      .map((part) => part.replace(/[*_`#>~]/g, "").trim())
      .find(Boolean) ?? "";
  if (line.length <= TITLE_MAX) return line;
  const cut = line.slice(0, TITLE_MAX);
  const space = cut.lastIndexOf(" ");
  return `${(space > 40 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

export function threadMeta(root: HomeMessage, overrides: ReadonlyMap<string, ThreadStatus>): ThreadMeta {
  return {
    root: root.id,
    title: titleFrom(messageText(root)),
    status: overrides.get(root.id) ?? "open",
    owner: root.author,
  };
}
