// PROPOSED platform interfaces `cmux.diff.renderer/1` and `cmux.diff.source/1`
// and the diff resource (app platform critique C1, C4).
// Vendored copy; identical in first-party-apps/{diffs,monaco,codemirror}.
//
// A diff is a resource (`diff_…`) owned by its producer: git (the session host),
// an agent (`diff.propose`), an automation run (`diff.publish`) or the user.
// Applying, staging or rejecting goes through the owner, never the renderer.

import type { DocHandle, DocRevision } from "./document.ts"

export const DIFF_RENDERER_INTERFACE = "cmux.diff.renderer/1"
export const DIFF_SOURCE_INTERFACE = "cmux.diff.source/1"

/** Opaque diff handle (`diff_…`). */
export type DiffHandle = string

/** One side of a diff. */
export type DiffRef =
  | { kind: "git"; repo: string; rev: string }
  | { kind: "worktree"; repo: string }
  | { kind: "index"; repo: string }
  | { kind: "document"; doc: DocHandle; revision: DocRevision }
  | { kind: "snapshot"; id: string }

export type DiffProducer = "git" | "agent" | "automation" | "user"

export type FileStatus = "modified" | "added" | "deleted" | "renamed" | "copied" | "untracked" | "binary"

export interface DiffFileSummary {
  path: string
  oldPath?: string
  status: FileStatus
  additions: number
  deletions: number
  binary?: boolean
}

export interface DiffResource {
  diff: DiffHandle
  title: string
  producer: DiffProducer
  /** `agent:<id>`, `run:<id>`, `user:<id>`; display only. */
  producerLabel?: string
  base: DiffRef
  head: DiffRef
  files: DiffFileSummary[]
  /** Unified diff text (git format) for all files, when the producer has it. */
  patch?: string
  /** Owner decisions recorded so far. */
  decisions?: DiffDecision[]
  /** What accepting means for this producer, shown on buttons. */
  acceptVerb?: "stage" | "apply" | "keep"
  rejectVerb?: "unstage" | "discard" | "drop"
  context?: { workspace?: string; terminal?: string; feedItem?: string; run?: string }
}

export interface DiffDecision {
  path: string
  /** Hunk id from `hunkId`; absent for the whole file. */
  hunk?: string
  decision: "accept" | "reject"
}

export interface DiffComment {
  id: string
  path: string
  /** New-side line; old-side when `side` is "old". */
  line: number
  side: "old" | "new"
  body: string
  author: string
  createdAt: number
}

/** What a renderer may be asked to show. */
export type DiffInput =
  | { kind: "worktree"; repo?: string; workspace?: string; staged?: boolean }
  | { kind: "refs"; repo: string; base: string; head: string }
  | { kind: "resource"; diff: DiffHandle }
  | { kind: "feedItem"; item: string }
  | { kind: "run"; run: string }
  | { kind: "documents"; base: { doc: DocHandle; revision: DocRevision }; head: { doc: DocHandle; revision: DocRevision }; title?: string }

/** Renderer props (`cmux.diff.renderer/1`). */
export interface DiffRendererProps {
  input: DiffInput
  focusPath?: string
  layout?: "sideBySide" | "inline"
  /** Review mode: decisions and comments are collected and submitted as a review answer. */
  review?: boolean
}

export type DiffRendererEvent =
  | { type: "decided"; decisions: DiffDecision[] }
  | { type: "reviewSubmitted"; verdict: "approve" | "request_changes" | "comment" }

// Operations (owners: git = session host; agent/automation = the diff's producer
// record in the session host; feed answers = the feed owner).

export interface DiffGetParams { diff: DiffHandle; include_patch?: boolean }
export interface DiffDecideParams { diff: DiffHandle; decisions: DiffDecision[] }
export interface DiffDecideResult { applied: DiffDecision[]; diff: DiffResource }
/** `diff.file.read`: one side of one file (owner: the producer). Binary files answer `diff.binary`. */
export interface DiffFileReadParams { diff: DiffHandle; path: string; side: "base" | "head" }
export interface DiffFileReadResult { text: string; language?: string }
export interface DiffCommentAddParams { diff: DiffHandle; path: string; line: number; side: "old" | "new"; body: string }
export interface DiffCommentListParams { diff: DiffHandle }

/** `diff.propose` (MCP tool for agents): creates a diff and a `review` feed request. */
export interface DiffProposeParams { title: string; base: DiffRef; patch: string; workspace?: string }
export interface DiffProposeResult { diff: DiffHandle; feed_item: string }
