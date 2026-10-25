// Owns a diff file's header: name, stats, collapse caret and review controls.
import { useRef } from "react";
import { type DeferredDiffReason } from "../deferred-diffs";
import { fileName, fileStats, type DiffItem } from "../diff-stream";
import { DiffHeaderMetadata } from "../diff-metadata";
import {
  HEADER_DRAG_THRESHOLD_PX,
  isHeaderToggleKey,
  shouldToggleFromHeaderClick,
  type HeaderPress,
} from "../file-header-toggle";
import { FileIcon } from "../file-icons";
import { Icon } from "../icons";
import { FileMenuButton } from "../DiffToolbar";
import { type FileKind } from "../fileKinds";
import { type ViewedFileState } from "../viewed-files";
import type { DiffViewerLabelKey, DiffViewerLabelResolver } from "../labels";
import { opensFile, type DiffFileOpen } from "./openFile";

/** The kinds' names in the viewer's table (diffViewer.fileKind.*). */
const FILE_KIND_LABELS: Record<FileKind, DiffViewerLabelKey> = {
  code: "fileKind.code",
  tests: "fileKind.tests",
  mocks: "fileKind.mocks",
  docs: "fileKind.docs",
  evals: "fileKind.evals",
  generated: "fileKind.generated",
};

/**
 * One file's header row, rendered into Pierre's custom header slot (the row
 * itself is Pierre's opaque sticky header): the language icon, the dim
 * directory and bright file name, the collapse caret, then the change counts
 * and the review controls. The whole bar is the collapse toggle
 * (file-header-toggle.ts); its controls keep their own actions. With
 * `onOpenFile`, the file name is a button that opens the file (D4), and the
 * menu opens it in a tab, the editor app or Finder; a deleted file has none.
 */
