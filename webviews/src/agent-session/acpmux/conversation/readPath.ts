// Which calls read one file, and that file's full path (ReadLabel.tsx draws them). A harness's own
// read tool (Claude Code's Read, Codex's read, Gemini's read_file) or a finished shell line the action
// table names a read of one file (`sed -n 94,104p a.swift`, `cat a.swift`, commandActions.ts).
import type { AcpmuxActivity } from "../model";
import { canonicalCall } from "../toolNames";
import { editedPaths } from "../toolPaths";
import { commandAction } from "./commandActions";
import { commandFolder } from "./commandFolder";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const running = (tool: Tool) =>
  tool.status === "pending" || tool.status === "in_progress" || tool.background?.state === "running";

const failed = (tool: Tool) =>
  tool.status === "failed" ||
  (tool.exitCode !== undefined && tool.exitCode !== 0) ||
  tool.background?.state === "failed";

/// The one file `tool` read, as the call named it; undefined for any other call. A shell counts only
/// once it finished without failing (until then it reads as the line that runs, #36940), and only a
/// line whose named step is the whole of it (no `… &&` after the read).
export function readPath(tool: Tool): string | undefined {
  if (tool.kind === "execute" && tool.command) {
    if (running(tool) || failed(tool)) return undefined;
    const action = commandAction(tool.command);
    if (action?.key !== "command.read" || action.more || action.files?.length !== 1) return undefined;
    return action.files[0];
  }
  const call = canonicalCall(tool);
  if (call?.tool !== "read") return undefined;
  return editedPaths(tool)[0] ?? call.input.path;
}

/// `path` as a full path for its hover: an absolute one as it is, a relative one from the chat's
/// folder. After a leading `cd` the line ran elsewhere (commandFolder.ts keeps only that folder's last
/// part), so the path shows as the line wrote it.
export function readFullPath(path: string, tool: Tool, cwd?: string): string {
  if (path.startsWith("/") || path.startsWith("~") || !cwd) return path;
  if (tool.command && commandFolder(tool.command).folder) return path;
  return `${cwd.replace(/\/+$/, "")}/${path.replace(/^\.\//, "")}`;
}

