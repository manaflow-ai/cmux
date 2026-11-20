// What a finished read, text search or file search found, read out of its result text so the opened
// call draws it as a card (FileResultCard.tsx) instead of raw text: a Read as its file, line range
// and lines; a Grep, Glob or list as its files, each with its matching lines. Picked off the call's
// canonical tool (toolNames.ts), never its title, so every harness's read and search draw alike.
// Result text a card cannot read whole (a summary line it does not know, prose) is left to the
// generic body (ToolDetail.tsx): a card never drops lines it did not understand.
import type { AcpmuxActivity } from "../model";
import { canonicalCall } from "../toolNames";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// A read file: its path, the first and last line shown, and the lines without their numbers.
export type ReadPeek = { path: string; start: number; end: number; code: string };

/// One matching line of a file; `line` when the result numbered it.
export type SearchMatch = { line?: number; text: string };

/// One file a search named: its path as given, as the card names it (without the folder every file of
/// the result shares), the path to open (absolute where the session's folder is known), its matching
/// lines, and the count a count-only search gave.
export type SearchFile = {
  path: string;
  shown: string;
  open: string;
  matches: SearchMatch[];
  count?: number;
};

/// A search's files in result order, how many lines matched, and whether the harness cut it short.
export type SearchResult = { files: SearchFile[]; matches: number; truncated: boolean };

export type FileCard =
  | { kind: "read"; read: ReadPeek }
  | { kind: "search"; tool: "search" | "glob" | "list"; result: SearchResult };

/// Claude Code numbers a Read's lines `     1→text`, or `1\ttext` (cat -n). The tab form is read only
/// from Claude's own Read (`file_path` in its input): another harness's read of a TSV file keeps its
/// first column.
const NUMBERED = /^\s*(\d+)→(.*)$/;
const TAB_NUMBERED = /^\s*(\d+)\t(.*)$/;
/// `sed -n 120,160p file`, as Codex reads a range.
const SED_RANGE = /\bsed\s+-n\s+['"]?(\d+)(?:,(\d+))?p/;

/// The card a finished call's result draws as, or undefined to draw the generic body. `text` is the
/// result as the row shows it (toolResult.ts); `cwd` resolves the relative paths a search prints.
export function fileCard(tool: Tool, text: string | undefined, cwd?: string): FileCard | undefined {
  if (tool.status !== "completed" || !text?.trim()) return undefined;
  const call = canonicalCall(tool);
  if (!call) return undefined;
  if (call.tool === "read") {
    const tabs = /"file_path"\s*:/.test(tool.inputSummary ?? "");
    const read = call.input.path ? readPeek(call.input.path, text, startOf(tool, call.input.command), tabs) : undefined;
    return read && { kind: "read", read };
  }
  if (call.tool === "search" || call.tool === "glob" || call.tool === "list") {
    // A Glob or listing prints only paths, as does a Grep that says "Found N files" (Claude's default).
    const filesOnly = call.tool !== "search" || FOUND_FILES.test(text.trimStart());
    const result = searchResult(text, inputCwd(tool) ?? cwd, filesOnly);
    return result && { kind: "search", tool: call.tool, result };
  }
  return undefined;
}

/// A read's lines: numbered lines lose their numbers and start where they say; plain lines start at
/// the line the call asked for (Claude's `offset`, Codex's `sed -n A,Bp`), else 1.
export function readPeek(path: string, text: string, from = 1, tabs = true): ReadPeek | undefined {
  const lines = text.replace(/\n+$/, "").split("\n");
  const numbered = lines.map((line) => line.match(NUMBERED) ?? (tabs ? line.match(TAB_NUMBERED) : null));
  if (numbered.every(Boolean)) {
    const start = Number(numbered[0]![1]);
    // Numbers that skip or repeat are not a file's lines but text that happens to start with digits.
    if (numbered.every((match, index) => Number(match![1]) === start + index))
      return {
        path,
        start,
        end: start + lines.length - 1,
        code: numbered.map((match) => match![2]).join("\n"),
      };
  }
  // Mostly numbered lines that do not count up are a listing, not a file's lines: no card.
  const counted = numbered.filter(Boolean).length;
  if (counted > 0 && counted >= lines.length - 1) return undefined;
  return { path, start: from, end: from + lines.length - 1, code: lines.join("\n") };
}

/// Lines of a search's result that say something about it rather than name a match.
const FOUND_FILES = /^Found \d+ files?\b/;
const FOUND_TOTAL = /^Found \d+ total occurrences?\b/;
const NONE = /^No (?:files|matches) found\b/;
const TRUNCATED = /^\(Results are truncated\b/;
/// `path:12:text` (grep -n, rg), `path:text` (rg without numbers), `path:3` (a count), `12:text` (rg
/// --heading, under its file), and a bare path (files with matches, Glob, a listing).
const LINE_MATCH = /^(.+?):(\d+):(.*)$/;
const COUNT = /^(.+?):(\d+)$/;
const HEADING_MATCH = /^(\d+)[:-](.*)$/;
/// A file name without an extension or folder, as a Glob prints one at the root.
const NAME = /^[\w.-]+$/;
const TEXT_MATCH = /^([^:\s]+\.[A-Za-z0-9]{1,12}):(.*)$/;

/// A search's files and matches, or undefined when any line is neither a match, a path nor a summary
/// line it knows, or names no file. `filesOnly` (a Glob or a listing, which print only paths) also
/// takes a bare name with no extension (`LICENSE`, `Makefile`).
export function searchResult(text: string, cwd?: string, filesOnly = false): SearchResult | undefined {
  const files = new Map<string, SearchFile>();
  let truncated = false;
  let heading: SearchFile | undefined;
  const file = (path: string) => {
    let entry = files.get(path);
    if (!entry) files.set(path, (entry = { path, shown: path, open: resolve(path, cwd), matches: [] }));
    return entry;
  };
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\s+$/, "");
    if (!line || line === "--" || FOUND_FILES.test(line) || FOUND_TOTAL.test(line) || NONE.test(line)) {
      if (!line) heading = undefined;
      continue;
    }
    if (TRUNCATED.test(line)) {
      truncated = true;
      continue;
    }
    let match: RegExpMatchArray | null;
    if ((match = line.match(LINE_MATCH)) && isPath(match[1]!)) {
      file(match[1]!).matches.push({ line: Number(match[2]), text: match[3]!.trim() });
    } else if ((match = line.match(COUNT)) && isPath(match[1]!)) {
      file(match[1]!).count = Number(match[2]);
    } else if (heading && (match = line.match(HEADING_MATCH))) {
      // A context line (`12-text`) under its heading is not a match.
      if (line[match[1]!.length] === ":") heading.matches.push({ line: Number(match[1]), text: match[2]!.trim() });
    } else if ((match = line.match(TEXT_MATCH))) {
      file(match[1]!).matches.push({ text: match[2]!.trim() });
    } else if (isPath(line) || (filesOnly && NAME.test(line))) {
      heading = file(line);
    } else {
      return undefined;
    }
  }
  const list = [...files.values()];
  // An empty search keeps its own words ("No files found") in the generic body.
  if (!list.length) return undefined;
  const shared = sharedFolder(list.map((entry) => entry.path));
  for (const entry of list) entry.shown = entry.path.slice(shared.length);
  const matches = list.reduce((sum, entry) => sum + (entry.count ?? entry.matches.length), 0);
  return { files: list, matches, truncated };
}

