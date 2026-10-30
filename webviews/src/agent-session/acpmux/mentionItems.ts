// What the composer's @ picker lists (MentionMenu.tsx), the way Claude desktop's does: other chats
// by title, then folders, then files of the chat's folder. Files come from the host's search
// (`file.search`, fileSearchModel.ts) with its ranking and matched letters; folders are matched
// here as the path picker's fuzzy filter ranks a name (viewer-empty/fuzzy.ts), and chats by a word
// of their title (titleMatch).
import { fuzzyScore } from "../../viewer-empty/fuzzy";
import { matchRuns, type FileMatch, type Run } from "./fileSearchModel";
import { mentionText } from "./MentionMenu";
import { isAgentHome, listed, projectLabel, sessionTitle, type AcpmuxSessionEntry } from "./sessionList";

export type MentionItem =
  | { kind: "session"; key: string; sessionId: string; title: string; project?: string; name: Run[] }
  | { kind: "folder" | "file"; key: string; path: string; name: Run[]; dir: Run[] };

/// How many chats and folders the picker lists ahead of the files.
export const MENTION_SESSIONS = 5;
export const MENTION_FOLDERS = 3;

/// How much of a chat's title a word is matched against: a chat named for its first prompt has the
/// whole prompt as its title, and a word deep in it says little about the chat.
export const MENTION_TITLE_CHARS = 100;
const RECENT_MENTION_PATHS_KEY = "cmux.acpmux.recentMentionPaths";
const RECENT_MENTION_PATHS_LIMIT = 12;

/// A file or folder picked from the @ menu, kept for the next bare `@` in the same project.
export type RecentMention = { kind: "file" | "folder"; path: string };

/// Recent paths are local UI memory, never sent to the host. They are kept per project folder on
/// its host (`scope`): a relative path means nothing in another folder or on another machine.
function recentKey(scope: string): string {
  return `${RECENT_MENTION_PATHS_KEY}:${scope}`;
}

/// The project a chat's recent picks belong to: its host and folder. Undefined: none are kept.
export function recentMentionScope(cwd: string | undefined, host: string | undefined): string | undefined {
  return cwd ? JSON.stringify([host ?? "local", cwd]) : undefined;
}

export function loadRecentMentionPaths(scope: string | undefined): RecentMention[] {
  if (!scope) return [];
  try {
    const value: unknown = JSON.parse(localStorage.getItem(recentKey(scope)) ?? "[]");
    if (!Array.isArray(value)) return [];
    return value
      .filter(
        (entry): entry is RecentMention =>
          typeof entry === "object" &&
          entry !== null &&
          (entry.kind === "file" || entry.kind === "folder") &&
          typeof entry.path === "string" &&
          entry.path.length > 0,
      )
      .slice(0, RECENT_MENTION_PATHS_LIMIT);
  } catch {
    return [];
  }
}

