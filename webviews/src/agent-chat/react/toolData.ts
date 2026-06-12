// Pure view-model builders for the rich tool rows: provider-shaped tool
// input/output (see protocol.ts `ConversationItem.input` / `output`) in,
// typed render data out. No DOM and no React here so everything is directly
// unit-testable (toolData.test.ts). Components stay dumb renderers.
//
// Provider shapes handled (see docs/agent-conversation-protocol.md):
// - Claude: Edit {file_path, old_string, new_string}, Write {file_path,
//   content}, MultiEdit {file_path, edits: [...]}, NotebookEdit
//   {notebook_path, new_source}, Bash {command}, WebSearch {query},
//   WebFetch {url}, Read {file_path}.
// - Codex: apply_patch envelopes ("*** Begin Patch" text), shell
//   {command: ["bash","-lc", ...]} with JSON output
//   {"output": ..., "metadata": {"exit_code": ..., "duration_seconds": ...}}.

import { isSafeURL } from "../../agent-session/shared/markdown";
import type { ConversationItem } from "../protocol";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return null;
}

function stringField(record: Record<string, unknown> | null, key: string): string | null {
  const value = record?.[key];
  return typeof value === "string" ? value : null;
}

function numberField(record: Record<string, unknown> | null, key: string): number | null {
  const value = record?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Splits into lines, dropping the single empty element a trailing \n makes. */
function splitLines(text: string): string[] {
  if (text === "") {
    return [];
  }
  const lines = text.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") {
    lines.pop();
  }
  return lines;
}

export interface ClampedText {
  text: string;
  truncated: boolean;
  totalLines: number;
  hiddenLines: number;
}

export function clampTextLines(text: string, maxLines: number): ClampedText {
  const lines = splitLines(text);
  if (lines.length <= maxLines) {
    return { text: lines.join("\n"), truncated: false, totalLines: lines.length, hiddenLines: 0 };
  }
  return {
    text: lines.slice(0, maxLines).join("\n"),
    truncated: true,
    totalLines: lines.length,
    hiddenLines: lines.length - maxLines,
  };
}

// ---------------------------------------------------------------------------
// File changes -> unified-diff view model
// ---------------------------------------------------------------------------

export type DiffLineKind = "add" | "del" | "context" | "hunk";

export interface DiffLine {
  kind: DiffLineKind;
  text: string;
  /** For `hunk` lines synthesized from collapsed context: hidden line count. */
  collapsedCount?: number;
}

export type FileDiffOp = "edit" | "create" | "delete";

export interface FileDiff {
  path: string | null;
  op: FileDiffOp;
  lines: DiffLine[];
  addedCount: number;
  removedCount: number;
  /** Lines dropped by the parse-time cap (0 when the diff is complete). */
  truncatedLineCount: number;
  /**
   * True when the provider input exceeded the source-character cap, so the
   * diff (and its counts) only cover the leading part of the change. The row
   * must show a truncation marker so a tail-only change never looks like
   * "no change".
   */
  sourceTruncated: boolean;
}

/** Above this many DP cells the line diff falls back to whole-block del/add. */
const LINE_DIFF_CELL_LIMIT = 200_000;
/** Context lines kept on each side of a change before collapsing the run. */
const DIFF_CONTEXT_LINES = 2;
/**
 * Bounds for parse work done on the render path. Counts stay accurate, but a
 * giant Write payload or patch never allocates more than this many DiffLine
 * objects (the row reports the remainder via `truncatedLineCount`), and
 * oversized source strings are cut before line splitting.
 */
const MAX_DIFF_LINES = 1_000;
const MAX_DIFF_SOURCE_CHARS = 200_000;

function boundedSource(text: string): string {
  if (text.length <= MAX_DIFF_SOURCE_CHARS) {
    return text;
  }
  const cut = text.lastIndexOf("\n", MAX_DIFF_SOURCE_CHARS);
  return text.slice(0, cut > 0 ? cut : MAX_DIFF_SOURCE_CHARS);
}

/**
 * Line-level diff of two text blocks: common prefix/suffix trim, then an LCS
 * walk over the middle. Long context runs collapse into `hunk` lines so the
 * clamped preview starts at the first real change instead of shared prefix.
 */
