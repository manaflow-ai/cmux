// The paths a file tool call edits, for an edited-files row that has no diff (EditedFilesCard).
// `inputSummary` is the call's `rawInput` as JSON, in each harness's own shape:
//   Claude Code  Write/Edit/MultiEdit {file_path}, NotebookEdit {notebook_path}
//   Codex        apply_patch {patch | input | command: ["apply_patch", patch]}, file changes
//                {changes: {<path>: …}} or {changes: [{path}]}
//   opencode     write/edit/multiedit {filePath}, patch {patchText}
//   pi           write/edit {path}
//   Gemini       write_file/replace {file_path | absolute_path}
// Then the call's locations, a path field in a cut-off input, and a path in the title. A row never
// shows the raw input: no path found is an empty list (the card says "Unknown file").
import type { AcpmuxActivity } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Field names that hold the edited file, in the order the harnesses use them.
const PATH_KEYS = ["file_path", "filePath", "notebook_path", "notebookPath", "absolute_path", "path", "target_file"];
/// Field names that hold an apply_patch body.
const PATCH_KEYS = ["patch", "patchText", "input"];
const PATCH_FILE = /^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm;
const PATCH_MOVE = /^\*\*\* Move to: (.+)$/gm;

/// The edited paths, in first-seen order without repeats.
export function editedPaths(tool: Tool): string[] {
  const found: string[] = [];
  const add = (value: unknown) => {
    if (typeof value !== "string") return;
    const path = value.trim();
    if (path && path.length <= 4096 && !path.includes("\n") && !found.includes(path)) found.push(path);
  };
  const input = parseInput(tool.inputSummary);
  if (input) fromInput(input, add);
  if (!found.length) for (const location of tool.locations ?? []) add(location.path);
  if (!found.length && tool.inputSummary && !input) {
    // A summary that is not JSON: a cut-off input, or the path itself (`notes.txt`).
    if (/^\s*[[{]/.test(tool.inputSummary)) fromCutInput(tool.inputSummary, add);
    else add(looksLikePath(tool.inputSummary.trim()));
  }
  if (!found.length) add(titlePath(tool.title));
  return found;
}

/// A short row label that describes a call without ever falling back to its raw JSON input.
/// Paths come from the same harness-aware reader as edited-file cards, so a Write whose content
/// precedes `file_path` still reads as `Write gen.py`.
export function toolLabel(tool: Tool, fallback: string, commandLabel: (command: string) => string): string {
  const title = readableName(tool.title);
  const fallbackName = readableName(fallback, tool.kind) || "Tool";
  const paths = editedPaths(tool);
  const command = tool.command?.trim();
  if (tool.kind === "execute" && command) return commandLabel(command);
  if (paths.length) {
    const action = firstWord(title || fallbackName);
    return title.includes(paths[0]!) ? title : `${action} ${paths[0]}`;
  }
  return title || fallbackName;
}

function firstWord(value: string): string {
  return value.trim().split(/\s+/, 1)[0] ?? value.trim();
}

function readableName(value: string | undefined, kind?: string): string {
  const name = value?.trim() ?? "";
  return name && !name.startsWith("{") && !name.startsWith("[") ? name : (kind?.trim() ?? "");
}

function fromInput(input: Record<string, unknown>, add: (value: unknown) => void) {
  for (const key of PATH_KEYS) add(input[key]);
  for (const key of PATCH_KEYS) if (typeof input[key] === "string") patchPaths(input[key] as string, add);
  const command = input.command;
  if (Array.isArray(command) && command[0] === "apply_patch") for (const part of command) patchPaths(part, add);
  else if (typeof command === "string" && command.includes("*** Begin Patch")) patchPaths(command, add);
  const changes = input.changes;
  if (Array.isArray(changes)) {
    for (const change of changes) if (change && typeof change === "object") add((change as { path?: unknown }).path);
  } else if (changes && typeof changes === "object") {
    for (const path of Object.keys(changes)) add(path);
  }
  const edits = input.edits;
  if (Array.isArray(edits))
    for (const edit of edits)
      if (edit && typeof edit === "object") for (const key of PATH_KEYS) add((edit as Record<string, unknown>)[key]);
}

function patchPaths(text: unknown, add: (value: unknown) => void) {
  if (typeof text !== "string" || !text.includes("*** ")) return;
  for (const match of text.matchAll(PATCH_FILE)) add(match[1]);
  for (const match of text.matchAll(PATCH_MOVE)) add(match[1]);
}

/// A path field in an input that is not whole JSON (a long input cut off on the way).
function fromCutInput(text: string, add: (value: unknown) => void) {
  const keys = PATH_KEYS.join("|");
  for (const match of text.matchAll(new RegExp(`"(?:${keys})"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"`, "g"))) {
    try {
      add(JSON.parse(`"${match[1]}"`));
    } catch {
      // A field cut inside its escape is no path.
    }
  }
  patchPaths(text.replace(/\\n/g, "\n"), add);
}

/// `Write /tmp/a.py`, `Edit \`src/a.ts\``: the title's last word when it reads as a path.
function titlePath(title: string): string | undefined {
  return looksLikePath(title.trim().split(/\s+/).slice(1).join(" ").replace(/^`|`$/g, ""));
}

/// `text` when it reads as one path: a folder in it, or a file name with an extension.
function looksLikePath(text: string): string | undefined {
  if (!text || /[\n{}"]/.test(text)) return undefined;
  return /\//.test(text) || /^[\w.-]+\.[A-Za-z0-9]{1,12}$/.test(text) ? text : undefined;
}

function parseInput(summary: string | undefined): Record<string, unknown> | undefined {
  if (!summary) return undefined;
  try {
    const value: unknown = JSON.parse(summary);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}