export function rememberMentionPath(scope: string | undefined, item: MentionItem): void {
  if (!scope || item.kind === "session") return;
  const picked: RecentMention = { kind: item.kind, path: item.path };
  const next = [
    picked,
    ...loadRecentMentionPaths(scope).filter((entry) => entry.kind !== picked.kind || entry.path !== picked.path),
  ].slice(0, RECENT_MENTION_PATHS_LIMIT);
  try {
    localStorage.setItem(recentKey(scope), JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the picker functional without recents.
  }
}

/// `text` lowercased a character at a time, with the string index in `text` of the character each
/// of its units comes from. Some characters lowercase to more units than they take (`İ` is one
/// unit, `i̇` two), so an index into `text.toLowerCase()` is not one into `text`.
function folded(text: string): { text: string; at: number[] } {
  let out = "";
  const at: number[] = [];
  let index = 0;
  for (const char of text) {
    const lower = char.toLowerCase();
    out += lower;
    for (let unit = 0; unit < lower.length; unit++) at.push(index);
    index += char.length;
  }
  return { text: out, at };
}

/// Adds to `out` the string indexes in `text` of the characters that units `start` to `end` of its
/// fold come from, every unit of each, so a row bolds a character outside the BMP (an emoji) whole.
function unfold(text: string, fold: { at: number[] }, start: number, end: number, out: Set<number>) {
  for (let unit = start; unit < end; unit++) {
    const first = fold.at[unit]!;
    out.add(first);
    if (text.codePointAt(first)! > 0xffff) out.add(first + 1);
  }
}

const ascending = (indexes: Set<number>) => [...indexes].sort((a, b) => a - b);

/// The string indexes of `text` that `query` matches, case aside: its first run as written, else
/// its characters in order (greedy, the way the host's file search marks a path). An emoji covers
/// both of its string units, so a row bolds it whole and the letters after it stay where they are.
/// Undefined when it does not match; an empty query matches with none.
export function fuzzyIndices(query: string, text: string): number[] | undefined {
  const q = folded(query).text;
  if (!q) return [];
  const t = folded(text);
  const out = new Set<number>();
  const at = t.text.indexOf(q);
  if (at >= 0) {
    unfold(text, t, at, at + q.length, out);
    return ascending(out);
  }
  let from = 0;
  for (const char of q) {
    const index = t.text.indexOf(char, from);
    if (index < 0) return undefined;
    unfold(text, t, index, index + char.length, out);
    from = index + char.length;
  }
  return ascending(out);
}

/// Whether a word starts at string index `index` of `text`: at its start, after a character that
/// is not a letter or digit, or at a lower-to-upper case change (`fileSearch`).
function wordStart(text: string, index: number): boolean {
  if (index === 0) return true;
  const before = text[index - 1]!;
  if (!/[\p{L}\p{N}]/u.test(before)) return true;
  const char = text[index]!;
  return before !== before.toUpperCase() && char !== char.toLowerCase();
}

/// How well `query` names a chat titled `title`, and its letters there. It matches only as one run
/// that starts a word in the title's first MENTION_TITLE_CHARS: a chat named for its first prompt
/// holds most short queries (`app`, `ts`) as letters in order, which says nothing of the chat. A
/// title that starts with the query ranks first, then one with it in an earlier word. Undefined
/// when it does not match.
export function titleMatch(query: string, title: string): { score: number; indexes: number[] } | undefined {
  const q = folded(query).text;
  if (!q) return { score: 0, indexes: [] };
  const head = title.slice(0, MENTION_TITLE_CHARS);
  const t = folded(head);
  for (let at = t.text.indexOf(q); at >= 0; at = t.text.indexOf(q, at + 1)) {
    const index = t.at[at]!;
    // Not from the middle of one character's lowercase (the dot of `i̇`), and at a word's start.
    if ((at > 0 && t.at[at - 1] === index) || !wordStart(head, index)) continue;
    const indexes = new Set<number>();
    unfold(head, t, at, at + q.length, indexes);
    return { score: index === 0 ? MENTION_TITLE_CHARS : MENTION_TITLE_CHARS - 1 - index, indexes: ascending(indexes) };
  }
  return undefined;
}

/// A chat's title on one line: a custom name may hold newlines, which would turn the inserted
/// mention into markdown blocks (a heading, a list) and move the caret off its paragraph.
const titleOf = (entry: AcpmuxSessionEntry) =>
  (entry.displayTitle?.trim() || sessionTitle(entry)).replace(/\s+/g, " ").trim();

/// Other listed chats whose title matches `query`, best first; for no query, the most recent.
function sessionItems(
  sessions: readonly AcpmuxSessionEntry[],
  chatId: string | undefined,
  query: string,
): MentionItem[] {
  // One pass that keeps only the best MENTION_SESSIONS (ties keep history order): typing runs this
  // on every key over the whole chat history, so it never sorts the history.
  const ranked: { entry: AcpmuxSessionEntry; title: string; score: number; indexes: number[] }[] = [];
  for (const entry of sessions) {
    if (entry.sessionId === chatId || !listed(entry)) continue;
    const title = titleOf(entry);
    const match = query ? titleMatch(query, title) : { score: entry.updatedAt ?? 0, indexes: [] };
    if (!match) continue;
    const { score, indexes } = match;
    if (ranked.length === MENTION_SESSIONS && score <= ranked[ranked.length - 1]!.score) continue;
    let at = ranked.length;
    while (at > 0 && ranked[at - 1]!.score < score) at--;
    ranked.splice(at, 0, { entry, title, score, indexes });
    if (ranked.length > MENTION_SESSIONS) ranked.pop();
  }
  return ranked.map(({ entry, title, indexes }) => ({
    kind: "session",
    key: `session:${entry.sessionId}`,
    sessionId: entry.sessionId,
    title,
    project: entry.cwd && !isAgentHome(entry.cwd) ? projectLabel(entry.cwd) : undefined,
    name: textRuns(title, indexes),
  }));
}

/// Whether any chat other than `chatId` can be offered.
export const hasOtherChats = (sessions: readonly AcpmuxSessionEntry[], chatId: string | undefined) =>
  sessions.some((entry) => entry.sessionId !== chatId && listed(entry));

/// `text` as runs marked matched or not, without splitting it at a slash as a path is.
function textRuns(text: string, indexes: readonly number[] = []): Run[] {
  const hit = new Set(indexes);
  const out: Run[] = [];
  for (let index = 0; index < text.length; index++) {
    const matched = hit.has(index);
    const last = out[out.length - 1];
    if (last && last.matched === matched) last.text += text[index];
    else out.push({ text: text[index]!, matched });
  }
  return out;
}

/// The folders of the found files whose own name matches `query`, best first.
function folderItems(files: readonly FileMatch[], query: string): MentionItem[] {
  if (!query) return [];
  const seen = new Set<string>();
  const ranked: { path: string; score: number; order: number }[] = [];
  for (const file of files) {
    const parts = file.path.split("/").slice(0, -1);
    for (let depth = 1; depth <= parts.length; depth++) {
      const path = parts.slice(0, depth).join("/");
      if (seen.has(path)) continue;
      seen.add(path);
      const score = fuzzyScore(query, parts[depth - 1]!);
      if (score != null) ranked.push({ path, score, order: ranked.length });
    }
  }
  ranked.sort((a, b) => b.score - a.score || a.order - b.order);
  return ranked.slice(0, MENTION_FOLDERS).map(({ path }) => {
    const slash = path.lastIndexOf("/");
    const indexes = fuzzyIndices(query, path.slice(slash + 1))!.map((index) => index + slash + 1);
    return { kind: "folder", key: `folder:${path}`, path, ...matchRuns(path, indexes) };
  });
}

/// The picker's rows for `query`: chats, then folders, then the host's files in its order. A query
/// with a `.` or `/` is a path (`app.ts`, `src/`), so its folders and files come before the chats.
export function mentionItems({
  query,
  files,
  sessions,
  chatId,
  recent = [],
}: {
  query: string;
  files: readonly FileMatch[];
  sessions: readonly AcpmuxSessionEntry[];
  chatId?: string;
  recent?: readonly RecentMention[];
}): MentionItem[] {
  const text = query.trim();
  const chats = sessionItems(sessions, chatId, text);
  const known = new Set(files.map((file) => file.path));
  const matching = (entry: RecentMention) => !text || fuzzyIndices(text, entry.path) !== undefined;
  const recentFiles = recent
    .filter((entry) => entry.kind === "file" && !known.has(entry.path) && matching(entry))
    .map((entry): FileMatch => ({ path: entry.path, ...(text ? { matches: fuzzyIndices(text, entry.path) } : {}) }));
  // A bare @ leads with recent picks; once there is a query, the host's own results come first.
  const allFiles = text ? [...files, ...recentFiles] : [...recentFiles, ...files];
  const searchedFolders = folderItems(allFiles, text);
  const shownFolders = new Set(searchedFolders.flatMap((item) => (item.kind === "session" ? [] : [item.path])));
  const recentFolders = recent
    .filter((entry) => entry.kind === "folder" && !shownFolders.has(entry.path) && matching(entry))
    .map((entry): MentionItem => {
      const indexes = text ? fuzzyIndices(text, entry.path) : undefined;
      return { kind: "folder", key: `folder:${entry.path}`, path: entry.path, ...matchRuns(entry.path, indexes) };
    });
  const paths = [
    ...(text ? [...searchedFolders, ...recentFolders] : [...recentFolders, ...searchedFolders]),
    ...allFiles.map((file): MentionItem => ({
      kind: "file",
      key: `file:${file.path}`,
      path: file.path,
      ...matchRuns(file.path, file.matches),
    })),
  ];
  return /[./]/.test(text) ? [...paths, ...chats] : [...chats, ...paths];
}

/// The row Return or Tab picks: the one the person moved to (by key, so it stays put when the
/// files land around it), else the first. While the files for the word are still on their way, a
/// chat is not picked unasked: a quick `@app⏎` means the file, which lists a moment later. -1: none.
export function mentionSelection(items: readonly MentionItem[], activeKey: string | undefined, pending: boolean) {
  const chosen = activeKey === undefined ? -1 : items.findIndex((item) => item.key === activeKey);
  if (chosen >= 0) return chosen;
  return pending ? items.findIndex((item) => item.kind !== "session") : items.length > 0 ? 0 : -1;
}

/// What a pick writes in place of the `@word`: a file's or folder's `@path ` (a folder's with its
/// slash), which the agent CLIs read as a path in the chat's folder; a chat's title, quoted as a
/// JSON string so a `"` in it does not end it, and full id, which an agent can look up with cmux
/// and the transcript links (#22055).
export function mentionInsert(item: MentionItem): { markdown: string; shown: string } {
  if (item.kind !== "session") return mentionText(item.kind === "folder" ? `${item.path}/` : item.path);
  const shown = `cmux session ${JSON.stringify(item.title)} (${item.sessionId}) `;
  return { markdown: shown.replace(/[\\`*_[\]~<&]/g, "\\$&"), shown };
}
