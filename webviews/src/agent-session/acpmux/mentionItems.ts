// What the composer's @ picker lists (MentionMenu.tsx), the way Claude desktop's does: other chats
// by title, then folders, then files of the chat's folder. Files come from the host's search
// (`file.search`, fileSearchModel.ts) with its ranking and matched letters; chats and folders are
// matched here, as the path picker's fuzzy filter ranks a name (viewer-empty/fuzzy.ts).
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

/// The indexes of `text` that `query` matches, case aside: its first run as written, else its
/// characters in order (greedy, the way the host's file search marks a path). Undefined when it
/// does not match; an empty query matches with none.
export function fuzzyIndices(query: string, text: string): number[] | undefined {
  const q = query.toLowerCase();
  const t = text.toLowerCase();
  if (!q) return [];
  const at = t.indexOf(q);
  if (at >= 0) return Array.from(q, (_, offset) => at + offset);
  const out: number[] = [];
  let from = 0;
  for (const char of q) {
    const index = t.indexOf(char, from);
    if (index < 0) return undefined;
    out.push(index);
    from = index + 1;
  }
  return out;
}

const titleOf = (entry: AcpmuxSessionEntry) => entry.displayTitle?.trim() || sessionTitle(entry);

/// Other listed chats whose title matches `query`, best first; for no query, the most recent.
function sessionItems(
  sessions: readonly AcpmuxSessionEntry[],
  chatId: string | undefined,
  query: string,
): MentionItem[] {
  const ranked: { entry: AcpmuxSessionEntry; title: string; score: number }[] = [];
  for (const entry of sessions) {
    if (entry.sessionId === chatId || !listed(entry)) continue;
    const title = titleOf(entry);
    const score = query ? fuzzyScore(query, title) : (entry.updatedAt ?? 0);
    if (score != null) ranked.push({ entry, title, score });
  }
  ranked.sort((a, b) => b.score - a.score);
  return ranked.slice(0, MENTION_SESSIONS).map(({ entry, title }) => ({
    kind: "session",
    key: `session:${entry.sessionId}`,
    sessionId: entry.sessionId,
    title,
    project: entry.cwd && !isAgentHome(entry.cwd) ? projectLabel(entry.cwd) : undefined,
    name: textRuns(title, fuzzyIndices(query, title)),
  }));
}

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

/// The picker's rows for `query`: chats, then folders, then the host's files in its order.
export function mentionItems({
  query,
  files,
  sessions,
  chatId,
}: {
  query: string;
  files: readonly FileMatch[];
  sessions: readonly AcpmuxSessionEntry[];
  chatId?: string;
}): MentionItem[] {
  const text = query.trim();
  return [
    ...sessionItems(sessions, chatId, text),
    ...folderItems(files, text),
    ...files.map((file): MentionItem => ({
      kind: "file",
      key: `file:${file.path}`,
      path: file.path,
      ...matchRuns(file.path, file.matches),
    })),
  ];
}

/// What a pick writes in place of the `@word`: a file's or folder's `@path ` (a folder's with its
/// slash), which the agent CLIs read as a path in the chat's folder; a chat's title and full id,
/// which an agent can look up with cmux and the transcript links (#22055).
export function mentionInsert(item: MentionItem): { markdown: string; shown: string } {
  if (item.kind !== "session") return mentionText(item.kind === "folder" ? `${item.path}/` : item.path);
  const shown = `cmux session "${item.title}" (${item.sessionId}) `;
  return { markdown: shown.replace(/[\\`*_[\]~<]/g, "\\$&"), shown };
}
