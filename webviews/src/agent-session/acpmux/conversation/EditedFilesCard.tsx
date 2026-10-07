// The card that closes a turn which edited files: a diff icon, "Edited 2 files" with the totals,
// then Undo and View changes; under it one row per file (the dimmed folder, the bold name, its
// counts). The data is turnChanges/model.ts; this file is only its view.
//
// Undo is a host revert (`turn.undo`): the host puts a file back only while it still holds the
// turn's last bytes, and moves a file the turn created to the Trash. The Undo click asks the host
// what it would do; nothing is written until the confirmation's Undo. Never the agent, never git.
//
// cmux.json `agentPane.editedFiles.*` (turnChanges/settings.ts): `show` always, collapsed (the
// header only, a chevron shows the rows) or never (the plain tool rows); `maxRows` rows before
// "Show N more"; `scope` turn, or session (one card, at the session's latest edit).
import { useContext, useMemo, useState } from "react";
import { turnFiles, type TurnFile } from "../diff";
import { ChevronDown, DiffFile } from "../changeIcons";
import { Counts } from "../changes/Counts";
import { TurnCountsContext } from "../changes/TurnCountsContext";
import { turnCounts } from "../changes/turnCheckpoint";
import { useT, type Translate } from "../i18n";
import { plainEditLabels, type AcpmuxRow } from "../model";
import { turnChanges, type EditedFile, type UndoStatus } from "../turnChanges/model";
import { SessionRowsContext, isEditRow } from "../turnChanges/sessionRows";
import { useEditedFilesSettings } from "../turnChanges/settings";
import { applyUndo, cancelUndo, checkUndo, useUndoState, type UndoState } from "../turnChanges/undoStore";
import { Undo } from "./icons";
import { ToolRows } from "./TurnRows";

/// `onOpenDiff` opens the turn's changes, at `path` when given; focus returns to `opener`.
export function EditedFilesCard({
  row,
  onOpenDiff,
}: {
  row: AcpmuxRow;
  onOpenDiff?: (rowId: string, path?: string, opener?: HTMLElement) => void;
}) {
  const settings = useEditedFilesSettings();
  const sessionRows = useContext(SessionRowsContext);
  // Session scope: the latest edited-files row draws one card for the session; earlier ones draw
  // their plain tool rows.
  const latest = useMemo(() => sessionRows && [...sessionRows].reverse().find(isEditRow)?.id, [sessionRows]);
  if (settings.show === "never" || (settings.scope === "session" && sessionRows && latest !== row.id))
    return <ToolRows row={row} />;
  const rows = settings.scope === "session" && sessionRows ? sessionRows.filter(isEditRow) : [row];
  return <Card row={row} rows={rows} onOpenDiff={onOpenDiff} />;
}

