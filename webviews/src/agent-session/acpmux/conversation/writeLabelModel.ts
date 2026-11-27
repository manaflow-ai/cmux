import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";
import { editedPaths } from "../toolPaths";
import { canonicalCall } from "../toolNames";

export type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The names harnesses give a call that writes a whole file: Claude Code's Write (and acpmux's own
/// "Write <file>" for a Codex patch that adds one), opencode's and pi's write, Gemini's write_file
/// ("Writing to <file>", toolNames.ts).
const WRITE_NAMES = /^(write|write_file|writefile|create_file)$/i;

export type WriteCall = { path?: string; counts?: { additions: number; deletions?: number } };

/// What a file-writing call wrote: its file, when it names one yet, and its counts (see above).
/// Undefined for any other call, and for a Write that names its file but waits on a permission
/// (`pending`), which keeps its own title, as an edit awaiting permission does (cx-p5fgx). A pending
/// Write with no input yet is one Claude Code named as its block started: the model is writing it.
export function writeCall(tool: Tool): WriteCall | undefined {
  if (tool.kind !== "edit" && tool.kind !== "fileChange") return undefined;
  const name = tool.title.trim().split(/\s+/, 1)[0] ?? "";
  if (!WRITE_NAMES.test(name) && canonicalCall(tool)?.tool !== "write") return undefined;
  const path = editedPaths(tool)[0] ?? tool.diffs?.[0]?.path;
  if (tool.status === "pending" && path) return undefined;
  if (tool.status !== "completed") return { path };
  const files = toolFiles([tool], { known: true });
  const file = files.find((entry) => entry.path === path) ?? (files.length === 1 ? files[0] : undefined);
  if (!file) return { path };
  return {
    path,
    counts: file.created ? { additions: file.additions } : { additions: file.additions, deletions: file.deletions },
  };
}
