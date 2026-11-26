// What the composer's @ picker lists (MentionMenu.tsx), as Codex's @ does: the plugins (computer use,
// browser use), another installed harness to ask, installed extensions' own items
// (`cmux.composer.mention/1`, composer/extensionMentions.ts; first when the word names their prefix,
// `@pr`), then folders and files of the chat's folder once the word is specific. No chats (Lucas
// 2026-11-21): a chat is found in the sidebar and All chats. Files come from the host's search
// (`file.search`, fileSearchModel.ts) with its ranking and matched letters; folders are matched here
// as the path picker's fuzzy filter ranks a name (viewer-empty/fuzzy.ts).
import { fuzzyScore } from "../../viewer-empty/fuzzy";
import { matchRuns, type FileMatch, type Run } from "./fileSearchModel";
import { mentionText } from "./mentionMenuModel";
import type { AcpmuxSnapshot } from "./model";
import { isModelRouterKind } from "./routerKinds";
import { TOOL_MENTIONS, toolMentionsFor, toolMentionsIn, type ToolMention, type ToolMentionId } from "./toolMentions";

/// The built-in tools' words (`@computer-use`, `@browser-use`) are theirs alone: a harness with the same id
/// is never a guest row nor a guest @ (its pick would write the tool's token and lose the tool's note).
const TOOL_IDS = new Set<string>(TOOL_MENTIONS.map((tool) => tool.id));
import type { ExtensionMention } from "./composer/extensionMentions";

export type MentionItem =
  | { kind: "harness"; key: string; harnessId: string; family?: string; name: Run[] }
  /** A built-in tool (toolMentions.ts), named from the pane's table (`toolName`). */
  | { kind: "tool"; key: string; toolId: ToolMentionId; icon: string; name: Run[] }
  | { kind: "folder" | "file"; key: string; path: string; name: Run[]; dir: Run[] }
  | { kind: "extension"; key: string; mention: ExtensionMention; name: Run[] };

/// How many extension items the picker lists.
export const MENTION_EXTENSION_ITEMS = 6;

/// How many folders the picker lists ahead of the files.
export const MENTION_FOLDERS = 3;
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
  if (!scope || item.kind === "harness" || item.kind === "tool" || item.kind === "extension") return;
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

/// A catalog row that can answer as a read-only guest: an installed agent harness the daemon
/// resolves by name. A folder's own profile is not one yet: the guest path resolves only the
/// global profiles (hq#8327).
export function canBeGuest(entry: AcpmuxSnapshot["catalog"][number]): boolean {
  return (
    Boolean(entry.id) &&
    entry.pickable !== false &&
    (!entry.unavailable || Boolean(entry.probeFailed)) &&
    entry.kind !== "terminal" &&
    entry.kind !== "unknown" &&
    !isModelRouterKind(entry.kind) &&
    entry.folder === undefined
  );
}

function harnessItems(catalog: readonly AcpmuxSnapshot["catalog"][number][], query: string): MentionItem[] {
  const ranked: { entry: AcpmuxSnapshot["catalog"][number]; score: number; indexes: number[]; label: string }[] = [];
  for (const entry of catalog) {
    if (!canBeGuest(entry) || TOOL_IDS.has(entry.id.toLowerCase())) continue;
    const label = entry.name?.trim() || entry.id;
    // A harness answers only to its own name's start: "@ini" is a file, never Gemini.
    const lower = query.toLowerCase();
    const named = label.toLowerCase().startsWith(lower);
    if (query && !named && !entry.id.toLowerCase().startsWith(lower)) continue;
    const indexes = query && named ? Array.from({ length: query.length }, (_, index) => index) : [];
    const score = query ? (entry.id.toLowerCase().startsWith(lower) ? 2 : 1) : 0;
    ranked.push({ entry, score, indexes, label });
  }
  ranked.sort((a, b) => b.score - a.score || a.entry.id.localeCompare(b.entry.id));
  return ranked.slice(0, 8).map(({ entry, indexes, label }) => ({
    kind: "harness",
    key: `harness:${entry.id}`,
    harnessId: entry.id,
    family: entry.family,
    name: textRuns(label, indexes),
  }));
}

