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

function isCompleteAddedDiff(tool: Tool, diff: NonNullable<Tool["diffs"]>[number], input: RecordedInput): boolean {
  if (diff.oldText != null || diff.fragment || diff.fromInput) return false;
  const changes = input.changes;
  if (!Array.isArray(changes)) return false;
  return changes.some((value) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const change = value as Record<string, unknown>;
    const path = change.path;
    const additions = change.additions;
    const deletions = change.deletions;
    if (
      typeof path !== "string" ||
      !path ||
      change.type !== "add" ||
      !Number.isInteger(additions) ||
      (additions as number) < 0 ||
      deletions !== 0
    )
      return false;
    // The summary path must identify this exact recorded file. A canonical spelling is accepted
    // only when mergeToolItem already normalized it on the diff or one of the call's locations.
    const changeKey = pathKey({ path, canonical: toolCanonical(tool, path) });
    return path === diff.path || changeKey === pathKey(diff);
  });
}

export function toolArtifacts(tool: Tool): Artifact[] {
  if (tool.status !== "completed" || (tool.kind !== "edit" && tool.kind !== "fileChange")) return [];
  const previous = cache.get(tool);
  if (previous) return previous;
  const found: Artifact[] = [];
  const seen = new Set<string>();
  const input = inputRecord(tool.inputSummary);
  const partialEdit = PARTIAL_EDIT.test(tool.title);
  const add = (file: { path: string; canonical?: string }, code: string) => {
    const path = pathKey(file);
    if (!HTML_FILE.test(file.path) || !code.trim() || seen.has(path)) return;
    seen.add(path);
    found.push({ kind: "html", lang: "html", code, path });
  };
  for (const diff of tool.diffs ?? []) {
    const wholeDiff = !diff.fragment || (diff.fromInput && diff.oldText == null);
    const completeAddedDiff = partialEdit && input ? isCompleteAddedDiff(tool, diff, input) : false;
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