export function FileHeader({
  item,
  kind,
  label,
  onCopyPath,
  onLoadDiff,
  onOpenFile,
  onToggleCollapsed,
  onToggleViewed,
  revert,
  stage: stageAction,
  viewedState,
}: {
  item: DiffItem;
  /** The file's kind, while the list reads in kind order and the diff has more than one kind. */
  kind?: FileKind;
  label: DiffViewerLabelResolver;
  /** The "..." menu's Copy path; the menu shows only that row when given. */
  onCopyPath?: (path: string) => void;
  onLoadDiff: () => void;
  /** Opens a file of the diff (openFile.ts); absent where the host cannot. */
  onOpenFile?: DiffFileOpen;
  onToggleCollapsed: () => void;
  onToggleViewed: () => void;
  /** Revert the file (D3): an icon beside Stage and a menu row, where the scope's changes are in the
   *  work tree (Unstaged, Uncommitted). The host asks before anything is lost. */
  revert?: { label: string; run: (path: string, previousPath: string | null) => void };
  /** Stage or Unstage the file (cx-ueuc8), where the viewer's source can; a button and a menu row.
   *  `offers` limits it to some files (Branch: those with work-tree changes; cx-4ukqc). */
  stage?: { label: string; run: (path: string) => void; offers?: (path: string) => boolean };
  viewedState: ViewedFileState;
}) {
  const fileDiff = item.fileDiff ?? {};
  const path = fileName(fileDiff, label("untitled"));
  const slash = path.lastIndexOf("/");
  const directory = slash >= 0 ? path.slice(0, slash + 1) : "";
  const baseName = path.slice(slash + 1);
  const previousPath = typeof fileDiff.prevName === "string" && fileDiff.prevName !== path ? fileDiff.prevName : null;
  const stats = fileStats(fileDiff);
  const collapsed = Boolean(item.collapsed);
  const caretLabel = (collapsed ? label("expandFile") : label("collapseFile")).replace("{file}", baseName);
  const press = useRef<HeaderPress | null>(null);
  const stage = stageAction && (!stageAction.offers || stageAction.offers(path)) ? stageAction : undefined;
  const open =
    onOpenFile && opensFile(fileDiff) ? (where?: "editor" | "finder") => onOpenFile(path, undefined, where) : undefined;
  const namePress = useRef<HeaderPress | null>(null);
  return (
    // The bar holds its own buttons (Viewed, Load diff), which a <button>
    // cannot contain, so the toggle is a focusable element with the button role.
    <div
      className="file-header"
      data-collapsed={collapsed}
      data-change-type={fileDiff.type}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="button"
      tabIndex={0}
      aria-expanded={!collapsed}
      aria-label={caretLabel}
      onMouseDown={(event) => {
        press.current = event.button === 0 ? { x: event.clientX, y: event.clientY } : null;
      }}
      onClick={(event) => {
        const start = press.current;
        press.current = null;
        if (shouldToggleFromHeaderClick(event, start)) {
          onToggleCollapsed();
        }
      }}
      onKeyDown={(event) => {
        if (isHeaderToggleKey(event)) {
          event.preventDefault();
          onToggleCollapsed();
        }
      }}
    >
      <FileIcon path={path} />
      <span className="file-header-path selectable">
        {previousPath != null ? (
          <span className="file-header-previous">
            <bdi>{previousPath}</bdi>
            <span aria-hidden="true"> → </span>
          </span>
        ) : null}
        {directory !== "" ? (
          <span className="file-header-directory">
            <bdi>{directory}</bdi>
          </span>
        ) : null}
        {open ? (
          <button
            type="button"
            className="file-header-name file-header-open"
            onMouseDown={(event) => {
              namePress.current = event.button === 0 ? { x: event.clientX, y: event.clientY } : null;
            }}
            onClick={(event) => {
              event.stopPropagation();
              // A drag that selected the name ends in a click: it selects, it does not open. A
              // double click (selecting the name) opens once. A key's click (detail 0) has no press.
              const start = namePress.current;
              namePress.current = null;
              if (event.detail > 1) return;
              const dragged =
                event.detail > 0 &&
                start != null &&
                Math.hypot(event.clientX - start.x, event.clientY - start.y) > HEADER_DRAG_THRESHOLD_PX;
              if (!dragged) open();
            }}
          >
            {baseName}
          </button>
        ) : (
          <span className="file-header-name">{baseName}</span>
        )}
      </span>
      <span className="file-header-caret" aria-hidden="true">
        <Icon name="chevronDown" />
      </span>
      <span className="file-header-spacer" />
      <DiffHeaderMetadata fileDiff={fileDiff} label={label} />
      {kind != null ? (
        <span className="file-header-kind" data-kind={kind}>
          {label(FILE_KIND_LABELS[kind])}
        </span>
      ) : null}
      <span className="file-header-stats" aria-label={label("diffStats")}>
        <span className="file-header-additions">+{stats.added}</span>
        <span className="file-header-deletions">-{stats.deleted}</span>
        <DiffStatBar added={stats.added} deleted={stats.deleted} />
      </span>
      {stage ? (
        <button
          type="button"
          className="file-review-stage"
          onClick={(event) => {
            event.stopPropagation();
            stage.run(path);
          }}
        >
          {stage.label}
        </button>
      ) : null}
      {revert ? (
        <button
          type="button"
          className="file-review-revert"
          aria-label={label("revertFileLabel").replace("{file}", baseName)}
          title={revert.label}
          onClick={(event) => {
            event.stopPropagation();
            revert.run(path, previousPath);
          }}
        >
          <Icon name="revert" />
        </button>
      ) : null}
      <FileReviewControls
        item={item}
        label={label}
        onLoadDiff={onLoadDiff}
        onToggleViewed={onToggleViewed}
        viewedState={viewedState}
      />
      <FileMenuButton
        label={label("fileActions").replace("{file}", baseName)}
        items={[
          ...(open
            ? [
                { id: "open", icon: "document" as const, label: label("openFile"), onChoose: () => open() },
                {
                  id: "open-editor",
                  icon: "external" as const,
                  label: label("openInEditor"),
                  onChoose: () => open("editor"),
                },
                {
                  id: "reveal",
                  icon: "files" as const,
                  label: label("revealInFinder"),
                  onChoose: () => open("finder"),
                },
              ]
            : []),
          ...(stage
            ? [{ id: "stage", icon: "check" as const, label: stage.label, onChoose: () => stage.run(path) }]
            : []),
          ...(revert
            ? [
                {
                  id: "revert",
                  icon: "revert" as const,
                  label: revert.label,
                  onChoose: () => revert.run(path, previousPath),
                },
              ]
            : []),
          {
            id: "viewed",
            icon: viewedState === "viewed" ? "eyeClosed" : "eye",
            label: viewedState === "viewed" ? label("markNotViewed") : label("markViewed"),
            onChoose: onToggleViewed,
          },
          ...(onCopyPath
            ? [
                {
                  id: "copy-path",
                  icon: "clipboard" as const,
                  label: label("copyFilePath"),
                  onChoose: () => onCopyPath(path),
                },
              ]
            : []),
        ]}
      />
    </div>
  );
}

