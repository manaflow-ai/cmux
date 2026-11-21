// Which calls read one file, and that file's full path (ReadLabel.tsx draws them). A harness's own
// read tool (Claude Code's Read, Codex's read, Gemini's read_file) or a finished shell line the action
// table names a read of one file (`sed -n 94,104p a.swift`, `cat a.swift`, commandActions.ts).
import type { AcpmuxActivity } from "../model";
import { canonicalCall } from "../toolNames";
import { toolImages } from "../toolImages";
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

/// The one file `tool` read, as the call named it; undefined for any other call and for a failed read.
/// A shell counts only once it finished without failing (until then it reads as the line that runs,
/// #36940), and only a line whose named step is the whole of it (no `… &&` after the read).
export function readPath(tool: Tool): string | undefined {
  if (tool.kind === "execute" && tool.command) return shellRead(tool, tool.command);
  const path = harnessRead(tool);
  // A harness's parse of a shell line that kept its variable (Codex's "Read $f" at `$f`, for `for f in
  // a b; do cat $f; done`) reads as its command does, as its label does (toolPaths.ts `toolLabel`):
  // a row never shows a `$f` (Leo, 2026-11-21: "this is not a good enough tool call heading that we
  // have derived").
  if (path !== undefined && UNEXPANDED.test(path)) return tool.command ? shellRead(tool, tool.command) : undefined;
  return path;
}

/// A `$name` or `${name}` a path shows as written.
const UNEXPANDED = /\$\{?[A-Za-z_]/;

function shellRead(tool: Tool, command: string): string | undefined {
  if (running(tool) || failed(tool)) return undefined;
  // A pipe's later step filters what the read printed (`cat build.log | grep error`): the row
  // keeps its output to open.
  if (command.includes("|")) return undefined;
  const action = commandAction(command);
  if (action?.key !== "command.read" || action.more || action.files?.length !== 1) return undefined;
  return action.files[0];
}

function harnessRead(tool: Tool): string | undefined {
  // A failed read keeps its opening (a hook's reason shows only inside it), and a call that read
  // several files (Gemini's read_many_files) keeps its own row.
  if (failed(tool)) return undefined;
  // A read that returned an image (a screenshot, a PNG) opens to it, as its row did before.
  if (toolImages(tool).length > 0) return undefined;
  const call = canonicalCall(tool);
  if (call?.tool !== "read") return undefined;
  const paths = editedPaths(tool);
  if (paths.length > 1) return undefined;
  return paths[0] ?? call.input.path;
}

/// `path` as a full path for its hover: an absolute one as it is, a relative one from the chat's
/// folder. After any `cd` the line ran elsewhere (`cd ..`, `cd $D`, `cd /tmp;`), so the path shows as
/// the line wrote it.
export function readFullPath(path: string, tool: Tool, cwd?: string): string {
  if (path.startsWith("/") || path.startsWith("~") || !cwd) return path;
  if (tool.command && (commandFolder(tool.command).folder || /(?:^|[;&|(]\s*)cd(?:\s|$)/.test(tool.command)))
    return path;
  return `${cwd.replace(/\/+$/, "")}/${path.replace(/^\.\//, "")}`;
}
