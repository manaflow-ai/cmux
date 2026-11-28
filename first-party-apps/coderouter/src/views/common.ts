// Small shared view pieces. Semantic color tokens only; no blue.

import { t } from "../l10n.ts"
import { problemMessage, problemTitle, type Problem } from "../ops.ts"
import type { Query } from "../query.ts"
import { signIn } from "../actions.ts"
import { notice } from "../store.ts"

export const dot = (tone: () => string, size = 8) => Circle({ fill: tone }).frame({ width: size, height: size })

export const caption = (text: Parameters<typeof Text>[0]) => Text(text).font("caption").secondary().lineLimit(2)

export function header(title: string, trailing: CmuxView | (() => CmuxView | null) | null = null) {
  return HStack({ spacing: 6 }, [Text(title).font("caption").weight("semibold").color("secondary"), Spacer(), trailing]).padding({ top: 10, leading: 0, bottom: 2, trailing: 0 })
}

/** A plain text button sized for rows. */
export const small = (title: Parameters<typeof Button>[0], action: () => unknown) => Button(title, action).font("caption")

/** One segmented choice: the selected title is bold, the others secondary. */
export function choice<T extends string>(options: Array<[T, string]>, current: () => T, set: (v: T) => void) {
  return HStack(
    { spacing: 10 },
    options.map(([value, title]) =>
      Text(title)
        .font("caption")
        .weight(() => (current() === value ? "semibold" : "regular"))
        .color(() => (current() === value ? "primary" : "secondary"))
        .cursor("pointer")
        .onTap(() => set(value))
    )
  )
}

/** Proportional bar for usage rows. */
export function bar(fraction: () => number, width = 120) {
  return HStack({ spacing: 0 }, [Capsule({ fill: "accent" }).frame(() => ({ width: Math.max(2, Math.round(fraction() * width)), height: 4 })), Spacer()]).frame({ width, height: 4 })
}

/** EmptyState for a failed read, with a retry and, when signed out, a sign-in button. */
export function problemView(problem: Problem, op: string, retry: () => void) {
  return VStack({ spacing: 6 }, [
    EmptyState({ title: problemTitle(problem), message: problemMessage(problem, op), symbol: problem.kind === "signedOut" ? "person.crop.circle.badge.questionmark" : problem.kind === "unsupported" ? "puzzlepiece.extension" : "exclamationmark.triangle" }),
    problem.kind === "signedOut" || problem.kind === "unsupported" || problem.kind === "scope"
      ? problem.kind === "signedOut" ? HStack([Spacer(), Button(t("action.signIn", "Sign In"), signIn), Spacer()]) : null
      : HStack([Spacer(), Button(t("action.retry", "Try Again"), retry), Spacer()])
  ])
}

/** Renders `body` with the query's value; a loading line before the first value, the problem when it failed. */
export function loaded<T>(q: Query<T>, op: string, body: (v: T) => CmuxView | null, loadingText = t("state.loading", "Loading…")): () => CmuxView | null {
  return () => {
    const v = q()
    const p = q.problem()
    if (p && v === undefined) return problemView(p, op, q.refresh)
    if (v === undefined) return caption(loadingText)
    return body(v)
  }
}

/** The notice line (one at a time, clears itself). */
export const noticeLine = () => () => {
  const n = notice()
  return n ? Text(n.text).font("caption").color(n.tone).lineLimit(3).padding({ top: 6, leading: 0, bottom: 0, trailing: 0 }) : null
}