/** Blocks in a file's change bar, GitHub's five. */
const STAT_BAR_BLOCKS = 5;

/**
 * The added and removed shares of a file's changed lines as five blocks (GitHub's diffstat):
 * a block per fifth, rounded so any change shows at least one block of its kind.
 */
export function diffStatBlocks(added: number, deleted: number): ("added" | "deleted" | "neutral")[] {
  const total = added + deleted;
  if (total <= 0) return Array.from({ length: STAT_BAR_BLOCKS }, () => "neutral");
  let addedBlocks = Math.round((added / total) * STAT_BAR_BLOCKS);
  let deletedBlocks = Math.round((deleted / total) * STAT_BAR_BLOCKS);
  if (added > 0 && addedBlocks === 0) addedBlocks = 1;
  if (deleted > 0 && deletedBlocks === 0) deletedBlocks = 1;
  // Over by a rounding: take from the larger side, from both on a tie (an even split stays even,
  // with a neutral block left over).
  while (addedBlocks + deletedBlocks > STAT_BAR_BLOCKS) {
    if (addedBlocks === deletedBlocks) {
      addedBlocks -= 1;
      deletedBlocks -= 1;
    } else if (addedBlocks > deletedBlocks) addedBlocks -= 1;
    else deletedBlocks -= 1;
  }
  return Array.from({ length: STAT_BAR_BLOCKS }, (_, index) =>
    index < addedBlocks ? "added" : index < addedBlocks + deletedBlocks ? "deleted" : "neutral",
  );
}

function DiffStatBar({ added, deleted }: { added: number; deleted: number }) {
  return (
    <span className="file-header-bar" aria-hidden="true">
      {diffStatBlocks(added, deleted).map((kind, index) => (
        // oxlint-disable-next-line react/no-array-index-key -- five fixed slots, never reordered.
        <span key={index} data-kind={kind} />
      ))}
    </span>
  );
}

/**
 * Per-file review controls rendered at the end of the file header: the
 * "Viewed" checkbox with its "changed since viewed" badge, and the generated /
 * large badge with a "Load diff" button while such a file is still collapsed.
 * Clicks stop propagating so they never reach the header row's own handlers.
 */
function FileReviewControls({
  item,
  label,
  onLoadDiff,
  onToggleViewed,
  viewedState,
}: {
  item: DiffItem;
  label: DiffViewerLabelResolver;
  onLoadDiff: () => void;
  onToggleViewed: () => void;
  viewedState: ViewedFileState;
}) {
  const reason = item.fileDiff?.cmuxDeferredReason as DeferredDiffReason | undefined;
  const viewed = viewedState === "viewed";
  return (
    <span className="file-review-controls" data-viewed-state={viewedState}>
      {reason != null ? (
        <span className="file-review-badge" data-deferred-reason={reason}>
          {reason === "generated" ? label("generatedFile") : label("largeDiff")}
        </span>
      ) : null}
      {reason != null && item.collapsed ? (
        <button
          type="button"
          className="file-review-load"
          onClick={(event) => {
            event.stopPropagation();
            onLoadDiff();
          }}
        >
          {label("loadDiff")}
        </button>
      ) : null}
      {viewedState === "changed" ? (
        <span className="file-review-badge" data-changed-since-viewed="true">
          {label("changedSinceViewed")}
        </span>
      ) : null}
      <button
        type="button"
        className="file-review-viewed"
        aria-pressed={viewed}
        aria-label={label("viewed")}
        title={viewed ? label("markNotViewed") : label("markViewed")}
        onClick={(event) => {
          event.stopPropagation();
          onToggleViewed();
        }}
      >
        {/* The classic bar's eye: dim until the file is viewed. */}
        <span className="file-review-eye" aria-hidden="true">
          <Icon name="viewedEye" />
        </span>
      </button>
    </span>
  );
}
