// The card that closes a turn which edited files: one row, a small diff glyph, "Edited 2 files" with
// the totals, Undo, and a chevron. A click anywhere on the row opens the whole card into every file's
// diff, stacked as the diff viewer lists a turn (EditDiff, whole, each under its sticky repo-relative
// name with its own counts, Open in Changes in its corner), in one box at most 60% of the view tall
// that scrolls once. Opened, the card keeps the message column's width. While the closed head is hovered,
// its counts read what a click does: "View changes"; open, they stay the counts, the chevron alone closing it. A Markdown file (.md, .markdown) also has Open beside its name, or in the head of a
// card for one file: it shows the file in cmux's Markdown page beside the chat (writtenArtifacts.tsx
// `OpenWrittenMarkdown`), once per file however often the turn wrote it. The data is
// turnChanges/model.ts; this file is only its view.
//
// Undo is a host revert (`turn.undo`): the host puts a file back only while it still holds the
// turn's last bytes, and moves a file the turn created to the Trash. The Undo click asks the host
// what it would do; nothing is written until the confirmation's Undo. Never the agent, never git.
//
// cmux.json `agentPane.editedFiles.*` (turnChanges/settings.ts): `show` always or collapsed (the
// card, its one row until the reader opens it) or never (the plain tool rows); `scope` turn, or
// session (one card, at the session's latest edit).
import { useContext, useMemo, useState } from "react";
import { commonDirectory, turnFiles, turnPathsOnly, type PathRef, type TurnFile } from "../diff";
import { EditDiff } from "./EditDiff";
import { cornerAction } from "./cornerActions";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { Counts } from "../changes/Counts";
import { TurnCountsContext } from "../changes/TurnCountsContext";
import { namesCheckpointFile, outsideRepository, turnCounts } from "../changes/turnCheckpoint";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { pathKey, plainEditLabels, type AcpmuxRow } from "../model";
import { turnChanges, type EditedFile, type UndoStatus } from "../turnChanges/model";
import { SessionCwdContext, SessionEditsContext, useSessionBranch } from "../turnChanges/sessionRows";
import { useExperimentSwitch } from "../../../experiments/switches";
import { useEditedFilesSettings } from "../turnChanges/settings";
import { applyUndo, cancelUndo, checkUndo, useUndoState, type UndoState } from "../turnChanges/undoStore";
import { useDisclosure } from "./useDisclosure";
import { TurnFramesStrip } from "../liveFrames/TurnFramesStrip";
import { TurnShots } from "../turnChanges/TurnShotsPair";
import { HEADER_TOGGLE_ATTRIBUTE, headerToggleClick } from "./headerToggle";
import { ChevronDown, DiffFile, Undo } from "./icons";
import { Icon } from "../icons/Icon";
import { ToolRows } from "./TurnRows";
import { useTranscriptReadOnly } from "./readOnly";
import "./cardFit.css";
import { OpenWrittenMarkdown } from "./writtenArtifacts";
import { isMarkdownPath } from "./writtenArtifactsModel";
import "./EditedFilesCard.css";
import "./transcriptWorkLog.css";
import { intl } from "../../../ui/intl";
import { INSET_SCROLLER_ATTRIBUTE } from "../../../scrollers";
import { installStackWheel } from "./stackWheel";
import { installStackEdge } from "./stackEdge";

/// The file stack's wheel (stackWheel.ts) and the code's fade under each file name (stackEdge.ts), installed
/// while the stack is drawn. One function for every card, so a render does not install them again.
const stackWheel = (node: HTMLDivElement) => {
  const removeWheel = installStackWheel(node);
  const removeEdge = installStackEdge(node);
  return () => {
    removeWheel();
    removeEdge();
  };
};

