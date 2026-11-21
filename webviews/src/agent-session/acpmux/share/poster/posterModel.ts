// What a run's poster shows (Share poster…, PosterDialog.tsx): the prompt that started the chat's
// last finished turn, a glimpse of its diff (files changed, the plus and minus counts, up to four
// short hunks), a before and an after picture when the turn had them, the harness and model, and
// how long the turn took. Pure: the dialog builds it once on open, never per token.
//
// Constant cost whatever the chat's length: the turn is found by walking back from the end to its
// prompt, so only that turn's rows are read, and the poster draws a fixed number of lines.
//
// Nothing secret leaves: env-like assignments, tokens and keys become •••, and a path outside the
// chat's folder becomes …; a file outside the folder counts but shows no hunk.
import { endsTurn, turnFiles, type DiffLine, type TurnFile } from "../../diff";
import type { AcpmuxRow } from "../../model";
import { opensTurn } from "../../turnStart";

export const POSTER_WIDTH = 1200;
export const POSTER_HEIGHT = 800;

/// Lines and widths the poster draws at most: the layout's fixed slots (Poster.tsx).
export const PROMPT_LINES = 4;
export const HUNKS = 4;
export const HUNK_LINES = 5;
export const HUNK_CHARS = 54;

export type PosterLine = { type: DiffLine["type"]; text: string };
export type PosterHunk = { path: string; lines: PosterLine[] };
export type PosterShots = { before?: string; after?: string };

export type PosterData = {
  prompt: string;
  /// The agent and its model as people say them ("Claude Code", "Opus 5.5").
  harness?: string;
  model?: string;
  /// The turn's length in ms, when known.
  durationMs?: number;
  files: number;
  added: number;
  removed: number;
  hunks: PosterHunk[];
  shots: PosterShots;
  /// The chat's viewer link, only when the person checked Include share link.
  link?: string;
};

export const REDACTED = "•••";
const OUTSIDE = "…";

/// Values that read as secrets: provider token shapes, JWTs, and long opaque runs.
const TOKEN =
  /\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}|xox[abprs]-[\w-]{10,}|AKIA[0-9A-Z]{16}|AIza[\w-]{30,}|eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,})|[A-Za-z0-9+_=-]{40,}/g;
