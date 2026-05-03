import React, { useCallback, useMemo } from "react"
import type { DiffFile } from "./diffModel"
import { DiffFileView } from "./DiffFileView"

interface Props {
  /** Absolute path to the repo root. Used as React key + display label. */
  root: string
  files: DiffFile[]
  /** True when this is the most-recently-active repo. */
  isActive: boolean
  /** Whether this group's body is currently expanded. */
  expanded: boolean
  /** Toggle this group. */
  onToggleRepo: (root: string) => void
  /** File-level expansion state for this repo. */
  expandedFiles: Set<string>
  /** Toggle a single file inside this repo. */
  onToggleFile: (path: string) => void
  /** Whether to use the unified (narrow) diff renderer. */
  unified: boolean
  /** Drag-to-reorder hooks. The header is the drag source AND the drop target. */
  onDragStart: (root: string) => void
  onDragOver: (root: string) => void
  onDrop: (root: string) => void
  onDragEnd: () => void
  /** When true, this group is currently being dragged (visual hint). */
  isDragging: boolean
  /** When true, this group is the current drop target (visual hint). */
  isDropTarget: boolean
}

/**
 * One repo's section of the multi-repo diff panel:
 *   - header: drag-handle + chevron + repo path + +X/-Y badges + active marker
 *   - body (when expanded): DiffFileView per file, or "No changes." if empty
 *
 * Body keys off the repo `root`, so an unchanged repo's file rows aren't
 * rebuilt when other repos in the panel update.
 *
 * Drag-to-reorder: the wrapper `<section>` is `draggable`. The drag handle on
 * the left of the header is the visual affordance, but the whole header is
 * draggable so the user doesn't have to grab a tiny target. The chevron
 * toggle stops propagation so clicking it never accidentally starts a drag.
 */
export const RepoGroup = React.memo(function RepoGroup({
  root,
  files,
  isActive,
  expanded,
  onToggleRepo,
  expandedFiles,
  onToggleFile,
  unified,
  onDragStart,
  onDragOver,
  onDrop,
  onDragEnd,
  isDragging,
  isDropTarget,
}: Props) {
  const onHeaderClick = useCallback(() => onToggleRepo(root), [onToggleRepo, root])

  const totals = useMemo(() => {
    let adds = 0
    let dels = 0
    for (const f of files) {
      adds += f.additions
      dels += f.deletions
    }
    return { adds, dels }
  }, [files])

  const handleDragStart = useCallback(
    (e: React.DragEvent<HTMLElement>) => {
      // Use text/plain so a stray drop in another widget doesn't blow up.
      // Mark the data on the event so external handlers can sniff it; the
      // App-level state is what we actually use to compute the reorder.
      e.dataTransfer.setData("text/plain", root)
      e.dataTransfer.effectAllowed = "move"
      onDragStart(root)
    },
    [onDragStart, root]
  )

  const handleDragOver = useCallback(
    (e: React.DragEvent<HTMLElement>) => {
      // Required to allow drop. preventDefault unlocks dropEffect = "move".
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      onDragOver(root)
    },
    [onDragOver, root]
  )

  const handleDrop = useCallback(
    (e: React.DragEvent<HTMLElement>) => {
      e.preventDefault()
      onDrop(root)
    },
    [onDrop, root]
  )

  const handleDragEnd = useCallback(() => {
    onDragEnd()
  }, [onDragEnd])

  return (
    <section
      className="repo-group"
      data-active={isActive}
      data-expanded={expanded}
      data-dragging={isDragging || undefined}
      data-drop-target={isDropTarget || undefined}
      draggable
      onDragStart={handleDragStart}
      onDragOver={handleDragOver}
      onDrop={handleDrop}
      onDragEnd={handleDragEnd}
    >
      <button
        type="button"
        className="repo-group-header"
        onClick={onHeaderClick}
        aria-expanded={expanded}
        title={root}
      >
        <span
          className="repo-group-drag-handle"
          aria-hidden
          title="Drag to reorder"
        >
          {"☰"}
        </span>
        <span className={`twisty ${expanded ? "open" : "closed"}`} aria-hidden>
          ▾
        </span>
        <span className="repo-group-path">{root}</span>
        {isActive ? <span className="repo-group-active" title="Active repo">active</span> : null}
        <span className="repo-group-totals">
          <span className="add-badge">+{totals.adds}</span>
          <span className="del-badge">−{totals.dels}</span>
          <span className="file-count">
            {files.length} file{files.length === 1 ? "" : "s"}
          </span>
        </span>
      </button>
      {expanded ? (
        <div className="repo-group-body">
          {files.length === 0 ? (
            <div className="repo-empty">No changes.</div>
          ) : (
            files.map((f) => (
              <DiffFileView
                key={f.path}
                file={f}
                expanded={expandedFiles.has(f.path)}
                onToggle={onToggleFile}
                unified={unified}
              />
            ))
          )}
        </div>
      ) : null}
    </section>
  )
})
