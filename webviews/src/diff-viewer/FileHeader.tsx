// Owns a diff file's header: name, stats, collapse caret and review controls.
import { useRef } from "react";
import { type DeferredDiffReason } from "../deferred-diffs";
import { fileName, fileStats, type DiffItem } from "../diff-stream";
import { DiffHeaderMetadata } from "../diff-metadata";
import { isHeaderToggleKey, shouldToggleFromHeaderClick, type HeaderPress } from "../file-header-toggle";
import { FileIcon } from "../file-icons";
import { Icon } from "../icons";
import { FileMenuButton } from "../DiffToolbar";
import { type ViewedFileState } from "../viewed-files";
import type { DiffViewerLabelResolver } from "../labels";

/**
 * One file's header row, rendered into Pierre's custom header slot (the row
 * itself is Pierre's opaque sticky header): the language icon, the dim
 * directory and bright file name, the collapse caret, then the change counts
 * and the review controls. The whole bar is the collapse toggle
 * (file-header-toggle.ts); its controls keep their own actions.
 */
export function FileHeader({
  item,
  label,
  onCopyPath,
  onLoadDiff,
  onToggleCollapsed,
  onToggleViewed,
  viewedState,
}: {
  item: DiffItem;
  label: DiffViewerLabelResolver;
  /** The "..." menu's Copy path; the menu shows only that row when given. */
  onCopyPath?: (path: string) => void;
  onLoadDiff: () => void;
  onToggleCollapsed: () => void;
  onToggleViewed: () => void;
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
      <span className="file-header-path selectable" title={previousPath == null ? path : `${previousPath} → ${path}`}>
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
        <span className="file-header-name">{baseName}</span>
      </span>
      <span className="file-header-caret" aria-hidden="true">
        <Icon name="chevronDown" />
      </span>
      <span className="file-header-spacer" />
      <DiffHeaderMetadata fileDiff={fileDiff} label={label} />
      <span className="file-header-stats" aria-label={label("diffStats")}>
        <span className="file-header-additions" title={label("additions")}>
          +{stats.added}
        </span>
        <span className="file-header-deletions" title={label("deletions")}>
          -{stats.deleted}
        </span>
      </span>
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
          title={reason === "generated" ? label("generatedFile") : label("largeDiff")}
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