export function computeLineDiff(oldText: string, newText: string): DiffLine[] {
  const oldLines = splitLines(boundedSource(oldText));
  const newLines = splitLines(boundedSource(newText));

  let prefix = 0;
  while (
    prefix < oldLines.length &&
    prefix < newLines.length &&
    oldLines[prefix] === newLines[prefix]
  ) {
    prefix += 1;
  }
  let suffix = 0;
  while (
    suffix < oldLines.length - prefix &&
    suffix < newLines.length - prefix &&
    oldLines[oldLines.length - 1 - suffix] === newLines[newLines.length - 1 - suffix]
  ) {
    suffix += 1;
  }

  const oldMid = oldLines.slice(prefix, oldLines.length - suffix);
  const newMid = newLines.slice(prefix, newLines.length - suffix);

  const raw: DiffLine[] = [];
  for (const line of oldLines.slice(0, prefix)) {
    raw.push({ kind: "context", text: line });
  }
  for (const line of diffMiddle(oldMid, newMid)) {
    raw.push(line);
  }
  for (const line of oldLines.slice(oldLines.length - suffix)) {
    raw.push({ kind: "context", text: line });
  }
  return collapseContextRuns(raw);
}

function diffMiddle(oldLines: string[], newLines: string[]): DiffLine[] {
  if (oldLines.length === 0) {
    return newLines.map((text) => ({ kind: "add" as const, text }));
  }
  if (newLines.length === 0) {
    return oldLines.map((text) => ({ kind: "del" as const, text }));
  }
  if (oldLines.length * newLines.length > LINE_DIFF_CELL_LIMIT) {
    return [
      ...oldLines.map((text) => ({ kind: "del" as const, text })),
      ...newLines.map((text) => ({ kind: "add" as const, text })),
    ];
  }
  // LCS length table (single allocation, row-major).
  const rows = oldLines.length + 1;
  const cols = newLines.length + 1;
  const table = new Uint32Array(rows * cols);
  for (let i = oldLines.length - 1; i >= 0; i -= 1) {
    for (let j = newLines.length - 1; j >= 0; j -= 1) {
      table[i * cols + j] =
        oldLines[i] === newLines[j]
          ? table[(i + 1) * cols + j + 1] + 1
          : Math.max(table[(i + 1) * cols + j], table[i * cols + j + 1]);
    }
  }
  const lines: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < oldLines.length && j < newLines.length) {
    if (oldLines[i] === newLines[j]) {
      lines.push({ kind: "context", text: oldLines[i] });
      i += 1;
      j += 1;
    } else if (table[(i + 1) * cols + j] >= table[i * cols + j + 1]) {
      lines.push({ kind: "del", text: oldLines[i] });
      i += 1;
    } else {
      lines.push({ kind: "add", text: newLines[j] });
      j += 1;
    }
  }
  for (; i < oldLines.length; i += 1) {
    lines.push({ kind: "del", text: oldLines[i] });
  }
  for (; j < newLines.length; j += 1) {
    lines.push({ kind: "add", text: newLines[j] });
  }
  return lines;
}

/** Collapses context runs longer than 2*DIFF_CONTEXT_LINES+1 into hunk rows. */
function collapseContextRuns(lines: DiffLine[]): DiffLine[] {
  const out: DiffLine[] = [];
  let run: DiffLine[] = [];
  const flush = (isEdge: boolean) => {
    const keepBefore = out.length === 0 ? 0 : DIFF_CONTEXT_LINES;
    const keepAfter = isEdge ? 0 : DIFF_CONTEXT_LINES;
    if (run.length <= keepBefore + keepAfter + 1) {
      out.push(...run);
    } else {
      out.push(...run.slice(0, keepBefore));
      out.push({ kind: "hunk", text: "", collapsedCount: run.length - keepBefore - keepAfter });
      out.push(...run.slice(run.length - keepAfter));
    }
    run = [];
  };
  for (const line of lines) {
    if (line.kind === "context") {
      run.push(line);
    } else {
      flush(false);
      out.push(line);
    }
  }
  flush(true);
  return out;
}

function countDiff(lines: DiffLine[]): { addedCount: number; removedCount: number } {
  let addedCount = 0;
  let removedCount = 0;
  for (const line of lines) {
    if (line.kind === "add") {
      addedCount += 1;
    } else if (line.kind === "del") {
      removedCount += 1;
    }
  }
  return { addedCount, removedCount };
}