/// The installed harness a send asks as a read-only guest, and the question it asks: the first
/// `@id` naming one outside code (a fenced block or an inline span is literal text, never a
/// mention). One guest per send: each guest request spends the send's one gesture. Only that
/// token leaves the question, so a file's `@path` and the rest of the text stay as written.
export function guestMention(
  text: string,
  catalog: readonly AcpmuxSnapshot["catalog"][number][],
): { harnessId: string; question: string } | undefined {
  const outsideCode = text.replace(/(```|~~~)[\s\S]*?(?:\1|$)|`[^`\n]*`/g, (code) => code.replace(/[^\n]/g, " "));
  for (const match of outsideCode.matchAll(/(^|\s)@([A-Za-z0-9_.:/-]+)(?=\s|$)/g)) {
    const id = match[2]!.toLowerCase();
    if (TOOL_IDS.has(id)) continue;
    const entry = catalog.find((candidate) => candidate.id.toLowerCase() === id && canBeGuest(candidate));
    if (!entry) continue;
    const start = match.index! + match[1]!.length;
    const question = `${text.slice(0, start)}${text.slice(start + 1 + match[2]!.length)}`.trim();
    return { harnessId: entry.id, question };
  }
  return undefined;
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

/// Whether a typed `@word` lists files (Lucas 2026-11-21, as Codex's @ lists them "only once you get very
/// specific"): it holds a `.` or `/` (`app.ts`, `src/`), or has at least MENTION_FILE_LETTERS letters. A
/// bare `@` or a short word lists the plugins only, and asks the host for no files.
export const MENTION_FILE_LETTERS = 4;
export function mentionWantsFiles(query: string): boolean {
  const text = query.trim();
  return /[./]/.test(text) || text.length >= MENTION_FILE_LETTERS;
}

/// Rows for the extension items the daemon matched (in its order), their label's matched letters bold.
function extensionItems(mentions: readonly ExtensionMention[], query: string): MentionItem[] {
  const word = query.includes(":") ? query.slice(query.indexOf(":") + 1) : query;
  return mentions.slice(0, MENTION_EXTENSION_ITEMS).map((mention) => ({
    kind: "extension",
    key: `extension:${mention.app}:${mention.prefix}:${mention.id}`,
    mention,
    name: textRuns(mention.label, (word && fuzzyIndices(word, mention.label)) || []),
  }));
}

/// The picker's rows for `query`: the plugins and harnesses, then extension items, then folders, then
/// the host's files in its order. A query with a `.` or `/` is a path (`app.ts`, `src/`), so its folders
/// and files come first. Extension items lead when the word names a provider (`extensionFirst`).
export function mentionItems({
  query,
  files,
  recent = [],
  harnesses = [],
  toolName = (tool) => tool.id,
  extension = [],
  extensionFirst = false,
}: {
  query: string;
  files: readonly FileMatch[];
  recent?: readonly RecentMention[];
  harnesses?: readonly AcpmuxSnapshot["catalog"][number][];
  /** A built-in tool's name in the app's language ("Computer use"). */
  toolName?: (tool: ToolMention) => string;
  extension?: readonly ExtensionMention[];
  extensionFirst?: boolean;
}): MentionItem[] {
  const text = query.trim();
  const wantsFiles = mentionWantsFiles(text);
  const harnessRows = text ? harnessItems(harnesses, text) : [];
  // The built-in tools show for a bare @ too (CMUX-682: always offered, set up or not).
  const toolRows = toolMentionsFor(text).map((tool): MentionItem => {
    const label = toolName(tool);
    const named = text && label.toLowerCase().startsWith(text.toLowerCase());
    const indexes = named ? Array.from({ length: text.length }, (_, index) => index) : [];
    return { kind: "tool", key: `tool:${tool.id}`, toolId: tool.id, icon: tool.icon, name: textRuns(label, indexes) };
  });
  const known = new Set(files.map((file) => file.path));
  const matching = (entry: RecentMention) => !text || fuzzyIndices(text, entry.path) !== undefined;
  const recentFiles = recent
    .filter((entry) => entry.kind === "file" && !known.has(entry.path) && matching(entry))
    .map((entry): FileMatch => ({ path: entry.path, ...(text ? { matches: fuzzyIndices(text, entry.path) } : {}) }));
  // A bare @ leads with recent picks; once there is a query, the host's own results come first.
  const allFiles = text ? [...files, ...recentFiles] : [...recentFiles, ...files];
  const searchedFolders = folderItems(allFiles, text);
  const shownFolders = new Set(searchedFolders.flatMap((item) => (item.kind === "folder" ? [item.path] : [])));
  const recentFolders = recent
    .filter((entry) => entry.kind === "folder" && !shownFolders.has(entry.path) && matching(entry))
    .map((entry): MentionItem => {
      const indexes = text ? fuzzyIndices(text, entry.path) : undefined;
      return { kind: "folder", key: `folder:${entry.path}`, path: entry.path, ...matchRuns(entry.path, indexes) };
    });
  // A short word lists only a file or folder it names exactly (`@go`, a root file `go`): specific
  // enough, while a short word's partial matches would bury the plugins.
  const exactly = (path: string) =>
    (path.replace(/\/$/, "").split("/").pop() ?? "").toLowerCase() === text.toLowerCase();
  const paths = !wantsFiles
    ? text
      ? [
          ...[...searchedFolders, ...recentFolders].filter((item) => item.kind === "folder" && exactly(item.path)),
          ...allFiles
            .filter((file) => exactly(file.path))
            .map((file): MentionItem => ({
              kind: "file",
              key: `file:${file.path}`,
              path: file.path,
              ...matchRuns(file.path, file.matches),
            })),
        ]
      : []
    : [
        ...(text ? [...searchedFolders, ...recentFolders] : [...recentFolders, ...searchedFolders]),
        ...allFiles.map((file): MentionItem => ({
          kind: "file",
          key: `file:${file.path}`,
          path: file.path,
          ...matchRuns(file.path, file.matches),
        })),
      ];
  const extensionRows = extensionItems(extension, text);
  if (extensionFirst) return [...extensionRows, ...toolRows, ...harnessRows, ...paths];
  if (/[./]/.test(text)) return [...paths, ...toolRows, ...harnessRows, ...extensionRows];
  // The plugins lead, typed word or not, as Codex's @ lists them first (Lucas 2026-11-21): `@c` is
  // Computer Use before a guest harness; files follow, and a word that names no plugin lists only them.
  return [...toolRows, ...harnessRows, ...extensionRows, ...paths];
}

/// The row Return or Tab picks: the one the person moved to (by key, so it stays put when the
/// files land around it), else the first. While the files for the word are still on their way, the
/// first row that is not an extension's item, unless the word named its provider (`@pr`,
/// `providerAsked`), else the first: a listed row is always chosen, so Return never falls through to
/// send. -1: no rows.
export function mentionSelection(
  items: readonly MentionItem[],
  activeKey: string | undefined,
  pending = false,
  providerAsked = false,
) {
  const chosen = activeKey === undefined ? -1 : items.findIndex((item) => item.key === activeKey);
  if (chosen >= 0) return chosen;
  if (items.length === 0) return -1;
  return pending
    ? Math.max(
        0,
        items.findIndex((item) => item.kind !== "extension" || providerAsked),
      )
    : 0;
}

/// What a pick writes in place of the `@word`: a file's or folder's `@path ` (a folder's with its
/// slash), which the agent CLIs read as a path in the chat's folder; a plugin's or harness's `@name `.
export function mentionInsert(item: MentionItem): { markdown: string; shown: string } {
  if (item.kind === "harness") return mentionText(item.harnessId);
  if (item.kind === "tool") return mentionText(item.toolId);
  // An extension's item writes its own text (a PR's link and title, a ticket), not an `@` path.
  if (item.kind === "extension") {
    const shown = `${item.mention.insert.replace(/\s+/g, " ").trim()} `;
    // Inline marks are escaped as a chat's are; a start that reads as a block (`> `, `- `, `1. `,
    // `# `, `+ `) is escaped too, since the pick can sit at the start of a line.
    const markdown = shown
      .replace(/[\\`*_[\]~<&]/g, "\\$&")
      .replace(/^(#{1,6}|[>+-])(?= )/, "\\$1")
      .replace(/^(\d+)([.)])(?= )/, "$1\\$2");
    return { markdown, shown };
  }
  const path = mentionPath(item.path);
  return mentionText(item.kind === "folder" ? `${path}/` : path);
}

/// A root file or folder named like a built-in tool (`computer-use`) goes as `./computer-use`, so the
/// send never reads it as the tool's word: the @ picker and Search Files both write it so.
export function mentionPath(path: string): string {
  // As the send reads it: `computer-use`, `computer-use,notes.md` would name the tool, `computer-use.md` not.
  return toolMentionsIn(`@${path}`).length > 0 ? `./${path}` : path;
}
