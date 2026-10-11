// App commands (palette, CLI, MCP). Opening a diff asks the shell for a pane
// of kind `diff` with the input (proposed `app.pane.open`); a mounted pane
// without its own input follows the last opened input either way.

import type { DiffInput } from "./interfaces/diff.ts"
import { cycleVariant as cycle, setVariantForSession, toggleLayout as toggle } from "./settings.ts"

const [defaultInput, setDefaultInput] = signal<DiffInput>({ kind: "worktree" })
const [focusRequest, setFocusRequest] = signal<{ path: string; seq: number } | null>(null)
let focusSeq = 0

export { defaultInput, focusRequest }

type CmuxErrorConstructor = new (code: string, message: string) => CmuxError
/** A thrown CmuxError reaches CLI and MCP callers as {code, message} (the typings lack its constructor). */
const invalid = (message: string): CmuxError => new (CmuxError as unknown as CmuxErrorConstructor)("invalid_params", message)

const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "error")

async function openPane(input: DiffInput, focusPath?: string): Promise<{ opened: boolean; reason?: string }> {
  setDefaultInput(input)
  if (focusPath) setFocusRequest({ path: focusPath, seq: ++focusSeq })
  try {
    await cmux.call("app.pane.open", { kind: "diff", input, focus_path: focusPath })
    return { opened: true }
  } catch (e) {
    return { opened: false, reason: codeOf(e) }
  }
}

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined)

/** Palette "Open Changes": the current workspace's working tree vs HEAD. */
export async function openChanges(args: { staged?: boolean; path?: string } = {}) {
  return openPane({ kind: "worktree", staged: !!args.staged }, str(args.path))
}

/** CLI/MCP: two refs of a repository. */
export async function openDiff(args: { repo?: string; base?: string; head?: string } = {}) {
  const base = str(args.base)
  const head = str(args.head)
  const repo = str(args.repo)
  if (!base || !head || !repo) throw invalid("repo, base and head are required")
  return openPane({ kind: "refs", repo, base, head })
}

/** Review an agent's proposal (a feed `review` item), a diff resource or a run's diff. */
export async function review(args: { item?: string; diff?: string; run?: string } = {}) {
  const item = str(args.item)
  const diff = str(args.diff)
  const run = str(args.run)
  const input: DiffInput | null = item ? { kind: "feedItem", item } : diff ? { kind: "resource", diff } : run ? { kind: "run", run } : null
  if (!input) throw invalid("give item, diff or run")
  if (item) setVariantForSession("review")
  return openPane(input)
}

/** Palette "Review Latest Proposal": the newest open feed `review` request with a diff (proposed `feed.list`). */
export async function reviewLatest() {
  const items = await cmux.call<Array<{ id: string; prompt?: { subject?: string } }>>("feed.list", { kind: "review", state: "open", limit: 20 })
  const item = items.find((i) => i.prompt?.subject === "diff")
  if (!item) return { opened: false, reason: "none" }
  return review({ item: item.id })
}

export async function toggleLayout() {
  return toggle()
}

export async function cycleVariant() {
  return cycle()
}