function makeFileDiff(
  path: string | null,
  op: FileDiffOp,
  lines: DiffLine[],
  sourceTruncated = false,
): FileDiff {
  const counts = countDiff(lines);
  if (lines.length <= MAX_DIFF_LINES) {
    return { path, op, lines, truncatedLineCount: 0, sourceTruncated, ...counts };
  }
  return {
    path,
    op,
    lines: lines.slice(0, MAX_DIFF_LINES),
    truncatedLineCount: lines.length - MAX_DIFF_LINES,
    sourceTruncated,
    ...counts,
  };
}

function exceedsSourceCap(...texts: string[]): boolean {
  return texts.some((text) => text.length > MAX_DIFF_SOURCE_CHARS);
}

const APPLY_PATCH_MARKER = "*** Begin Patch";

/** Parses a Codex apply_patch envelope into per-file diffs. */
export function parseApplyPatch(patch: string): FileDiff[] {
  const diffs: FileDiff[] = [];
  let current: { path: string; op: FileDiffOp; lines: DiffLine[] } | null = null;
  const flush = () => {
    if (current) {
      diffs.push(makeFileDiff(current.path, current.op, collapseContextRuns(current.lines)));
      current = null;
    }
  };
  for (const line of splitLines(boundedSource(patch))) {
    if (line.startsWith("*** Update File: ")) {
      flush();
      current = { path: line.slice("*** Update File: ".length).trim(), op: "edit", lines: [] };
    } else if (line.startsWith("*** Add File: ")) {
      flush();
      current = { path: line.slice("*** Add File: ".length).trim(), op: "create", lines: [] };
    } else if (line.startsWith("*** Delete File: ")) {
      flush();
      current = { path: line.slice("*** Delete File: ".length).trim(), op: "delete", lines: [] };
    } else if (line.startsWith("*** Move to: ")) {
      if (current) {
        current.path = `${current.path} → ${line.slice("*** Move to: ".length).trim()}`;
      }
    } else if (line.startsWith("***")) {
      // Begin/End Patch and unknown directives.
      if (line.startsWith("*** End Patch")) {
        flush();
      }
    } else if (current) {
      if (line.startsWith("@@")) {
        current.lines.push({ kind: "hunk", text: line.slice(2).trim() });
      } else if (line.startsWith("+")) {
        current.lines.push({ kind: "add", text: line.slice(1) });
      } else if (line.startsWith("-")) {
        current.lines.push({ kind: "del", text: line.slice(1) });
      } else {
        current.lines.push({ kind: "context", text: line.startsWith(" ") ? line.slice(1) : line });
      }
    }
  }
  flush();
  if (diffs.length > 0 && exceedsSourceCap(patch)) {
    // The cap cut the patch tail, so the last section is incomplete.
    diffs[diffs.length - 1] = { ...diffs[diffs.length - 1], sourceTruncated: true };
  }
  return diffs;
}

/** Finds apply_patch text in the input shapes Codex items carry. */
function applyPatchText(input: unknown): string | null {
  if (typeof input === "string") {
    return input.includes(APPLY_PATCH_MARKER) ? input : null;
  }
  const record = asRecord(input);
  if (!record) {
    return null;
  }
  for (const key of ["patch", "input", "content"]) {
    const value = stringField(record, key);
    if (value?.includes(APPLY_PATCH_MARKER)) {
      return value;
    }
  }
  const command = record["command"];
  if (Array.isArray(command)) {
    for (const part of command) {
      if (typeof part === "string" && part.includes(APPLY_PATCH_MARKER)) {
        return part;
      }
    }
  }
  return null;
}

/**
 * Builds diffs for a file_change item from whichever provider shape its
 * input carries. Empty result means "nothing structured": the row falls back
 * to the generic input/output rendering.
 */
