// Sidebar section "Changes": the current workspace's repository status
// (proposed `git.status`, refreshed by the `git.changed` event, no polling).
// A tap opens the diff pane at that file.

import type { GitStatusFile, GitStatusResult } from "../interfaces/git.ts"
import { t } from "../l10n.ts"
import { resolveRepo, SourceError } from "../source.ts"
import { basename, dirname, errorState, stat, statusSymbol, statusTint } from "./common.ts"

export interface ChangesDeps {
  open(path: string, staged: boolean): unknown
}

const MAX_ROWS = 12

export function changesSection(deps: ChangesDeps) {
  const [status, setStatus] = signal<GitStatusResult | null>(null)
  const [error, setError] = signal<{ code: string; message: string; op?: string } | null>(null)
  let generation = 0

  async function load() {
    const gen = ++generation
    try {
      const r = await resolveRepo({})
      if (gen !== generation) return
      setStatus(r)
      setError(null)
    } catch (e) {
      if (gen !== generation) return
      setError(e instanceof SourceError ? { code: e.code, message: e.message, op: e.op } : { code: "error", message: String(e) })
    }
  }

  load()
  cmux.events.on("git.changed", (p) => {
    const repo = (p as { repo?: string } | null)?.repo
    if (!repo || repo === status()?.repo?.repo) load()
  })
  // The current workspace decides the repository.
  cmux.events.on("workspace.changed", () => load())

  const row = (f: () => GitStatusFile) =>
    Row({
      title: () => basename(f().path),
      subtitle: () => dirname(f().path) || null,
      symbol: () => statusSymbol(f().status),
      tint: () => statusTint(f().status),
      badge: () => (f().status === "untracked" || f().binary ? null : stat(f().additions, f().deletions))
    })
      .help(() => f().path)
      .onTap(() => deps.open(f().path, f().staged))
      .contextMenu(() => [Button(t("action.openFile", "Open File"), () => cmux.call("ui.open", { interface: "cmux.editor/1", target: { repo: status()?.repo?.repo, path: f().path } }))])

  const group = (title: string | null, files: () => GitStatusFile[]) =>
    VStack({ spacing: 2 }, [
      title ? Text(title).font("caption").weight("semibold").secondary().padding({ top: 4, leading: 6, bottom: 0, trailing: 6 }) : null,
      ForEach({ items: () => files().slice(0, MAX_ROWS), key: (f) => `${f.staged ? "s" : "w"}:${f.path}` }, row),
      () => (files().length > MAX_ROWS ? Text(t("changes.more", "{n} more", { n: files().length - MAX_ROWS })).font("caption").secondary().padding({ top: 0, leading: 8, bottom: 0, trailing: 6 }) : null)
    ])

  return VStack({ spacing: 4 }, [
    () => {
      const err = error()
      if (err) return errorState(err)
      const s = status()
      if (!s) return null
      if (!s.repo) return EmptyState({ title: t("changes.noRepo", "Not a git repository"), symbol: "folder" })
      if (!s.files.length) return EmptyState({ title: t("changes.empty", "No changes"), symbol: "checkmark.circle" })
      const staged = () => (status()?.files ?? []).filter((f) => f.staged)
      const unstaged = () => (status()?.files ?? []).filter((f) => !f.staged)
      const both = staged().length > 0 && unstaged().length > 0
      return VStack({ spacing: 4 }, [
        HStack({ spacing: 6 }, [
          Icon("arrow.triangle.branch").font("caption").secondary(),
          Text(() => status()?.repo?.branch ?? "HEAD").font("caption").monospaced().secondary().lineLimit(1),
          Spacer(),
          Text(() => t("files.count", "{n} files", { n: status()?.files.length ?? 0 })).font("caption").color("tertiary")
        ]).padding({ top: 0, leading: 6, bottom: 2, trailing: 6 }),
        staged().length ? group(both ? t("changes.staged", "Staged") : null, staged) : null,
        unstaged().length ? group(both ? t("changes.unstaged", "Changes") : null, unstaged) : null
      ])
    }
  ])
}