/// `onOpenDiff` opens the turn's changes, at `path` when given; focus returns to `opener`.
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
  // `earlier`: not the chat's latest card (a lone card, with no session rows, is the latest). Every
  // card shows its Undo and View changes at rest, as the Codex app does (Lucas, 2026-11-14).
  return <Card row={row} rows={rows} earlier={Boolean(latest) && latest !== row.id} onOpenDiff={onOpenDiff} />;
}

function Card({
  row,
  rows,
  earlier,
  onOpenDiff,
}: {
  row: AcpmuxRow;
  rows: readonly AcpmuxRow[];
  earlier: boolean;
  onOpenDiff?: (rowId: string, path?: string, opener?: HTMLElement) => void;
}) {
  const t = useT();
  // The store outlives the card leaving the virtualized transcript; one open-state store
  // (useDisclosure.ts): a click is one transition of the transcript's owner.
  const { open: userOpened, set: setOpen } = useDisclosure({ card: row.id });
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
  // A path reads from the turn's repository (the checkpoint's root), else from the chat's folder, as
  // the Codex app lists them: a watched or checkpointless chat no longer shows /Users/... paths.
  const cwd = useContext(SessionCwdContext);
  const fromRoot = (path: string) => shownPath(path, [counts.root, cwd]);
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
  // Undo leaves the paths listed without counts as they are: the page never had their old text.
  const kept = pathsOnly
    .filter((entry) => !toolFiles.some((file) => pathKey(file) === pathKey(entry)))
    .map((entry) => entry.path);
  const total = files.length + plain.length;
  const single = total === 1 && files.length === 1 ? files[0] : undefined;
  // Read only, Undo would write the owner's files.
  const readOnly = useTranscriptReadOnly();
  const undoable = !readOnly && row.ended === true && changes.files.some((file) => file.undo.kind !== "cannot");
  // A Markdown file the turn left in place opens in cmux's Markdown page (writtenArtifacts.tsx): its
  // full path, which the reader's own machine opens, so never in a read-only copy.
  const markdownPath = (file: { path?: string; canonical?: string; deleted?: boolean }) =>
    !readOnly && file.path && !file.deleted && isMarkdownPath(file.path)
      ? pathKey({ path: file.path, canonical: file.canonical })
      : undefined;
  const singleMarkdown = single ? markdownPath(single) : undefined;
  // Transcript Work Log (taste build 9): "Changed 2 files +22 -10" over the session's branch. The
  // head keeps its two lines and 64px (model.ts `editedCardHeight`).
  const workLog = useExperimentSwitch("transcriptWorkLog");
  const branch = useSessionBranch();
  const title = workLog
    ? total === 1
      ? t("worklog.changed.one")
      : t("worklog.changed.other", { n: total })
    : single
      ? t("tools.edited.file", { file: single.path.split("/").pop() ?? single.path })
      : total === 1
        ? t("edited.one")
        : t("tools.edited.files", { n: total });
  // One row, and one click shows every change (Leo, 2026-11-25: "what do you think about just having
  // one row that expands out to the widest situation?"): the head is the card's only line, and opening
  // it stacks each file's whole diff under its own sticky name, as the diff viewer lists a turn's
  // files, in one box capped at 60% of the view that scrolls once. No file rows that open one at a
  // time, and no card inside the card. The reader's choice is the card's (turnChanges/openStore.ts),
  // so it outlives the card scrolling out of the virtualized transcript; the fold keeps the clicked
  // head where it is (useAnchoredCollapse).
  const fold = useAnchoredCollapse({
    open: total > 0 && userOpened,
    onOpenChange: setOpen,
  });
  const headClick = total > 0 ? headerToggleClick(fold.toggle) : undefined;
  // A click that opens or closes the card quiets its hover label until the pointer leaves the head: a
  // reader clicking open and closed sees the counts, and "View changes" only on a fresh hover (Lucas,
  // 2026-11-26). Undo and the head's other buttons never quiet it; a key press never does.
  const [quiet, setQuiet] = useState(false);
  const fullPath = single ? fromRoot(single.path) : undefined;
  // The host answers for the path Undo sent (turnChanges/model.ts `undoPath`), which may be another
  // spelling of the row's.
  const status = (file: TurnFile) =>
    fileStatus(undoState, changes.files.find((edited) => edited.key === pathKey(file))?.path ?? file.path);
  const openChanges = (file: TurnFile) =>
    onOpenDiff && (
      <button
        type="button"
        className={`${cornerAction()} acpmux-edited-open`}
        aria-label={t("edited.openChanges")}
        title={t("edited.openChanges")}
        onClick={(event) => onOpenDiff(row.id, file.path, event.currentTarget)}
      >
        <Icon name="link.external" size={14} />
      </button>
    );
  return (
    <div
      className="acpmux-edited cv-fit"
      data-earlier={earlier ? "" : undefined}
      data-open={fold.present ? "" : undefined}
      data-undo={undoState.phase === "idle" ? undefined : undoState.phase}
    >
      {/* Header padding shares its pointer action; child controls keep their own clicks. */}
      {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions */}
      <div
        className="acpmux-edited-head"
        ref={(node) => fold.headerRef(node)}
        {...(headClick ? { [HEADER_TOGGLE_ATTRIBUTE]: "" } : {})}
        // A control of its own for the transcript's gap selection (#26704), as the title was.
        data-interactive={headClick ? "" : undefined}
        data-hover-quiet={quiet ? "" : undefined}
        onClickCapture={(event) => {
          const target = event.target as Element;
          if (headClick && event.detail > 0 && !target.closest("button:not(.acpmux-edited-toggle)")) setQuiet(true);
        }}
        onPointerLeave={quiet ? () => setQuiet(false) : undefined}
        onClick={headClick}
      >
        <span className="acpmux-edited-icon">
          <DiffFile size={20} />
        </span>
        {/* The words and Undo share a line while the card is wide, Undo goes under the words when it
            is narrow, and only its icon shows when narrower still (cardFit.css). The name is cut
            with an ellipsis, never drawn under a button; its whole path shows on hover. */}
        <div className="cv-fit-row acpmux-edited-main">
          <div className="cv-fit-text acpmux-edited-title">
            {workLog ? (
              <>
                <div className="acpmux-worklog-headline">
                  <span>{title}</span>
                  {files.length > 0 && <Counts additions={counts.additions} deletions={counts.deletions} />}
                </div>
                <div className="acpmux-edited-sub acpmux-worklog-branch">
                  {branch ? (
                    <>
                      <Icon name="git.branch" size={14} />
                      <bdi>{branch}</bdi>
                    </>
                  ) : (
                    counts.outside && <span className="acpmux-edited-outside">{t("turn.outside.card")}</span>
                  )}
                </div>
              </>
            ) : (
              <>
                <div
                  className="acpmux-edited-name"
                  // tooltip-allow: the line shows the file name, cut to the line; the tooltip is its whole path
                  title={fullPath}
                  data-tooltip-force={fullPath ? "" : undefined}
                >
                  {title}
                </div>
                <div className="acpmux-edited-sub">
                  {files.length > 0 && (
                    <span className="acpmux-edited-counts">
                      <Counts additions={counts.additions} deletions={counts.deletions} />
                      {/* Closed only: open, the head keeps its counts (Lucas, 2026-11-26: no "Hide changes"). */}
                      {!fold.present && (
                        <span className="acpmux-edited-hover-label" aria-hidden data-find-skip="">
                          {t("edited.view")}
                        </span>
                      )}
                    </span>
                  )}
                  {counts.outside && <span className="acpmux-edited-outside">{t("turn.outside.card")}</span>}
                </div>
              </>
            )}
          </div>
          {(undoable || singleMarkdown) && (
            <div className="cv-fit-actions acpmux-edited-actions">
              {undoable && <UndoButton state={undoState} rowId={row.id} files={changes.files} t={t} />}
              {singleMarkdown && <OpenWrittenMarkdown path={singleMarkdown} />}
            </div>
          )}
        </div>
        {total > 0 && (
          <button
            type="button"
            className="acpmux-edited-toggle acpmux-edited-chevron"
            aria-expanded={fold.open}
            aria-label={fold.open ? t("edited.hide") : single ? t("edited.view") : t("edited.showFiles")}
            onClick={fold.toggle}
          >
            {/* The cmux disclosure glyph at 16: about 10px wide, as wide as Undo's 14px arrow beside it (Lucas,
                2026-11-26); at 14 the flat chevron read smaller than the arrow. */}
            <ChevronDown size={16} style={fold.open ? { transform: "rotate(180deg)" } : undefined} />
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
      {fold.present && (
        <div {...fold.bodyProps}>
          <div
            ref={stackWheel}
            className="acpmux-edited-stack"
            data-files={total}
            {...{ [INSET_SCROLLER_ATTRIBUTE]: "" }}
          >
            {files.map((file) => {
              const markdown = single ? undefined : markdownPath(file);
              return (
                <div className="acpmux-edited-section" key={file.path} data-path={file.path}>
                  <EditDiff
                    file={file}
                    whole
                    flat
                    collapsible
                    label={fromRoot(file.path)}
                    actions={
                      <>
                        {markdown && <OpenWrittenMarkdown path={markdown} />}
                        {openChanges(file)}
                      </>
                    }
                  />
                  {undoState.phase === "done" && (
                    <FileStatus status={status(file)} path={file.path} rowId={row.id} onOpenDiff={onOpenDiff} t={t} />
                  )}
                </div>
              );
            })}
            {plain.map((entry) => {
              // An edit with no diff: its repo-relative path, or "Unknown file".
              const display = entry.path ? fromRoot(entry.path) : "";
              const markdown = !entry.failed && entry.path ? markdownPath({ ...entry, path: entry.path }) : undefined;
              return (
                <div className="acpmux-edited-plain" key={`plain-${entry.key}`}>
                  <span className="acpmux-edited-path" data-path={entry.path} title={display || undefined}>
                    {entry.path ? display : t("edited.unknownFile")}
                  </span>
                  {entry.failed && <span className="acpmux-edited-failed">{t("tools.failed")}</span>}
                  {markdown && <OpenWrittenMarkdown path={markdown} />}
                </div>
              );
            })}
            {/* The turn's page pictures show with the card's contents: collapsed, they wait until it opens. */}
            {row.ended === true && <TurnShots rowId={row.id} />}
            {row.ended === true && <TurnFramesStrip rowId={row.id} />}
          </div>
        </div>
      )}
      {single && !fold.present && undoState.phase === "done" && (
        <FileStatus status={status(single)} path={single.path} rowId={row.id} onOpenDiff={onOpenDiff} t={t} />
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
  const label =
    state.phase === "undoing"
      ? t("edited.undoing")
      : state.phase === "failed"
        ? t("edited.undoFailed")
        : t("edited.undo");
  // In the narrowest card only the icon shows (cardFit.css): the words stay its name, and the page's
  // tooltip says them while they are cut.
  return (
    <button
      type="button"
      className="acpmux-edited-undo"
      disabled={busy}
      aria-label={label}
      title={label}
      onClick={() => void checkUndo(rowId, files)}
    >
      <span className="cv-fit-label">{label}</span>
      {/* 14, the icon scale's mark inline with text: 12 drew the arrow smaller than its word. */}
      <Undo size={14} />
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
                  files: intl.ListFormat(language, { type: "conjunction" }).format(names),
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

/// `path` from the first of `roots` it lies inside, else as given.
function shownPath(path: string, roots: readonly (string | undefined)[]): string {
  for (const root of roots) {
    const base = root?.replace(/\/+$/, "");
    if (base && path.startsWith(`${base}/`)) return path.slice(base.length + 1);
  }
  return path;
}