export function fileChangeDiffs(item: Pick<ConversationItem, "input" | "title">): FileDiff[] {
  const patch = applyPatchText(item.input);
  if (patch !== null) {
    return parseApplyPatch(patch);
  }
  const record = asRecord(item.input);
  if (!record) {
    return [];
  }
  const path =
    stringField(record, "file_path") ??
    stringField(record, "notebook_path") ??
    stringField(record, "path") ??
    item.title ??
    null;

  const oldString = stringField(record, "old_string");
  const newString = stringField(record, "new_string");
  if (oldString !== null && newString !== null) {
    return [
      makeFileDiff(
        path,
        "edit",
        computeLineDiff(oldString, newString),
        exceedsSourceCap(oldString, newString),
      ),
    ];
  }

  const edits = record["edits"];
  if (Array.isArray(edits)) {
    const lines: DiffLine[] = [];
    let editIndex = 0;
    let truncated = false;
    for (const edit of edits) {
      const editRecord = asRecord(edit);
      const editOld = stringField(editRecord, "old_string");
      const editNew = stringField(editRecord, "new_string");
      if (editOld === null || editNew === null) {
        continue;
      }
      if (editIndex > 0) {
        lines.push({ kind: "hunk", text: "" });
      }
      lines.push(...computeLineDiff(editOld, editNew));
      truncated = truncated || exceedsSourceCap(editOld, editNew);
      editIndex += 1;
    }
    return lines.length > 0 ? [makeFileDiff(path, "edit", lines, truncated)] : [];
  }

  const content = stringField(record, "content") ?? stringField(record, "new_source");
  if (content !== null) {
    const sourceLines = splitLines(boundedSource(content));
    const lines: DiffLine[] = sourceLines.map((text) => ({ kind: "add", text }));
    return [makeFileDiff(path, "create", lines, exceedsSourceCap(content))];
  }
  return [];
}

// ---------------------------------------------------------------------------
// Command execution -> structured view
// ---------------------------------------------------------------------------

export interface CommandView {
  /** The command line to show as the prompt line; null when unknown. */
  command: string | null;
  /** Combined stdout/stderr (providers do not separate the streams). */
  output: string | null;
  exitCode: number | null;
  durationText: string | null;
}

const SHELL_WRAPPERS = new Set(["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"]);

/** Joins a Codex argv, unwrapping the ["bash","-lc","<script>"] pattern. */
function commandFromArgv(argv: unknown[]): string | null {
  const parts = argv.filter((part): part is string => typeof part === "string");
  if (parts.length === 0) {
    return null;
  }
  if (parts.length === 3 && SHELL_WRAPPERS.has(parts[0]) && (parts[1] === "-lc" || parts[1] === "-c")) {
    return parts[2];
  }
  return parts.join(" ");
}

