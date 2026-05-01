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
}

/**
 * One repo's section of the multi-repo diff panel:
 *   - header: chevron + repo path + +X/-Y badges + active marker
 *   - body (when expanded): DiffFileView per file, or "No changes." if empty
 *
 * Body keys off the repo `root`, so an unchanged repo's file rows aren't
 * rebuilt when other repos in the panel update.
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

  return (
    <section className="repo-group" data-active={isActive} data-expanded={expanded}>
      <button
        type="button"
        className="repo-group-header"
        onClick={onHeaderClick}
        aria-expanded={expanded}
        title={root}
      >
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
