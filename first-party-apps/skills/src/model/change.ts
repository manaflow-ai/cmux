// A planned config change and its review. The owner plans a change as a diff
// resource (dry_run) whose files carry their base revisions; accepting the
// diff applies it, and a file that changed since the plan (an agent CLI wrote
// it) rejects the accept with diff.stale. States:
//   idle -> planning -> review (diff shown) -> applying -> applied
//   applying -> stale -> planning (one automatic re-plan, the new diff is shown again)
//   planning|applying -> failed ; review -> idle (Cancel)

export type ChangeFile = { path_label: string; kind: "modify" | "create" | "delete"; patch: string }
export type Plan = { diff: string; title: string; files: ChangeFile[]; requests?: string[]; sandbox?: string | null }

/** What the user asked for, kept so a stale plan can be made again (intent, not bytes). */
export type Intent = { op: string; params: Record<string, unknown>; title: string }

export type ChangeState =
  | { phase: "idle" }
  | { phase: "planning"; intent: Intent; replans: number }
  | { phase: "review"; intent: Intent; plan: Plan; replans: number; note: "stale" | null }
  | { phase: "applying"; intent: Intent; plan: Plan; replans: number }
  | { phase: "applied"; intent: Intent }
  | { phase: "failed"; intent: Intent; code: string; message: string }

export type ChangeEvent =
  | { type: "ask"; intent: Intent }
  | { type: "planned"; plan: Plan }
  | { type: "apply" }
  | { type: "applied" }
  | { type: "stale" }
  | { type: "error"; code: string; message: string }
  | { type: "cancel" }

export const MAX_REPLANS = 1

export function reduceChange(s: ChangeState, ev: ChangeEvent): ChangeState {
  switch (ev.type) {
    case "ask":
      // A new ask replaces a review, never an apply in flight.
      return s.phase === "applying" ? s : { phase: "planning", intent: ev.intent, replans: 0 }
    case "planned":
      if (s.phase !== "planning") return s
      return { phase: "review", intent: s.intent, plan: ev.plan, replans: s.replans, note: s.replans > 0 ? "stale" : null }
    case "apply":
      return s.phase === "review" ? { phase: "applying", intent: s.intent, plan: s.plan, replans: s.replans } : s
    case "applied":
      return s.phase === "applying" ? { phase: "applied", intent: s.intent } : s
    case "stale":
      if (s.phase !== "applying") return s
      if (s.replans >= MAX_REPLANS) return { phase: "failed", intent: s.intent, code: "diff.stale", message: "" }
      return { phase: "planning", intent: s.intent, replans: s.replans + 1 }
    case "error":
      return s.phase === "planning" || s.phase === "applying" ? { phase: "failed", intent: s.intent, code: ev.code, message: ev.message } : s
    case "cancel":
      return s.phase === "applying" ? s : { phase: "idle" }
  }
}

export const busyChange = (s: ChangeState) => s.phase === "planning" || s.phase === "applying"
