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

export function toolArtifacts(tool: Tool): Artifact[] {
  if (tool.status !== "completed" || (tool.kind !== "edit" && tool.kind !== "fileChange")) return [];
  const previous = cache.get(tool);
  if (previous) return previous;
  const found: Artifact[] = [];
  const seen = new Set<string>();
  const add = (file: { path: string; canonical?: string }, code: string) => {
    const path = pathKey(file);
    if (!HTML_FILE.test(file.path) || !code.trim() || seen.has(path)) return;
    seen.add(path);
    found.push({ kind: "html", lang: "html", code, path });
  };
  if (!PARTIAL_EDIT.test(tool.title))
    for (const diff of tool.diffs ?? [])
      if (!diff.fragment || (diff.fromInput && diff.oldText == null)) add(diff, diff.newText);

  // Claude/pi/Gemini whole-file writes may carry their contents only in rawInput. Even when
  // their diff is marked unknown-old/fragment, the completed Write still records the whole new
  // file. Other tools' content fields, shell redirections and patches are never treated this way.
  if (WRITE.test(tool.title) && tool.inputSummary) {
    try {
      const input: unknown = JSON.parse(tool.inputSummary);
      if (input && typeof input === "object") {
        const fields = input as Record<string, unknown>;
        const path = fields.file_path ?? fields.path;
        if (typeof path === "string" && typeof fields.content === "string")
          add({ path, canonical: toolCanonical(tool, path) }, fields.content);
      }
    } catch {
      // Malformed or truncated input cannot supply a document.
    }
  }
  // mergeToolItem allocates a new tool for each update; completion and late content cannot
  // reuse an earlier result. Only completed tools enter this weak cache.
  cache.set(tool, found);
  return found;
}
