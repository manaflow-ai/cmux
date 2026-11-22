// Accept and reject controls for a hunk or a file. Decisions go to the diff's
// owner (git stages or restores, an agent's proposal applies or drops). A
// destructive reject (git restore) needs a second tap: the scene has no
// confirmation dialog yet (README, gaps).

import { t } from "../l10n.ts"
import { fileDecision, type Decision } from "../model/review.ts"
import type { FileDiff, Hunk } from "../model/unified.ts"
import { decisionBadge } from "./common.ts"
import type { PaneView } from "./state.ts"

interface Verbs {
  accept: string
  reject: string
  destructiveReject: boolean
}

export function verbsOf(pv: PaneView): Verbs {
  const r = pv.session.loaded()?.resource
  const accept = r?.acceptVerb === "stage" ? t("action.stage", "Stage") : r?.acceptVerb === "apply" ? t("action.apply", "Apply") : t("action.accept", "Accept")
  const reject = r?.rejectVerb === "discard" ? t("action.discard", "Discard") : r?.rejectVerb === "drop" ? t("action.drop", "Drop") : t("action.reject", "Reject")
  return { accept, reject, destructiveReject: r?.rejectVerb === "discard" }
}

/** Decisions need an owner: a documents diff (no handle) shows none. */
const decidable = (pv: PaneView) => !!pv.session.loaded()?.resource.diff

function rejectButton(pv: PaneView, id: string, verbs: Verbs, send: () => unknown) {
  if (!verbs.destructiveReject) return Button(verbs.reject, send).font("caption")
  return Button(
    () => (pv.armed() === id ? `${verbs.reject}?` : verbs.reject),
    () => {
      if (pv.armed() !== id) return pv.setArmed(id)
      pv.setArmed(null)
      return send()
    }
  )
    .font("caption")
    .destructive()
}

function decidedControls(pv: PaneView, decision: Decision, confirmed: boolean, undo: () => unknown) {
  return HStack({ spacing: 6 }, [
    Badge(decision === "accept" ? t("file.decision.accept", "Accepted") : t("file.decision.reject", "Rejected"), decision === "accept" ? "success" : "danger"),
    confirmed ? null : Button(t("action.undo", "Undo"), undo).font("caption")
  ])
}

export function hunkControls(pv: PaneView, file: FileDiff, h: Hunk) {
  return () => {
    if (!decidable(pv)) return null
    const state = pv.session.review()
    const d = state.hunks[h.id]
    if (d) return decidedControls(pv, d, state.confirmed[h.id] === d, () => pv.session.decideHunk(file, h.id, d))
    const verbs = verbsOf(pv)
    return HStack({ spacing: 6 }, [
      Button(verbs.accept, () => pv.session.decideHunk(file, h.id, "accept")).font("caption"),
      rejectButton(pv, h.id, verbs, () => pv.session.decideHunk(file, h.id, "reject"))
    ])
  }
}

export function fileControls(pv: PaneView, file: () => FileDiff) {
  return () => {
    if (!decidable(pv) || !file().hunks.length) return null
    const d = fileDecision(pv.session.review(), file())
    if (d === "accept" || d === "reject") return decisionBadge(d)
    const verbs = verbsOf(pv)
    const id = `file:${file().path}`
    return HStack({ spacing: 6 }, [
      d === "partial" ? decisionBadge(d) : null,
      Button(verbs.accept, () => pv.session.decideFile(file(), "accept")).font("caption"),
      rejectButton(pv, id, verbs, () => pv.session.decideFile(file(), "reject"))
    ])
  }
}
