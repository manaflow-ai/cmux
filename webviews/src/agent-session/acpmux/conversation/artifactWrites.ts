// Completed file writes from every harness share ACP diffs. Keep only whole recorded HTML:
// a path, edit fragment, failed call, or shell command is never enough to invent a document.
import { type AcpmuxActivity, type AcpmuxRow } from "../model";
import { artifactPath, type Artifact } from "./artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const cached = new WeakMap<Tool, Artifact[]>();
const HTML_FILE = /\.html?$/i;
const WRITE = /^(?:Write|write|write_file)(?:[\s:]|$)/;
// Older Claude/pi edit diffs predate the fragment marker and contain replacements only.
const PARTIAL_EDIT = /^(?:Edit|MultiEdit|edit|replace)(?:[\s:]|$)/;

function document(path: string, code: string, canonical?: string): Artifact | undefined {
  return HTML_FILE.test(path) && code.trim()
    ? { kind: "html", lang: "html", code, path, ...(canonical ? { canonical } : {}) }
    : undefined;
}

function readWrites(tool: Tool): Artifact[] {
  if (tool.status !== "completed" || tool.kind !== "edit") return [];
  const found: Artifact[] = [];
  for (const diff of tool.diffs ?? []) {
    if (diff.fragment || PARTIAL_EDIT.test(tool.title)) continue;
    const artifact = document(diff.path, diff.newText, diff.canonical);
    if (artifact) found.push(artifact);
  }
  // Claude Write and pi/Gemini write tools can carry full contents only in rawInput. Unlike
  // Edit/apply_patch's snippets, these names describe a whole-file replacement. Completion is
  // required; this never reads paths, guesses shell redirections, or reconstructs patch hunks.
  if (WRITE.test(tool.title) && tool.inputSummary) {
    try {
      const input: unknown = JSON.parse(tool.inputSummary);
      if (input && typeof input === "object") {
        const fields = input as Record<string, unknown>;
        const path = fields.file_path ?? fields.path;
        if (typeof path === "string" && typeof fields.content === "string") {
          const canonical = tool.inputPath?.path === path ? tool.inputPath.canonical : undefined;
          const artifact = document(path, fields.content, canonical);
          if (artifact && !found.some((item) => artifactPath(item) === (canonical ?? path))) found.push(artifact);
        }
      }
    } catch {
      // Malformed recorded input cannot describe a document.
    }
  }
  return found;
}

export function writtenArtifacts(row: AcpmuxRow): Artifact[] {
  const found: Artifact[] = [];
  for (const item of row.items ?? []) {
    if (!item.tool) continue;
    let artifacts = cached.get(item.tool);
    if (!artifacts) {
      artifacts = readWrites(item.tool);
      cached.set(item.tool, artifacts);
    }
    found.push(...artifacts);
  }
  return found;
}
