// One edit's header in the changes view: name, badges, counts and the viewed toggle. It sits
// outside Pierre's diff so collapsing or marking a file keeps the focused button.
import React from "react";
import type { DiffEdit, TurnFile } from "../diff";
import { ChevronDown, Eye, FileTypeIcon } from "../changeIcons";
import { Counts } from "./Counts";
import { FileMenu } from "./FileMenu";

export type FileView = { collapsed: boolean; viewed: boolean };
export type FileActions = { toggleCollapsed: (path: string) => void; toggleViewed: (path: string) => void };

export function FileHeader({
  file,
  edit,
  index,
  view,
  on,
}: {
  file: TurnFile;
  edit: DiffEdit;
  index: number;
  view: FileView;
  on: FileActions;
}) {
  const slash = file.displayPath.lastIndexOf("/");
  const additions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "add").length, 0);
  const deletions = edit.hunks.reduce((sum, hunk) => sum + hunk.lines.filter((line) => line.type === "del").length, 0);
  return (
    <div className="acpmux-file-header" data-viewed={view.viewed ? "" : undefined}>
      <FileTypeIcon path={file.displayPath} />
      <button
        type="button"
        className="acpmux-fh-name"
        title={file.path}
        aria-expanded={!view.collapsed}
        onClick={() => on.toggleCollapsed(file.path)}
      >
        {slash >= 0 && <span className="acpmux-fh-dir">{file.displayPath.slice(0, slash + 1)}</span>}
        <span>{file.displayPath.slice(slash + 1)}</span>
        <ChevronDown className="acpmux-fh-chevron" width={14} height={14} />
      </button>
      {file.created && index === 0 && <span className="acpmux-fh-badge">New</span>}
      {file.deleted && <span className="acpmux-fh-badge">Deleted</span>}
      {file.edits.length > 1 && <span className="acpmux-fh-badge">{`Edit ${index + 1} of ${file.edits.length}`}</span>}
      <span className="acpmux-fh-spacer" />
      <Counts additions={additions} deletions={deletions} />
      <button
        type="button"
        className="acpmux-fh-btn"
        aria-label={view.viewed ? `Mark ${file.displayPath} as not viewed` : `Mark ${file.displayPath} as viewed`}
        aria-pressed={view.viewed}
        onClick={() => on.toggleViewed(file.path)}
      >
        <Eye />
      </button>
      <FileMenu
        path={file.path}
        name={file.displayPath}
        collapsed={view.collapsed}
        onToggleCollapsed={() => on.toggleCollapsed(file.path)}
      />
    </div>
  );
}
