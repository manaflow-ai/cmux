// PROPOSED git operations (app platform critique C4). Owner: the session host
// on the machine that has the repository. Read ops need `git:read`; staging
// and restoring need `git:write` and origin user (a tap) or an approval.
// Vendored copy; identical in first-party-apps/{diffs,monaco,codemirror}.

import type { DiffFileSummary, DiffResource } from "./diff.ts"

export interface GitRepo {
  /** Opaque repository handle (`repo_…`); never a path the app chose. */
  repo: string
  name: string
  branch: string | null
  head: string | null
  ahead?: number
  behind?: number
}

export interface GitStatusParams { workspace?: string; repo?: string }

export interface GitStatusFile extends DiffFileSummary {
  staged: boolean
}

export interface GitStatusResult {
  repo: GitRepo | null
  files: GitStatusFile[]
}

/** `git.diff`: returns a diff resource (producer git) for two refs or the working tree. */
export interface GitDiffParams {
  repo: string
  /** Absent: HEAD. */
  base?: string
  /** Absent: the working tree. `:index` for staged changes. */
  head?: string
  paths?: string[]
  include_patch?: boolean
}

export type GitDiffResult = DiffResource

/** Event `git.changed {repo}`: the owner watches the repository (no polling). */
export interface GitChangedEvent { repo: string }