/// One path on its own: no white space, and a folder or an extension in it. A path with a space in
/// it leaves the result to the generic body rather than be read as a match's text.
function isPath(text: string): boolean {
  if (!text || /\s/.test(text) || /^\d+$/.test(text)) return false;
  return /\//.test(text) || /^[^\s/]+\.[A-Za-z0-9]{1,12}$/.test(text);
}

/// The path to open: as given when absolute or from home, else under the session's folder.
function resolve(path: string, cwd: string | undefined): string {
  if (path.startsWith("/") || path.startsWith("~") || !cwd) return path;
  return `${cwd.replace(/\/+$/, "")}/${path.replace(/^\.\//, "")}`;
}

/// The folder a call ran in, when its input says (Codex's `cwd`).
function inputCwd(tool: Tool): string | undefined {
  try {
    const input: unknown = tool.inputSummary ? JSON.parse(tool.inputSummary) : undefined;
    const cwd = input && typeof input === "object" ? (input as Record<string, unknown>).cwd : undefined;
    return typeof cwd === "string" && cwd.startsWith("/") ? cwd : undefined;
  } catch {
    return undefined;
  }
}

/// The line a read asked to start at: Claude's `offset`, or Codex's `sed -n A,Bp` range.
function startOf(tool: Tool, command: string | undefined): number {
  const sed = (command ?? tool.inputSummary ?? "").match(SED_RANGE);
  if (sed) return Number(sed[1]);
  try {
    const input: unknown = tool.inputSummary ? JSON.parse(tool.inputSummary) : undefined;
    const offset = input && typeof input === "object" ? (input as Record<string, unknown>).offset : undefined;
    return typeof offset === "number" && offset > 0 ? Math.floor(offset) : 1;
  } catch {
    return 1;
  }
}

/// The folder every path starts with, through its last `/` ("" when they share none): a result's
/// paths drop it, so `/home/me/app/src/a.ts` and `…/src/b.ts` read `a.ts` and `b.ts`.
function sharedFolder(paths: string[]): string {
  let prefix = paths[0] ?? "";
  for (const path of paths) while (prefix && !path.startsWith(prefix)) prefix = prefix.slice(0, -1);
  return prefix.slice(0, prefix.lastIndexOf("/") + 1);
}

/// What Find reads of a card: a read's lines (its numbers are a gutter it skips); a search's paths as
/// shown, each followed by its matching lines' text. The file name over a read and the counts over a
/// search are labels it skips.
export function fileCardText(card: FileCard): string {
  if (card.kind === "read") return card.read.code;
  return card.result.files.flatMap((entry) => [entry.shown, ...entry.matches.map((match) => match.text)]).join("\n");
}
