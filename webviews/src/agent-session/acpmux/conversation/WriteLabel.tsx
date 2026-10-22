// A file-writing call's line, as an edit's reads ("Edited App.tsx +12 -3"): "Writing notes.md"
// while it runs, "Wrote notes.md +18" once done, with the lines it wrote in the diff's add color.
// Claude Code names its Write as the block starts, before any input ("Write"), and a row read
// that bare name until the call finished. The file name opens the file through the host
// (`link.openPath`, as a path chip in a reply does); a failed write reads "Writing notes.md failed".
// Without a path yet: "Writing a file", "Wrote a file".
import { useContext, type KeyboardEvent, type MouseEvent } from "react";
import { callChipHost } from "../chips/host";
import { isDeniedPath } from "../chips/paths";
import type { Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { editedPaths } from "../toolPaths";
import { SessionCwdContext } from "../turnChanges/sessionRows";
import { lineCount } from "./BlockParts";
import { fileName, isRunning } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The names harnesses give a call that writes a whole file: Claude Code's Write (and acpmux's own
/// "Write <file>" for a Codex patch that adds one), opencode's and pi's write, Gemini's write_file.
const WRITE_NAMES = /^(write|write_file|writefile|create_file)$/i;
/// Input fields that hold the text a write puts in its file.
const CONTENT_KEYS = ["content", "contents", "file_text", "text"];

/// What a file-writing call wrote: its file, when it names one yet, and the number of lines it
/// wrote, when the call carries its text. Undefined for any other call.
export function writeCall(tool: Tool): { path?: string; lines?: number } | undefined {
  if (tool.kind !== "edit" && tool.kind !== "fileChange") return undefined;
  const name = tool.title.trim().split(/\s+/, 1)[0] ?? "";
  if (!WRITE_NAMES.test(name)) return undefined;
  const path = editedPaths(tool)[0] ?? tool.diffs?.[0]?.path;
  const diff = tool.diffs?.find((change) => !path || change.path === path);
  const text = diff ? diff.newText : inputText(tool.inputSummary);
  return { path, lines: text === undefined ? undefined : lineCount(text) };
}

function inputText(summary: string | undefined): string | undefined {
  if (!summary) return undefined;
  try {
    const input: unknown = JSON.parse(summary);
    if (!input || typeof input !== "object") return undefined;
    for (const key of CONTENT_KEYS) {
      const value = (input as Record<string, unknown>)[key];
      if (typeof value === "string") return value;
    }
  } catch {
    // A cut-off input has no whole text to count.
  }
  return undefined;
}

/// The line of a file-writing call (`writeCall`): its verb, the file name that opens it, and once
/// it finished the lines it wrote. A failed call keeps the running verb; its row adds "failed".
export function WriteLabel({ tool, write, t }: { tool: Tool; write: { path?: string; lines?: number }; t: Translate }) {
  const cwd = useContext(SessionCwdContext);
  const done = !isRunning(tool) && tool.status !== "failed";
  if (!write.path) return <>{t(done ? "tools.wrote.unnamed" : "tools.writing.unnamed")}</>;
  const [before, after = ""] = t(done ? "tools.wrote.file" : "tools.writing.file", { file: "\u0000" }).split("\u0000");
  return (
    <>
      {before}
      <WriteFileName path={write.path} cwd={cwd} />
      {after}
      {done && write.lines !== undefined && (
        <span className="cv-tool__counts">
          <span className="cv-edit-diff__add">+{write.lines}</span>
        </span>
      )}
    </>
  );
}

/// The written file's name. A click opens it through the host, which checks the path again, without
/// opening or closing the row it sits on; a path no chip opens (a key, `.env`) is plain text.
function WriteFileName({ path, cwd }: { path: string; cwd?: string }) {
  const name = fileName(path);
  const folder = cwd?.replace(/\/+$/, "");
  const full = path.startsWith("/") || path.startsWith("~") || !folder ? path : `${folder}/${path}`;
  if (isDeniedPath(full)) return <span className="cv-tool__file">{name}</span>;
  const open = (event: MouseEvent | KeyboardEvent) => {
    event.stopPropagation();
    event.preventDefault();
    void callChipHost("link.openPath", { path: full });
  };
  return (
    <span
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- it sits inside the row's toggle <button>, where an <a> or a <button> may not go, and opens through the host, not by navigation.
      role="link"
      tabIndex={0}
      className="cv-tool__file is-link"
      data-path={full}
      title={full}
      onClick={open}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") open(event);
      }}
    >
      {name}
    </span>
  );
}