/// `NAME=value` (an env assignment, `export` or not): the name stays, the value goes.
const ENV_ASSIGNMENT = /\b([A-Z][A-Z0-9_]{2,})=("[^"]*"|'[^']*'|[^\s"'`]+)/g;
/// `password: x`, `api_key = "x"`, `Authorization: Bearer x`: the key stays, the value goes.
const SECRET_FIELD =
  /\b((?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|authorization)["']?\s*[:=]\s*(?:bearer\s+)?)("[^"]*"|'[^']*'|[^\s,;"'`]+)/gi;
const BEARER = /\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}/g;
/// An absolute or home path, starting a word.
/// A quoted absolute or home path, which may hold spaces: the whole quote is the path.
const QUOTED_PATH = /(["'`])((?:~\/|\/)[^"'`\n]*)\1/g;
/// An absolute or home path, starting a word (an escaped space stays in it), then the words a name
/// with spaces may go on with, up to one with an extension (`/a/secret notes.txt`).
const PATH =
  /(^|[\s"'`(=:[])((?:~\/|\/)(?:(?:[\w.@+-]|\\ )+\/)*(?:[\w.@+-]|\\ )+\/?)((?:\s[\w@+-]+){0,2}\s[\w@+-]*\.[A-Za-z0-9]{1,8}\b)?/g;

/// `text` with its secrets as ••• and each path outside `root` as …; a path inside `root` reads
/// relative to it.
export function redact(text: string, root?: string): string {
  const base = root?.replace(/\/+$/, "");
  const shown = (path: string) => {
    if (base && (path === base || path.startsWith(`${base}/`))) return path.slice(base.length + 1) || ".";
    // A lone slash or a one-segment path (`/s`, `/tmp`) is too short to say where anything lives.
    return path.split("/").filter(Boolean).length < 2 && !path.startsWith("~") ? path : OUTSIDE;
  };
  return text
    .replace(QUOTED_PATH, (_, quote: string, path: string) => quote + shown(path) + quote)
    .replace(PATH, (_, lead: string, path: string, tail: string | undefined) => {
      const out = shown(path);
      // An outside name with no extension may go on past a space (`secret notes.txt`): its tail
      // goes with it. A name that already ended (`a.ts`) keeps the words after it.
      const named = /\.[A-Za-z0-9]{1,8}$/.test(path.split("/").at(-1) ?? "");
      return lead + out + (tail && (out !== OUTSIDE || named) ? tail : "");
    })
    .replace(ENV_ASSIGNMENT, (_, name: string) => `${name}=${REDACTED}`)
    .replace(SECRET_FIELD, (_, key: string) => `${key}${REDACTED}`)
    .replace(BEARER, (_, lead: string) => `${lead}${REDACTED}`)
    .replace(TOKEN, REDACTED);
}

/// The display width of `text` in Latin letters: a wide (CJK, emoji) character counts two.
export function textWidth(text: string): number {
  let width = 0;
  for (const char of text) width += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]|\p{Extended_Pictographic}/u.test(char) ? 2 : 1;
  return width;
}

/// `text` cut to `width` with … at the end when it was longer.
export function clip(text: string, width: number): string {
  if (textWidth(text) <= width) return text;
  let out = "";
  let used = 0;
  for (const char of text) {
    const step = textWidth(char);
    if (used + step > width - 1) break;
    out += char;
    used += step;
  }
  return `${out.trimEnd()}…`;
}

/// `text` (whitespace folded) wrapped at word breaks to lines of `width`, at most `lines` of them;
/// the last line ends with … when text was left over. A word longer than a line is cut.
export function wrap(text: string, width: number, lines: number): string[] {
  const out: string[] = [];
  let line = "";
  for (const word of text.replace(/\s+/g, " ").trim().split(" ").filter(Boolean)) {
    const next = line ? `${line} ${word}` : word;
    if (textWidth(next) <= width) {
      line = next;
      continue;
    }
    if (line) out.push(line);
    if (out.length === lines) {
      const last = out[lines - 1]!;
      out[lines - 1] = textWidth(last) < width ? `${last}…` : clip(`${last} `, width);
      return out;
    }
    line = textWidth(word) > width ? clip(word, width) : word;
  }
  if (line) out.push(line);
  return out;
}

/// The rows of the chat's last finished turn: from its prompt through the summary that ends it (a
/// `continued` summary, a Stop the turn went on after, does not). Undefined while no turn has
/// finished. Walks back from the end, so it reads only that turn's rows.
export function lastFinishedTurn(rows: readonly AcpmuxRow[]): AcpmuxRow[] | undefined {
  let end = rows.length - 1;
  while (end >= 0 && !endsTurn(rows[end]!)) end--;
  if (end < 0) return undefined;
  let start = end - 1;
  while (start >= 0 && !opensTurn(rows[start]!)) start--;
  if (start < 0) return undefined;
  return rows.slice(start, end + 1);
}

/// Whether the chat has a finished turn to make a poster of (the menu row shows only then).
export const hasPoster = (rows: readonly AcpmuxRow[]): boolean => lastFinishedTurn(rows) !== undefined;

/// Up to `HUNK_LINES` lines of `lines` around its first change: one line of context before it, then
/// the change and what follows.
function glimpse(lines: readonly DiffLine[], root?: string): PosterLine[] {
  const first = lines.findIndex((line) => line.type !== "context");
  if (first < 0) return [];
  const from = Math.max(0, first - 1);
  return lines
    .slice(from, from + HUNK_LINES)
    .map((line) => ({ type: line.type, text: clip(redact(line.text.replace(/\t/g, "  "), root), HUNK_CHARS) }));
}

/// A file in the chat's folder: its canonical path (links and `..` resolved) under `root`; without
/// one, its path under `root`, or relative to it with no `..` step out.
function inside(file: TurnFile, root?: string): boolean {
  const under = (path: string) => root !== undefined && root !== "" && path.startsWith(`${root}/`);
  if (file.canonical) return under(file.canonical);
  if (file.path.startsWith("/") || file.path.startsWith("~")) return under(file.path);
  return !file.path.split("/").includes("..");
}

/// A file's path as the poster names it: relative to the chat's folder.
function shownPath(file: TurnFile, root?: string): string {
  // The canonical path when it has one: a spelling through a link outside the folder never shows.
  const source = file.canonical ?? file.path;
  const path = root && source.startsWith(`${root}/`) ? source.slice(root.length + 1) : source;
  return clip(path.replace(/^\.\//, ""), 40);
}

/// The poster's hunks: one per file, the files with the most added lines first, from files inside
/// the chat's folder only.
export function posterHunks(files: readonly TurnFile[], root?: string): PosterHunk[] {
  const base = root?.replace(/\/+$/, "");
  return [...files]
    .filter((file) => !file.binary && inside(file, base))
    .sort((a, b) => b.additions + b.deletions - (a.additions + a.deletions))
    .flatMap((file) => {
      const hunk = file.edits.flatMap((edit) => edit.hunks).find((h) => h.lines.some((l) => l.type !== "context"));
      const lines = hunk ? glimpse(hunk.lines, base) : [];
      return lines.length > 0 ? [{ path: shownPath(file, base), lines }] : [];
    })
    .slice(0, HUNKS);
}

/// The first picture the prompt carried (what the person saw before) and the last one a tool call
/// returned in the turn (what the agent saw after). Only `data:` pictures: they draw into the
/// poster without a read and never taint its canvas.
export function posterShots(turn: readonly AcpmuxRow[]): PosterShots {
  const isData = (src: string | undefined): src is string => typeof src === "string" && src.startsWith("data:image/");
  const before = turn[0]?.images?.map((image) => image.src).find(isData);
  let after: string | undefined;
  for (let index = turn.length - 1; index > 0 && !after; index--) {
    const row = turn[index]!;
    if (row.kind !== "activity") continue;
    for (const item of [...(row.items ?? [])].reverse()) {
      after = [...(item.tool?.images ?? [])].reverse().find(isData);
      if (after) break;
    }
  }
  return { ...(before ? { before } : {}), ...(after ? { after } : {}) };
}

/// The turn's length: its summary's `durationMs`, else from its prompt to its summary.
function turnDuration(turn: readonly AcpmuxRow[]): number | undefined {
  const summary = turn.at(-1);
  if (summary?.durationMs !== undefined) return summary.durationMs;
  const span = (summary?.at ?? 0) - (turn[0]?.at ?? 0);
  return span > 0 ? span : undefined;
}

/// The poster of the chat's last finished turn; undefined while none has finished.
export function buildPoster(
  rows: readonly AcpmuxRow[],
  chat: { cwd?: string; harness?: string; model?: string },
): PosterData | undefined {
  const turn = lastFinishedTurn(rows);
  if (!turn) return undefined;
  const root = chat.cwd?.replace(/\/+$/, "");
  const files = turnFiles(turn);
  const durationMs = turnDuration(turn);
  return {
    prompt: redact(turn[0]!.text ?? "", root),
    ...(chat.harness ? { harness: chat.harness } : {}),
    ...(chat.model ? { model: chat.model } : {}),
    ...(durationMs !== undefined ? { durationMs } : {}),
    files: files.length,
    added: files.reduce((sum, file) => sum + file.additions, 0),
    removed: files.reduce((sum, file) => sum + file.deletions, 0),
    hunks: posterHunks(files, root),
    shots: posterShots(turn),
  };
}

/// A duration as the poster says it: "42s", "4m 12s", "1h 5m".
export function posterDuration(ms: number): string {
  const seconds = Math.max(1, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/// The link as the poster prints it: no scheme.
export const posterLink = (url: string) => url.replace(/^https?:\/\//, "").replace(/\/$/, "");
