// Completed recorded writes only: never read paths, execute commands, or rebuild edit hunks.
import { pathKey, toolCanonical, type AcpmuxActivity } from "../model";
import type { Artifact } from "./artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const cache = new WeakMap<Tool, Artifact[]>();
const HTML_FILE = /\.html?$/i;
const WRITE = /^(?:write|write_file|writefile|create_file)(?:[\s:]|$)/i;
// Older logs did not mark replacement-only diffs as fragments. These calls describe edits,
// whereas a whole ACP diff (for example apply_patch) describes the entire resulting file.
const PARTIAL_EDIT = /^(?:edit|multiedit|replace|replace_in_file|edit_file)(?:[\s:]|$)/i;

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
  for (const diff of diffs) {
    const wholeDiff = !diff.fragment || (diff.fromInput && diff.oldText == null);
    const completeAddedDiff = provenance ? isCompleteAddedDiff(diff, provenance) : false;
    if ((!partialEdit && wholeDiff) || completeAddedDiff) add(diff, diff.newText);
  }

  // Claude/pi/Gemini whole-file writes may carry their contents only in rawInput. Even when
  // their diff is marked unknown-old/fragment, the completed Write still records the whole new
  // file. Other tools' content fields, shell redirections and patches are never treated this way.
  if (WRITE.test(tool.title) && input) {
    const path = input.file_path ?? input.path;
    if (typeof path === "string" && typeof input.content === "string")
      add({ path, canonical: toolCanonical(tool, path) }, input.content);
  }
  // mergeToolItem allocates a new tool for each update; completion and late content cannot
  // reuse an earlier result. Only completed tools enter this weak cache.
  cache.set(tool, found);
  return found;
}