export function formatDurationSeconds(seconds: number): string {
  if (seconds < 1) {
    return `${Math.round(seconds * 1000)}ms`;
  }
  if (seconds < 60) {
    const rounded = Math.round(seconds * 10) / 10;
    return `${rounded}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const rest = Math.round(seconds % 60);
  return `${minutes}m ${rest}s`;
}

const EXIT_CODE_PATTERN = /\bexit code:?\s+(\d+)\b/i;

/**
 * Builds the structured command view for a command_execution item. `provider`
 * is the session's provider id; envelope unwrapping only applies to Codex
 * sessions so another provider's command stdout is never reinterpreted.
 */
export function commandExecutionView(
  item: Pick<ConversationItem, "input" | "output" | "title" | "status">,
  provider?: string | null,
): CommandView {
  const record = asRecord(item.input);
  let command: string | null = null;
  if (typeof item.input === "string") {
    command = item.input;
  } else if (record) {
    const rawCommand = record["command"];
    if (typeof rawCommand === "string") {
      command = rawCommand;
    } else if (Array.isArray(rawCommand)) {
      command = commandFromArgv(rawCommand);
    } else {
      command = stringField(record, "cmd") ?? stringField(record, "script");
    }
  }
  if (command === null && item.title) {
    command = item.title;
  }

  let output = item.output?.text ?? null;
  let exitCode: number | null = null;
  let durationText: string | null = null;

  // Codex shell results arrive as a JSON envelope in the transcript:
  // {"output": "...", "metadata": {"exit_code": 0, "duration_seconds": 0.1}}.
  // The daemon's Codex parser usually unwraps it (keeping only is_error, see
  // decodeCodexToolOutput in daemon/remote/agentconv/codex.go), but the raw
  // envelope still reaches us when the inner output is empty, and hook-only
  // or future producers may pass it through verbatim. Parsing it here is the
  // only way to surface exit code/duration until the protocol carries them
  // as structured ToolOutput fields. Two guards keep arbitrary stdout from
  // being reinterpreted: only Codex sessions are unwrapped at all, and the
  // text must carry both envelope fields.
  if (provider === "codex" && output !== null && output.startsWith("{")) {
    try {
      const parsed = asRecord(JSON.parse(output));
      const innerOutput = stringField(parsed, "output");
      const metadata = asRecord(parsed?.["metadata"] ?? null);
      if (innerOutput !== null && metadata !== null) {
        output = innerOutput;
        exitCode = numberField(metadata, "exit_code");
        const durationSeconds = numberField(metadata, "duration_seconds");
        if (durationSeconds !== null) {
          durationText = formatDurationSeconds(durationSeconds);
        }
      }
    } catch {
      // Not the Codex envelope; keep the raw text.
    }
  }

  if (exitCode === null && output !== null) {
    const match = EXIT_CODE_PATTERN.exec(output);
    if (match) {
      exitCode = Number.parseInt(match[1], 10);
    }
  }
  if (
    exitCode === null &&
    item.status === "completed" &&
    item.output?.is_error !== true &&
    item.output !== undefined
  ) {
    // A successful completed result with no explicit code is exit 0. Never
    // inferred while in_progress: live items can carry partial output before
    // the command finishes.
    exitCode = 0;
  }

  return { command, output: output === "" ? null : output, exitCode, durationText };
}

// ---------------------------------------------------------------------------
// Read / file-view tools -> path + preview
// ---------------------------------------------------------------------------

export interface FileViewData {
  path: string;
  preview: string | null;
}

const READ_TOOL_NAMES = new Set(["read", "notebookread", "read_file", "readfile", "view", "cat", "open_file"]);

/**
 * Returns path + preview when a dynamic_tool_call is a file read; null means
 * "not a file view", and the row falls back to generic rendering.
 */
export function fileViewData(
  item: Pick<ConversationItem, "tool_name" | "input" | "output">,
): FileViewData | null {
  const record = asRecord(item.input);
  const path =
    stringField(record, "file_path") ??
    stringField(record, "notebook_path") ??
    stringField(record, "path");
  if (path === null) {
    return null;
  }
  const toolName = item.tool_name?.toLowerCase() ?? "";
  if (!READ_TOOL_NAMES.has(toolName)) {
    return null;
  }
  const preview = item.output?.text ?? null;
  return { path, preview: preview === "" ? null : preview };
}

// ---------------------------------------------------------------------------
// Web search -> query + result links
// ---------------------------------------------------------------------------

export interface WebSearchResult {
  title: string;
  url: string;
}

export interface WebSearchView {
  query: string | null;
  results: WebSearchResult[];
  /** Raw output text for the no-structured-results fallback. */
  text: string | null;
}

const MAX_SEARCH_RESULTS = 8;

// Claude WebSearch output embeds JSON objects like
// {"title": "...", "url": "..."} (either key order) inside result text.
const RESULT_OBJECT_PATTERN =
  /\{\s*"(?:title|url)"\s*:\s*"(?:[^"\\]|\\.)*"\s*,\s*"(?:title|url)"\s*:\s*"(?:[^"\\]|\\.)*"\s*\}/g;

function extractSearchResults(text: string): WebSearchResult[] {
  const results: WebSearchResult[] = [];
  const seen = new Set<string>();
  for (const match of text.match(RESULT_OBJECT_PATTERN) ?? []) {
    if (results.length >= MAX_SEARCH_RESULTS) {
      break;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(match);
    } catch {
      continue;
    }
    const record = asRecord(parsed);
    const title = stringField(record, "title");
    const url = stringField(record, "url");
    if (title === null || url === null || seen.has(url) || !isSafeURL(url)) {
      continue;
    }
    seen.add(url);
    results.push({ title, url });
  }
  return results;
}

export function webSearchView(
  item: Pick<ConversationItem, "input" | "output" | "title">,
): WebSearchView {
  const record = asRecord(item.input);
  let query =
    stringField(record, "query") ?? stringField(record, "q") ?? stringField(record, "url");
  if (query === null && typeof item.input === "string" && item.input !== "") {
    query = item.input;
  }
  if (query === null && item.title) {
    query = item.title;
  }
  const text = item.output?.text ?? null;
  const results = text !== null ? extractSearchResults(text) : [];
  return { query, results, text: text === "" ? null : text };
}