function Card({
  row,
  rows,
  onOpenDiff,
}: {
  row: AcpmuxRow;
  rows: readonly AcpmuxRow[];
  onOpenDiff?: (rowId: string, path?: string, opener?: HTMLElement) => void;
}) {
  const t = useT();
  const settings = useEditedFilesSettings();
  const [showAll, setShowAll] = useState(false);
  const [open, setOpen] = useState(settings.show !== "collapsed");
  const edits = rows.flatMap((one) =>
    (one.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange"),
  );
  const toolFiles = useMemo(() => turnFiles([...rows]), [rows]);
  // Once the turn's checkpoint has loaded, its files and counts replace the tool calls' (turn scope).
  const countsFor = useContext(TurnCountsContext);
  const counts = useMemo(
    () => (countsFor && rows.length === 1 ? countsFor(row.id, toolFiles) : turnCounts(toolFiles, undefined)),
    [countsFor, row.id, rows.length, toolFiles],
  );
  const files = counts.files;
  // Undo works from the tool calls' full texts, by the paths the agent wrote.
  const changes = useMemo(() => turnChanges(row.id, rows, toolFiles), [row.id, rows, toolFiles]);
  const undoState = useUndoState(row.id);
  // An edit whose tool call carried no diff still lists, without counts.
  const plain = counts.files === toolFiles ? plainEditLabels(edits) : [];
  const entries: { key: string; file?: TurnFile; text?: string }[] = [
    ...files.map((file) => ({ key: file.path, file })),
    ...plain.map((text, index) => ({ key: `plain-${index}`, text })),
  ];
  const total = entries.length;
  const single = total === 1 && files.length === 1 ? files[0] : undefined;
  const limit = settings.maxRows;
  const shown = single || !open ? [] : showAll ? entries : entries.slice(0, limit);
  const more = single ? 0 : total - shown.length;
  const reviewable = onOpenDiff && files.length > 0;
  const undoable = row.ended === true && changes.files.some((file) => file.undo.kind !== "cannot");
  const title = single
    ? t("tools.edited.file", { file: single.path.split("/").pop() ?? single.path })
    : total === 1
      ? t("edited.one")
      : t("tools.edited.files", { n: total });
  const status = (path: string) => fileStatus(undoState, path);
  return (
    <div className="acpmux-edited">
      <div className="acpmux-edited-head">
        <span className="acpmux-edited-icon">
          <DiffFile />
        </span>
        <div className="acpmux-edited-title">
          <div>{title}</div>
          {files.length > 0 && <Counts additions={counts.additions} deletions={counts.deletions} />}
          {counts.outside && <span className="acpmux-edited-outside">{t("turn.outside.card")}</span>}
        </div>
        {undoable && <UndoButton state={undoState} rowId={row.id} files={changes.files} t={t} />}
        {reviewable && (
          <button
            type="button"
            className="acpmux-review-changes"
            onClick={(event) => onOpenDiff(row.id, single?.path, event.currentTarget)}
          >
            {t("edited.view")}
          </button>
        )}
        {!single && total > 0 && settings.show === "collapsed" && (
          <button
            type="button"
            className="acpmux-edited-toggle"
            aria-expanded={open}
            aria-label={open ? t("edited.hideFiles") : t("edited.showFiles")}
            onClick={() => setOpen(!open)}
          >
            <ChevronDown width={14} height={14} style={open ? { transform: "rotate(180deg)" } : undefined} />
          </button>
        )}
      </div>
      {undoState.phase === "confirm" && (
        <UndoConfirm
          summary={undoState.summary}
          onUndo={() => void applyUndo(row.id, changes.files)}
          onCancel={() => cancelUndo(row.id)}
          t={t}
        />
      )}
      {single && undoState.phase === "done" && (
        <FileStatus status={status(single.path)} path={single.path} rowId={row.id} onOpenDiff={onOpenDiff} t={t} />
      )}
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
        const done = undoState.phase === "done" ? status(file.path) : undefined;
        return (
          <div className="acpmux-edited-entry" key={entry.key}>
            {onOpenDiff ? (
              <button
                type="button"
                className="acpmux-edited-file"
                onClick={(event) => onOpenDiff(row.id, file.path, event.currentTarget)}
              >
                {label}
              </button>
            ) : (
              <div className="acpmux-edited-file">{label}</div>
            )}
            {done && <FileStatus status={done} path={file.path} rowId={row.id} onOpenDiff={onOpenDiff} t={t} />}
          </div>
        );
      })}
      {open && (more > 0 || showAll) && !single && total > limit && (
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

/// What the done card says for a file: undone, changed since the turn, or not undoable.
type DoneStatus = "undone" | "changed" | "cannot";

function fileStatus(state: UndoState, path: string): DoneStatus {
  if (state.phase !== "done") return "cannot";
  const status: UndoStatus | undefined = state.result.get(path);
  if (status === "reverted" || status === "trashed") return "undone";
  return status === "changed" ? "changed" : "cannot";
}

function UndoButton({
  state,
  rowId,
  files,
  t,
}: {
  state: UndoState;
  rowId: string;
  files: readonly EditedFile[];
  t: Translate;
}) {
  if (state.phase === "done") {
    const undone = [...state.result.values()].filter((status) => status === "reverted" || status === "trashed").length;
    const total = files.length;
    return (
      <output className="acpmux-edited-undone">
        {undone === total ? t("edited.undone") : t("edited.undonePartial", { n: undone, total })}
      </output>
    );
  }
  const busy = state.phase === "checking" || state.phase === "undoing" || state.phase === "confirm";
  return (
    <button
      type="button"
      className="acpmux-edited-undo"
      disabled={busy}
      title={t("edited.undoHostLabel")}
      onClick={() => void checkUndo(rowId, files)}
    >
      {state.phase === "undoing"
        ? t("edited.undoing")
        : state.phase === "failed"
          ? t("edited.undoFailed")
          : t("edited.undo")}
      <Undo size={14} />
    </button>
  );
}

function UndoConfirm({
  summary,
  onUndo,
  onCancel,
  t,
}: {
  summary: { undo: number; changed: number; cannot: number };
  onUndo: () => void;
  onCancel: () => void;
  t: Translate;
}) {
  return (
    <div className="acpmux-edited-confirm" role="alertdialog" aria-label={t("edited.undo")}>
      <div className="acpmux-edited-confirm-text">
        <div>
          {summary.undo === 0
            ? t("edited.undoNothing")
            : summary.undo === 1
              ? t("edited.undoConfirm.one")
              : t("edited.undoConfirm.other", { n: summary.undo })}
        </div>
        {summary.changed > 0 && (
          <div className="acpmux-edited-confirm-skip">
            {summary.changed === 1
              ? t("edited.undoSkip.changed.one")
              : t("edited.undoSkip.changed.other", { n: summary.changed })}
          </div>
        )}
        {summary.cannot > 0 && (
          <div className="acpmux-edited-confirm-skip">
            {summary.cannot === 1
              ? t("edited.undoSkip.cannot.one")
              : t("edited.undoSkip.cannot.other", { n: summary.cannot })}
          </div>
        )}
      </div>
      <button type="button" className="acpmux-edited-cancel" onClick={onCancel}>
        {t("edited.cancel")}
      </button>
      {summary.undo > 0 && (
        <button type="button" className="acpmux-edited-undo acpmux-edited-undo-confirm" onClick={onUndo}>
          {t("edited.undo")}
        </button>
      )}
    </div>
  );
}

function FileStatus({
  status,
  path,
  rowId,
  onOpenDiff,
  t,
}: {
  status: DoneStatus;
  path: string;
  rowId: string;
  onOpenDiff?: (rowId: string, path?: string, opener?: HTMLElement) => void;
  t: Translate;
}) {
  return (
    <div className={`acpmux-edited-status acpmux-edited-status-${status}`}>
      <span>
        {status === "undone"
          ? t("edited.status.undone")
          : status === "changed"
            ? t("edited.status.changed")
            : t("edited.status.cannot")}
      </span>
      {status === "changed" && onOpenDiff && (
        <button
          type="button"
          className="acpmux-edited-viewdiff"
          onClick={(event) => onOpenDiff(rowId, path, event.currentTarget)}
        >
          {t("edited.viewDiff")}
        </button>
      )}
    </div>
  );
}
