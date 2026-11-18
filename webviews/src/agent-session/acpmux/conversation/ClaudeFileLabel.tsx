// A one-file tool row as Claude Code desktop draws it: the verb in bold ("Edit", "Write"), then the
// file's path from the chat's folder in a mono chip ("src/api/client.ts"), the counts after it
// (claudeLook.css). The verb comes from the translated line ("Edit {file}"), split where the file goes,
// so a language whose file leads keeps its own order.
import { useContext } from "react";
import { SessionCwdContext } from "../turnChanges/sessionRows";

/// `path` as the chat's folder sees it: relative under `cwd`, else as given.
export function chatRelativePath(path: string, cwd?: string): string {
  const folder = cwd?.replace(/\/+$/, "");
  if (folder && path.startsWith(`${folder}/`)) return path.slice(folder.length + 1);
  return path;
}

/// `line` is the translated line with "\u0000" where the file goes ("Edit \u0000").
export function ClaudeFileLabel({ line, path, full }: { line: string; path: string; full?: string }) {
  const cwd = useContext(SessionCwdContext);
  const [before = "", after = ""] = line.split("\u0000");
  const shown = chatRelativePath(path, cwd);
  return (
    <span className="cv-claude-file-label">
      {before.trim() && <span className="cv-claude-verb">{before.trim()}</span>}
      {before.trim() && " "}
      <code className="cv-claude-chip cv-tool__file" data-path={full} title={full ?? path}>
        {shown}
      </code>
      {after.trim() && <span className="cv-claude-verb"> {after.trim()}</span>}
    </span>
  );
}
