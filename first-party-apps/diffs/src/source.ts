// Resolves a DiffInput to a diff resource and parsed files, through proposed
// ops only (git.*, diff.get, feed.get, automation.run.get, document.read).

import type { DiffFileSummary, DiffHandle, DiffInput, DiffResource } from "./interfaces/diff.ts"
import type { DocumentReadResult } from "./interfaces/document.ts"
import type { GitStatusResult } from "./interfaces/git.ts"
import { diffTexts } from "./model/linediff.ts"
import { parseUnifiedDiff, type FileDiff } from "./model/unified.ts"

export interface FeedReviewItem {
  id: string
  title: string
  state: "open" | "answered" | "cancelled" | "expired"
  poster?: { label?: string }
  prompt: { subject: string; ref: string; checklist?: string[] }
}

export interface Loaded {
  resource: DiffResource
  files: FileDiff[]
  /** Set when the diff came from a feed `review` request: the review answers it. */
  feedItem: FeedReviewItem | null
}

export class SourceError extends Error {
  constructor(readonly code: string, message: string, readonly op?: string) {
    super(message)
  }
}

const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "error")

/** Calls a proposed op; a missing op becomes SourceError("operation.unsupported", ..., op). */
async function call<T>(op: string, params: unknown): Promise<T> {
  try {
    return await cmux.call<T>(op, params)
  } catch (e) {
    throw new SourceError(codeOf(e), e instanceof Error ? e.message : String(e), op)
  }
}

/** Files from the resource's patch, plus summary-only entries for files the patch lacks (binary, too large). */
export function filesOf(resource: DiffResource): FileDiff[] {
  const parsed = resource.patch ? parseUnifiedDiff(resource.patch) : []
  const byPath = new Map(parsed.map((f) => [f.path, f]))
  const ordered: FileDiff[] = resource.files.map((s: DiffFileSummary) => {
    const f = byPath.get(s.path)
    byPath.delete(s.path)
    if (f) return { ...f, status: s.status, oldPath: s.oldPath ?? f.oldPath }
    return { path: s.path, oldPath: s.oldPath, status: s.status, binary: !!s.binary || s.status === "binary", hunks: [], additions: s.additions, deletions: s.deletions }
  })
  return [...ordered, ...byPath.values()]
}

async function currentWorkspace(): Promise<string | undefined> {
  try {
    const list = await cmux.workspace.list()
    return list.find((w) => w.focused)?.id
  } catch {
    return undefined
  }
}

export async function resolveRepo(input: { repo?: string; workspace?: string }): Promise<GitStatusResult> {
  const workspace = input.workspace ?? (input.repo ? undefined : await currentWorkspace())
  return call<GitStatusResult>("git.status", input.repo ? { repo: input.repo } : { workspace })
}

async function byHandle(diff: DiffHandle, feedItem: FeedReviewItem | null = null): Promise<Loaded> {
  const resource = await call<DiffResource>("diff.get", { diff, include_patch: true })
  return { resource, files: filesOf(resource), feedItem }
}

export async function load(input: DiffInput): Promise<Loaded> {
  switch (input.kind) {
    case "worktree": {
      const status = await resolveRepo(input)
      if (!status.repo) throw new SourceError("git.not_a_repository", "not a repository")
      const resource = await call<DiffResource>("git.diff", { repo: status.repo.repo, head: input.staged ? ":index" : undefined, include_patch: true })
      return { resource, files: filesOf(resource), feedItem: null }
    }
    case "refs": {
      const resource = await call<DiffResource>("git.diff", { repo: input.repo, base: input.base, head: input.head, include_patch: true })
      return { resource, files: filesOf(resource), feedItem: null }
    }
    case "resource":
      return byHandle(input.diff)
    case "feedItem": {
      const item = await call<FeedReviewItem>("feed.get", { item: input.item })
      if (item.prompt?.subject !== "diff") throw new SourceError("feed.not_a_diff", "the review request has no diff")
      return byHandle(item.prompt.ref, item)
    }
    case "run": {
      const run = await call<{ diff?: DiffHandle }>("automation.run.get", { run: input.run })
      if (!run.diff) throw new SourceError("run.no_diff", "the run published no diff")
      return byHandle(run.diff)
    }
    case "documents": {
      const [a, b] = await Promise.all([
        call<DocumentReadResult>("document.read", { doc: input.base.doc, revision: input.base.revision }),
        call<DocumentReadResult>("document.read", { doc: input.head.doc, revision: input.head.revision })
      ])
      const path = input.title ?? "document"
      const file = diffTexts(path, a.text, b.text)
      const resource: DiffResource = {
        diff: "",
        title: path,
        producer: "user",
        base: { kind: "document", ...input.base },
        head: { kind: "document", ...input.head },
        files: [{ path, status: file.status, additions: file.additions, deletions: file.deletions }]
      }
      return { resource, files: [file], feedItem: null }
    }
  }
}
