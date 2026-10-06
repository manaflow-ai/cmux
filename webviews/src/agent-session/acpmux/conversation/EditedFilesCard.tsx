// The card that closes a turn which edited files: "Edited App.tsx +12 -3" (or "Edited 4 files"
// over the first three), then View changes. No Undo: asking the agent to revert let it run any
// command (git checkout) and lose edits made after the turn. Undo returns as a host revert that
// checks each file still holds the turn's bytes.
import { useMemo, useState } from "react";
import { turnFiles, type TurnFile } from "../diff";
import { ChevronDown, DiffFile } from "../changeIcons";
import { Counts } from "../changes/Counts";
import { useT } from "../i18n";
import { plainEditLabels, type AcpmuxRow } from "../model";

export const EDITED_FILES_SHOWN = 3;

/// `onOpenDiff` opens the turn's changes, at `path` when given; focus returns to `opener`.
export function EditedFilesCard({
  row,
  onOpenDiff,
}: {
  row: AcpmuxRow;
  onOpenDiff?: (rowId: string, path?: string, opener?: HTMLElement) => void;
}) {
  const t = useT();
  const [showAll, setShowAll] = useState(false);
  const edits = (row.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");
  const files = useMemo(() => turnFiles([row]), [row]);
  // An edit whose tool call carried no diff still lists, without counts.
  const plain = plainEditLabels(edits);
  const entries: { key: string; file?: TurnFile; text?: string }[] = [
    ...files.map((file) => ({ key: file.path, file })),
    ...plain.map((text, index) => ({ key: `plain-${index}`, text })),
  ];
  const total = entries.length;
  const additions = files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
  const single = total === 1 && files.length === 1 ? files[0] : undefined;
  const shown = single ? [] : showAll ? entries : entries.slice(0, EDITED_FILES_SHOWN);
  const more = single ? 0 : total - shown.length;
  const reviewable = onOpenDiff && files.length > 0;
  const title = single
    ? t("tools.edited.file", { file: single.path.split("/").pop() ?? single.path })
    : total === 1
      ? t("edited.one")
      : t("tools.edited.files", { n: total });
  return (
    <div className="acpmux-edited">
      <div className="acpmux-edited-head">
        <span className="acpmux-edited-icon">
          <DiffFile />
        </span>
        <div className="acpmux-edited-title">
          <div>{title}</div>
          {files.length > 0 && <Counts additions={additions} deletions={deletions} />}
        </div>
        {reviewable && (
          <button
            type="button"
            className="acpmux-review-changes"
            onClick={(event) => onOpenDiff(row.id, single?.path, event.currentTarget)}
          >
            {t("edited.view")}
          </button>
        )}
      </div>
      {shown.map((entry) => {
        if (!entry.file)
          return (
            <div className="acpmux-edited-file" key={entry.key}>
              <span className="acpmux-edited-path">{entry.text}</span>
            </div>
          );
        const file = entry.file;
        const slash = file.displayPath.lastIndexOf("/");
        const label = (
          <>
            <span className="acpmux-edited-path" title={file.path}>
              <span className="acpmux-edited-dir">{file.displayPath.slice(0, slash + 1)}</span>
              <span className="acpmux-edited-base">{file.displayPath.slice(slash + 1)}</span>
            </span>
            <Counts additions={file.additions} deletions={file.deletions} />
          </>
        );
        return onOpenDiff ? (
          <button
            type="button"
            className="acpmux-edited-file"
            key={entry.key}
            onClick={(event) => onOpenDiff(row.id, file.path, event.currentTarget)}
          >
            {label}
          </button>
        ) : (
          <div className="acpmux-edited-file" key={entry.key}>
            {label}
          </div>
        );
      })}
      {(more > 0 || showAll) && !single && total > EDITED_FILES_SHOWN && (
        <button
          type="button"
          className="acpmux-edited-more"
          aria-expanded={showAll}
          onClick={() => setShowAll(!showAll)}
        >
          {showAll ? t("edited.fewer") : more === 1 ? t("edited.more.one") : t("edited.more.other", { n: more })}
          <ChevronDown width={14} height={14} style={showAll ? { transform: "rotate(180deg)" } : undefined} />
        </button>
      )}
    </div>
  );
}
