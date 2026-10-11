/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Diffs: implements `cmux.diff.renderer/1`. Shows the working tree against
// HEAD, two refs, an agent's proposed diff (a feed `review` request) or a run's
// diff. File bodies come from the user's `cmux.editor/1` app through an embed,
// or from the built-in scene diff when no editor app is installed.

import * as commands from "./commands.ts"
import type { DiffInput } from "./interfaces/diff.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { createSession } from "./session.ts"
import { variant } from "./settings.ts"
import { changesSection } from "./views/section.ts"
import { createPaneView } from "./views/state.ts"
import { reviewView, splitView, streamView } from "./views/variants.ts"

const isInput = (v: unknown): v is DiffInput => !!v && typeof v === "object" && typeof (v as { kind?: unknown }).kind === "string"

/** Sidebar section "Changes". */
export function renderChanges(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  return changesSection({ open: (path, staged) => commands.openChanges({ path, staged }) })
}

/** Pane kind `diff`. The proposed mount context carries `input` and `focusPath`; without them the pane follows the last opened diff. */
export function renderDiffPane(ctx: Record<string, unknown> = {}) {
  setLanguage(detectLanguage(ctx))
  const own = isInput(ctx.input) ? ctx.input : null
  const session = createSession(() => own ?? commands.defaultInput())
  const pv = createPaneView(session)
  if (typeof ctx.focusPath === "string") session.select(ctx.focusPath)

  // Reload when the input changes (reads the input signal only before its first await).
  effect(() => {
    session.input()
    session.reload()
  })
  effect(() => {
    const req = commands.focusRequest()
    if (req) session.select(req.path)
  })
  cmux.events.on("git.changed", () => {
    if (["worktree", "refs"].includes(session.input().kind)) session.reload()
  })
  cmux.events.on("diff.changed", (p) => {
    const diff = (p as { diff?: string } | null)?.diff
    if (diff && diff === session.loaded()?.resource.diff) session.reload()
  })

  return VStack({ spacing: 0 }, [
    () => {
      switch (variant()) {
        case "stream":
          return streamView(pv)
        case "review":
          return reviewView(pv)
        default:
          return splitView(pv)
      }
    }
  ])
}

export const openChanges = commands.openChanges
export const openDiff = commands.openDiff
export const review = commands.review
export const reviewLatest = commands.reviewLatest
export const toggleLayout = commands.toggleLayout
export const cycleVariant = commands.cycleVariant
