// The card that closes a turn which edited files: a small diff glyph, "Edited 2 files" with the
// totals, then Undo and View changes; under it one row per file in monospace (the dimmed folder,
// the name, its counts). A card for one file has no rows: its title or chevron opens that file's
// diff in the card (EditDiff, the transcript's edit view), built from the tool calls, so a new file
// or one outside any repository shows too. The data is turnChanges/model.ts; this file is only its view.
//
// Undo is a host revert (`turn.undo`): the host puts a file back only while it still holds the
// turn's last bytes, and moves a file the turn created to the Trash. The Undo click asks the host
// what it would do; nothing is written until the confirmation's Undo. Never the agent, never git.
//
// cmux.json `agentPane.editedFiles.*` (turnChanges/settings.ts): `show` always, collapsed (the
// header only, a chevron shows the rows) or never (the plain tool rows); `maxRows` rows before
// "Show N more"; `scope` turn, or session (one card, at the session's latest edit).
import { useContext, useMemo, useState, type ReactNode } from "react";
import { commonDirectory, turnFiles, turnPathsOnly, type PathRef, type TurnFile } from "../diff";
import { ChevronDown } from "../changeIcons";
import { Counts } from "../changes/Counts";
import { TurnCountsContext } from "../changes/TurnCountsContext";
import { namesCheckpointFile, outsideRepository, turnCounts } from "../changes/turnCheckpoint";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { pathKey, plainEditLabels, type AcpmuxRow } from "../model";
import { turnChanges, type EditedFile, type UndoStatus } from "../turnChanges/model";
import { SessionEditsContext } from "../turnChanges/sessionRows";
import { useEditedFilesSettings } from "../turnChanges/settings";
import { applyUndo, cancelUndo, checkUndo, useUndoState, type UndoState } from "../turnChanges/undoStore";
import { setCardOpen, useCardOpen } from "../turnChanges/openStore";
import { FindReveal, isRevealRow } from "./chatFind";
import { HEADER_TOGGLE_ATTRIBUTE, headerToggleClick } from "./headerToggle";
import { EditDiff } from "./EditDiff";
import { Undo } from "./icons";
import { ToolRows } from "./TurnRows";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { useTranscriptReadOnly } from "./readOnly";

/// `onOpenDiff` opens the turn's changes, at `path` when given; focus returns to `opener`.
/// Find in Chat's reveal for `row` only: the card draws outside ToolRows (which passes the reveal to
/// its match's row alone), under the transcript-wide one, and a diff opens on the reveal it sees.
function OwnFindReveal({ row, children }: { row: AcpmuxRow; children: ReactNode }) {
  const reveal = useContext(FindReveal);
  return (
    <FindReveal.Provider value={reveal && isRevealRow(row, reveal) ? reveal : undefined}>
      {children}
    </FindReveal.Provider>
  );
}

