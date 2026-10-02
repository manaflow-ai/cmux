import { use } from "react";
import { ChatActionsContext } from "./actions";
import { ChevronDown, DiffFile, Undo } from "./icons";

export type EditedFile = { path: string; additions: number; deletions: number };

export type EditedFilesCardProps = {
  files: EditedFile[];
  /** Number of files shown before "Show N more files". */
  visible?: number;
  /** Totals; default sums `files`. */
  additions?: number;
  deletions?: number;
  /** Total count for the title; default `files.length`. */
  count?: number;
  /** The turn the card closes, for View changes. */
  turnId?: string;
};

/** "Edited N files" card with Undo / View changes and the per-file list. */
export function EditedFilesCard({ files, visible = 3, additions, deletions, count, turnId }: EditedFilesCardProps) {
  const { viewChanges } = use(ChatActionsContext);
  const add = additions ?? files.reduce((n, f) => n + f.additions, 0);
  const del = deletions ?? files.reduce((n, f) => n + f.deletions, 0);
  const total = count ?? files.length;
  // One edited file: the card names it and lists nothing (live-getappstate-bottom).
  const single = total === 1 && files.length === 1 ? files[0] : undefined;
  const shown = single ? [] : files.slice(0, visible);
  const more = single ? 0 : total - Math.min(visible, files.length);
  return (
    <div className="cv-edited">
      <div className="cv-edited__head">
        <span className="cv-edited__icon">
          <DiffFile size={20} strokeWidth={1.1} className="cv-edited__glyph" />
        </span>
        <div className="cv-edited__title">
          <div>
            {single
              ? `Edited ${single.path.slice(single.path.lastIndexOf("/") + 1)}`
              : `Edited ${total} ${total === 1 ? "file" : "files"}`}
          </div>
          <div className="cv-counts">
            <span className="cv-add">+{add}</span> <span className="cv-del">-{del}</span>
          </div>
        </div>
        <span className="cv-edited__undo">
          Undo <Undo size={14} strokeWidth={1.2} />
        </span>
        <button
          type="button"
          className="cv-edited__view"

          onClick={turnId && viewChanges ? () => viewChanges(turnId) : undefined}
        >
          View changes
        </button>
      </div>
      {shown.map((f) => {
        const slash = f.path.lastIndexOf("/");
        return (
          <div key={f.path} className="cv-edited__file">
            <span className="cv-edited__path">
              <span className="cv-edited__dir">{f.path.slice(0, slash + 1)}</span>
              <span className="cv-edited__base">{f.path.slice(slash + 1)}</span>
            </span>
            <span className="cv-counts">
              <span className="cv-add">+{f.additions}</span> <span className="cv-del">-{f.deletions}</span>
            </span>
          </div>
        );
      })}
      {more > 0 && (
        <div className="cv-edited__more">
          Show {more} more {more === 1 ? "file" : "files"}
          <ChevronDown size={14} strokeWidth={1.2} />
        </div>
      )}
    </div>
  );
}
