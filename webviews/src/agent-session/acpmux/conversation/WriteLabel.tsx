// A file-writing call's line, as an edit's reads ("Edited App.tsx +12 -3"): "Writing notes.md"
// while it runs, "Wrote notes.md" once done, with the counts its edits line would show. Claude Code
// names its Write as the block starts, before any input ("Write"), and a row read that bare name
// until the call finished. The file name opens the file through the host (`link.openPath`, as a
// path chip in a reply does); a failed write reads "Writing notes.md failed". Without a path yet:
// "Writing a file", "Wrote a file".
//
// Counts, as the edited-files card counts them (diff.ts `toolFiles` with `known`): a created file
// "+N" (every line it wrote), an overwrite whose old text is known its real "+a -d", and none for an
// overwrite of unknown old contents (model.ts `contentsUnknown`: its text is not lines added) or a
// call whose input carries text but no diff, which may have been either.
import { useContext, type KeyboardEvent, type MouseEvent } from "react";
import { callChipHost } from "../chips/host";
import { isDeniedPath } from "../chips/paths";

import type { Translate } from "../i18n";

import { SessionCwdContext } from "../turnChanges/sessionRows";
import { fileName } from "./toolGroups";
import { ToolLabel } from "./ToolVerb";
import { leadingVerb } from "./toolVerbModel";
import { useTranscriptReadOnly } from "./readOnly";
import { type Tool, type WriteCall } from "./writeLabelModel";
/// The line of a file-writing call (`writeCall`): its verb, the file name that opens it, and once
/// it finished its counts. A failed call keeps the running verb; its row adds "failed".
export function WriteLabel({ tool, write, t }: { tool: Tool; write: WriteCall; t: Translate }) {
  const cwd = useContext(SessionCwdContext);
  const done = tool.status === "completed";
  if (!write.path) return <ToolLabel text={t(done ? "tools.wrote.unnamed" : "tools.writing.unnamed")} />;
  const [before, after = ""] = t(done ? "tools.wrote.file" : "tools.writing.file", { file: "\u0000" }).split("\u0000");
  const counts = done ? write.counts : undefined;
  const name = <WriteFileName path={write.path} cwd={cwd} />;
  return (
    <>
      {/* "Wrote" in the run's verb column (ToolVerb.tsx), the file after it. */}
      <ToolLabel verb={after ? undefined : leadingVerb(before ?? "")} subject={name}>
        {before}
        {name}
        {after}
      </ToolLabel>
      {counts && (
        <span className="cv-tool__counts">
          <span className="cv-edit-diff__add">+{counts.additions}</span>
          {counts.deletions !== undefined && <span className="cv-edit-diff__del">-{counts.deletions}</span>}
        </span>
      )}
    </>
  );
}

/// The written file's name. A click opens it through the host, which checks the path again, without
/// opening or closing the row it sits on; a path no chip opens (a key, `.env`) is plain text. Inside
/// the row's <button> its children are presentational, so VoiceOver reads the row, not the link: the
/// file opens by pointer and keyboard focus, and from the row's context menu (Open, `data-path`).
function WriteFileName({ path, cwd }: { path: string; cwd?: string }) {
  const name = fileName(path);
  const folder = cwd?.replace(/\/+$/, "");
  const full = path.startsWith("/") || path.startsWith("~") || !folder ? path : `${folder}/${path}`;
  // Read only, the file is on the owner's machine: its name, never a link.
  const readOnly = useTranscriptReadOnly();
  if (isDeniedPath(full) || readOnly) return <span className="cv-tool__file">{name}</span>;
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