export function EditedFilesCard({
  row,
  sessionId,
  onOpenDiff,
}: {
  row: AcpmuxRow;
  sessionId?: string;
  onOpenDiff?: (rowId: string, path?: string, opener?: HTMLElement) => void;
}) {
  const settings = useEditedFilesSettings();
  const sessionEdits = useContext(SessionEditsContext);
  // Session scope: the latest edited-files row draws one card for the session; earlier ones draw
  // their plain tool rows.
  const latest = sessionEdits?.at(-1)?.id;
  const own = useMemo(() => [row], [row]);
  if (settings.show === "never" || (settings.scope === "session" && sessionEdits && latest !== row.id))
    return <ToolRows row={row} sessionId={sessionId} />;
  const rows = settings.scope === "session" && sessionEdits ? sessionEdits : own;
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
  // Derived on every render: the host's setting can arrive after the card mounts.
  const userOpened = useCardOpen(row.id);
  const open = settings.show !== "collapsed" || userOpened;
  const setOpen = (value: boolean) => setCardOpen(row.id, value);
  // A one-file card's diff, open or not, kept by row like the rows' open state.
  const diffKey = `${row.id}\u0000diff`;
  const diffOpen = useCardOpen(diffKey);
  // It opens and closes in the transcript's fold, the card's line held where it was clicked.
  const diff = useAnchoredCollapse({ open: diffOpen, onOpenChange: (next) => setCardOpen(diffKey, next) });
  const toggleDiff = diff.toggle;
  const edits = rows.flatMap((one) =>
    (one.items ?? []).filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange"),
  );
  const toolFiles = useMemo(() => turnFiles([...rows]), [rows]);
  // An edit whose tool call carried no diff, or a Write whose old contents are unknown: a path
  // without counts.
  const labels = plainEditLabels(edits);
  const pathsOnly = useMemo(() => turnPathsOnly(rows), [rows]);
  // Once the turn's checkpoint has loaded, its files and counts replace the tool calls' (turn scope).
  const countsFor = useContext(TurnCountsContext);
  const counts = useMemo(
    () => (countsFor && rows.length === 1 ? countsFor(row.id, toolFiles, pathsOnly) : turnCounts(toolFiles, undefined)),
    [countsFor, row.id, rows.length, toolFiles, pathsOnly],
  );
  const files = counts.files;
  // Undo works from the tool calls' full texts, by the paths the agent wrote.
  const changes = useMemo(() => turnChanges(row.id, rows, toolFiles), [row.id, rows, toolFiles]);
  const undoState = useUndoState(row.id);
  // Those list unless a listed file is that file: the same canonical path (model.ts `pathKey`), or
  // the same path when acpmux recorded none. Once the checkpoint loads, its files are the
  // repository's: only a path outside it stays (a /tmp file), as for the tool calls' diffs, and a
  // failed call's, which no checkpoint file covers unless a later call changed that same file: a
  // call that succeeded on that file lists wherever its file lists, and any other path is that
  // file only by `namesCheckpointFile` (/tmp/x is /private/tmp/x, but docs/x is not x).
  const same = (entry: PathRef) => (file: PathRef) => pathKey(file) === pathKey(entry);
  const plain =
    counts.files === toolFiles
      ? labels.filter((entry) => !entry.path || !files.some(same({ ...entry, path: entry.path })))
      : [
          ...outsideRepository(
            labels.flatMap((entry) => (entry.path && !entry.failed ? [{ ...entry, path: entry.path }] : [])),
            counts.root,
            files,
          ),
          ...labels.filter((entry) => {
            if (!entry.failed) return false;
            if (!entry.path) return true;
            const named = { ...entry, path: entry.path };
            return !(
              toolFiles.some(same(named)) ||
              pathsOnly.some(same(named)) ||
              files.some((file) => namesCheckpointFile(named, file, counts.root))
            );
          }),
        ];
  const entries: { key: string; file?: TurnFile; path?: string; failed?: true }[] = [
    ...files.map((file) => ({ key: file.path, file })),
    ...plain.map((entry) => ({ key: `plain-${entry.key}`, path: entry.path, failed: entry.failed })),
  ];
  // Undo leaves the paths listed without counts as they are: the page never had their old text.
  const kept = pathsOnly
    .filter((entry) => !toolFiles.some((file) => pathKey(file) === pathKey(entry)))
    .map((entry) => entry.path);
  const total = entries.length;
  const single = total === 1 && files.length === 1 ? files[0] : undefined;
  const limit = settings.maxRows;
  const shown = single || !open ? [] : showAll ? entries : entries.slice(0, limit);
  const more = single ? 0 : total - shown.length;
  const reviewable = onOpenDiff && files.length > 0;
  // Read only, Undo would write the owner's files.
  const readOnly = useTranscriptReadOnly();
  const undoable = !readOnly && row.ended === true && changes.files.some((file) => file.undo.kind !== "cannot");
  const title = single
    ? t("tools.edited.file", { file: single.path.split("/").pop() ?? single.path })
    : total === 1
      ? t("edited.one")
      : t("tools.edited.files", { n: total });
  // What a click anywhere on the header does: a one-file card opens its diff, a folded card its rows.
  const headToggle = single
    ? toggleDiff
    : total > 0 && settings.show === "collapsed"
      ? () => setOpen(!open)
      : undefined;
  // The host answers for the path Undo sent (turnChanges/model.ts `undoPath`), which may be another
  // spelling of the row's.
  const status = (file: TurnFile) =>
    fileStatus(undoState, changes.files.find((edited) => edited.key === pathKey(file))?.path ?? file.path);
  return (
    <div className="acpmux-edited">
      {/* The whole header is a wider mouse target for the chevron's toggle, edge to edge
          (headerToggle.ts); the chevron is the keyboard and screen reader control. */}
      {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions */}
      <div
        className="acpmux-edited-head"
        ref={single ? diff.headerRef : undefined}
        {...(headToggle ? { [HEADER_TOGGLE_ATTRIBUTE]: "" } : {})}
        // A control of its own for the transcript's gap selection (#26704), as the title was.
        data-interactive={headToggle ? "" : undefined}
        onClick={headToggle ? headerToggleClick(headToggle) : undefined}
      >
        <span className="acpmux-edited-icon">
          <PlusMinus />
        </span>
        <div className="acpmux-edited-title">
          <div>{title}</div>
          <div className="acpmux-edited-sub">
            {files.length > 0 && <Counts additions={counts.additions} deletions={counts.deletions} />}
            {counts.outside && <span className="acpmux-edited-outside">{t("turn.outside.card")}</span>}
          </div>
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
        {single && (
          <button
            type="button"
            className="acpmux-edited-toggle"
            aria-expanded={diffOpen}
            aria-label={diffOpen ? t("changes.collapseFile") : t("changes.expandFile")}
            onClick={toggleDiff}
          >
            <ChevronDown width={14} height={14} style={diffOpen ? { transform: "rotate(180deg)" } : undefined} />
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
          kept={kept}
          onUndo={() => void applyUndo(row.id, changes.files)}
          onCancel={() => cancelUndo(row.id)}
          t={t}
        />
      )}
      {single && undoState.phase === "done" && (
        <FileStatus status={status(single)} path={single.path} rowId={row.id} onOpenDiff={onOpenDiff} t={t} />
      )}
      {single && diff.present && (
        <div {...diff.bodyProps}>
          <div className="acpmux-edited-diff">
            <OwnFindReveal row={row}>
              <EditDiff file={single} />
            </OwnFindReveal>
          </div>
        </div>
      )}
      {shown.map((entry) => {
        if (!entry.file) {
          // An edit with no diff: its path (dimmed folder, then the name), or "Unknown file".
          const path = entry.path;
          const cut = path ? path.replace(/\/+$/, "").lastIndexOf("/") : -1;
          return (
            <div className="acpmux-edited-file" key={entry.key}>
              {path ? (
                <span className="acpmux-edited-path" data-path={path}>
                  <DirPart dir={path.slice(0, cut + 1)} />
                  <span className="acpmux-edited-base">{path.slice(cut + 1)}</span>
                </span>
              ) : (
                <span className="acpmux-edited-path">{t("edited.unknownFile")}</span>
              )}
              {entry.failed && <span className="acpmux-edited-failed">{t("tools.failed")}</span>}
            </div>
          );
        }
        const file = entry.file;
        const slash = file.displayPath.lastIndexOf("/");
        const label = (
          <>
            <span className="acpmux-edited-path" data-path={file.path}>
              <DirPart dir={file.displayPath.slice(0, slash + 1)} />
              <span className="acpmux-edited-base">{file.displayPath.slice(slash + 1)}</span>
            </span>
            <Counts additions={file.additions} deletions={file.deletions} />
          </>
        );
        const done = undoState.phase === "done" ? status(file) : undefined;
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
          <ChevronDown width={12} height={12} style={showAll ? { transform: "rotate(180deg)" } : undefined} />
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
    <button type="button" className="acpmux-edited-undo" disabled={busy} onClick={() => void checkUndo(rowId, files)}>
      {state.phase === "undoing"
        ? t("edited.undoing")
        : state.phase === "failed"
          ? t("edited.undoFailed")
          : t("edited.undo")}
      <Undo size={12} />
    </button>
  );
}

function UndoConfirm({
  summary,
  kept,
  onUndo,
  onCancel,
  t,
}: {
  summary: { undo: number; changed: number; cannot: number };
  kept: readonly string[];
  onUndo: () => void;
  onCancel: () => void;
  t: Translate;
}) {
  const language = usePaneLanguage();
  // Named from their shared directory, as the card's rows are: a/x.ts and b/x.ts, not x.ts twice.
  const base = commonDirectory([...kept]).length;
  const names = kept.map((path) => path.slice(base));
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
        {names.length > 0 && (
          <div className="acpmux-edited-confirm-skip acpmux-edited-confirm-kept">
            {names.length === 1
              ? t("edited.undoSkip.unknown.one", { file: names[0]! })
              : t("edited.undoSkip.unknown.other", {
                  files: new Intl.ListFormat(language, { type: "conjunction" }).format(names),
                })}
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

/// The directory part of a row's path. Too long for the row, it drops its middle: the first segment
/// stays, and the rest shows its end ("src/…/net/").
function DirPart({ dir }: { dir: string }) {
  if (!dir) return null;
  const cut = dir.indexOf("/") + 1;
  const head = dir.slice(0, cut);
  const tail = dir.slice(cut);
  return (
    <span className="acpmux-edited-dir">
      <span className="acpmux-edited-dir-head">{head}</span>
      {tail && (
        <span className="acpmux-edited-dir-tail">
          <bdi>{tail}</bdi>
        </span>
      )}
    </span>
  );
}

const PlusMinus = () => (
  <svg
    width={14}
    height={14}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.4}
    strokeLinecap="round"
    aria-hidden="true"
  >
    <path d="M8 2.5v6M5 5.5h6M5 12.5h6" />
  </svg>
);
