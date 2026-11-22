// Completed recorded writes only: never read paths, execute commands, or rebuild edit hunks.
import { pathKey, toolCanonical, type AcpmuxActivity } from "../model";
import type { Artifact } from "./artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const cache = new WeakMap<Tool, Artifact[]>();
const HTML_FILE = /\.html?$/i;
const WRITE = /^(?:write|write_file|writefile|create_file)(?:[\s:]|$)/i;
// Older logs did not mark replacement-only diffs as fragments. These calls describe edits, and
// Claude Code's Edit/MultiEdit diff is its replacement strings, not the file. Gemini's replace and
// OpenCode's edit send the whole old and new file in the same calls, so an edit-named diff opens
// only once it is shown to be the file (`completeEditDiff`), as a whole ACP diff (apply_patch) does.
const PARTIAL_EDIT = /^(?:edit|multiedit|replace|replace_in_file|edit_file)(?:[\s:]|$)/i;
// A whole HTML document: it starts with its doctype, or opens <html> and ends closing it.
const wholeDocument = (text: string) =>
  /^\s*<!doctype\s+html\b/i.test(text) || (/^\s*<html\b/i.test(text) && /<\/html\s*>\s*$/i.test(text));
const NEW_TEXT_KEYS = ["new_string", "newString", "new_str", "newText", "replacement"] as const;

type RecordedInput = Record<string, unknown>;
type Diff = NonNullable<Tool["diffs"]>[number];
type PathIndex = {
  canonicalByRawPath: Map<string, string>;
  diffCanonicalKeys: Set<string>;
};
type AddedProvenance = { rawPaths: Set<string>; canonicalKeys: Set<string> };

function inputRecord(summary: string | undefined): RecordedInput | undefined {
  if (!summary) return undefined;
  try {
    const parsed: unknown = JSON.parse(summary);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as RecordedInput) : undefined;
  } catch {
    // Malformed or truncated input cannot supply provenance or a document.
    return undefined;
  }
}

function pathIndex(tool: Tool, diffs: readonly Diff[]): PathIndex {
  const canonicalByRawPath = new Map<string, string>();
  const diffCanonicalKeys = new Set<string>();
  for (const diff of diffs) {
    if (diff.canonical === undefined) continue;
    diffCanonicalKeys.add(diff.canonical);
    if (!canonicalByRawPath.has(diff.path)) canonicalByRawPath.set(diff.path, diff.canonical);
  }
  for (const location of tool.locations ?? []) {
    if (HTML_FILE.test(location.path) && location.canonical !== undefined && !canonicalByRawPath.has(location.path))
      canonicalByRawPath.set(location.path, location.canonical);
  }
  const input = tool.inputPath;
  if (input && HTML_FILE.test(input.path) && !canonicalByRawPath.has(input.path))
    canonicalByRawPath.set(input.path, input.canonical);
  return { canonicalByRawPath, diffCanonicalKeys };
}

function addedProvenance(input: RecordedInput, index: PathIndex): AddedProvenance {
  const rawPaths = new Set<string>();
  const canonicalKeys = new Set<string>();
  const changes = input.changes;
  if (!Array.isArray(changes)) return { rawPaths, canonicalKeys };
  for (const value of changes) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const change = value as Record<string, unknown>;
    const path = change.path;
    const additions = change.additions;
    const deletions = change.deletions;
    if (
      typeof path !== "string" ||
      !path ||
      !HTML_FILE.test(path) ||
      change.type !== "add" ||
      !Number.isInteger(additions) ||
      (additions as number) < 0 ||
      deletions !== 0
    )
      continue;
    rawPaths.add(path);
    const canonical = index.canonicalByRawPath.get(path);
    if (canonical !== undefined) canonicalKeys.add(canonical);
    else if (index.diffCanonicalKeys.has(path)) canonicalKeys.add(path);
  }
  return { rawPaths, canonicalKeys };
}

function isCompleteAddedDiff(diff: Diff, provenance: AddedProvenance): boolean {
  if (diff.oldText != null || diff.fragment || diff.fromInput) return false;
  return (
    provenance.rawPaths.has(diff.path) || (diff.canonical !== undefined && provenance.canonicalKeys.has(diff.canonical))
  );
}

/// The replacement texts an edit call's input records (Claude Code `new_string`, MultiEdit `edits`,
/// OpenCode `newString`, Gemini `new_string`), when it records any.
function replacementTexts(input: RecordedInput | undefined): Set<string> | undefined {
  if (!input) return undefined;
  const texts = new Set<string>();
  const read = (record: Record<string, unknown>) => {
    for (const key of NEW_TEXT_KEYS) if (typeof record[key] === "string") texts.add(record[key] as string);
  };
  read(input);
  if (Array.isArray(input.edits))
    for (const edit of input.edits)
      if (edit && typeof edit === "object" && !Array.isArray(edit)) read(edit as Record<string, unknown>);
  return texts.size ? texts : undefined;
}

/// Whether an edit-named call's unmarked diff is the whole file rather than its replacement: it is
/// not one of the replacements the input records, and either the input records some (so the agent
/// sent the file beside them) or its new text is a whole HTML document. A legacy snippet with no
/// input, or one equal to its input's replacement, never opens.
function completeEditDiff(diff: Diff, replacements: Set<string> | undefined): boolean {
  if (diff.fragment || diff.fromInput) return false;
  if (replacements?.has(diff.newText)) return false;
  return replacements !== undefined || wholeDocument(diff.newText);
}

export function toolArtifacts(tool: Tool): Artifact[] {
  if (tool.status !== "completed" || (tool.kind !== "edit" && tool.kind !== "fileChange")) return [];
  const previous = cache.get(tool);
  if (previous) return previous;
  const found: Artifact[] = [];
  const seen = new Set<string>();
  const input = inputRecord(tool.inputSummary);
  const partialEdit = PARTIAL_EDIT.test(tool.title);
  const diffs = (tool.diffs ?? []).filter((diff) => HTML_FILE.test(diff.path));
  const provenance = partialEdit && input ? addedProvenance(input, pathIndex(tool, diffs)) : undefined;
  const add = (file: { path: string; canonical?: string }, code: string) => {
    const path = pathKey(file);
    if (!HTML_FILE.test(file.path) || !code.trim() || seen.has(path)) return;
    seen.add(path);
    found.push({ kind: "html", lang: "html", code, path });
  };
  const replacements = partialEdit ? replacementTexts(input) : undefined;
  for (const diff of diffs) {
    const wholeDiff = !diff.fragment || (diff.fromInput && diff.oldText == null);
    const completeAddedDiff = provenance ? isCompleteAddedDiff(diff, provenance) : false;
    const completeEdit = partialEdit && completeEditDiff(diff, replacements);
    if ((!partialEdit && wholeDiff) || completeAddedDiff || completeEdit) add(diff, diff.newText);
  }

  // Claude/pi/OpenCode/Gemini whole-file writes may carry their contents only in rawInput, each
  // naming the file its own way (toolPaths.ts). Even when their diff is marked unknown-old/fragment,
  // the completed Write still records the whole new file. Other tools' content fields, shell
  // redirections and patches are never treated this way.
  if (WRITE.test(tool.title) && input) {
    const path = input.file_path ?? input.filePath ?? input.absolute_path ?? input.path;
    if (typeof path === "string" && typeof input.content === "string")
      add({ path, canonical: toolCanonical(tool, path) }, input.content);
  }
  // mergeToolItem allocates a new tool for each update; completion and late content cannot
  // reuse an earlier result. Only completed tools enter this weak cache.
  cache.set(tool, found);
  return found;
}
