// The proposed operations this app calls through `cmux.call`, the existing
// actions it falls back to, and how failures map to what the user sees.
// README "Proposed operations" documents every shape.

import { t } from "./l10n.ts"

export const OP = {
  status: "coderouter.status",
  detect: "coderouter.detect",
  accounts: "coderouter.accounts.list",
  connect: "coderouter.accounts.connect",
  remove: "coderouter.accounts.remove",
  share: "coderouter.accounts.share",
  keys: "coderouter.keys.list",
  createKey: "coderouter.keys.create",
  revokeKey: "coderouter.keys.revoke",
  usage: "coderouter.usage.get",
  route: "coderouter.route.get",
  setOrder: "coderouter.route.order.set",
  test: "coderouter.route.test",
  agents: "coderouter.agents.set",
  reveal: "ui.secret.reveal",
  copySecret: "clipboard.writeSecret",
  openPane: "app.pane.open",
  setSetting: "app.settings.set"
} as const

/** Existing app actions (CmuxNextActions ActionCatalog), run through `cmux.actions.run`. */
export const ACTION = {
  showAccounts: "accounts.show",
  refreshAccounts: "accounts.refresh",
  reauthenticate: "accounts.reauthenticate",
  connect: "accounts.connect",
  remove: "accounts.remove",
  signIn: "palette.auth.signIn"
} as const

/** Streams that invalidate the reads. The host emits `coderouter.changed` after any account, key, sharing or route change. */
export const CHANGED = "coderouter.changed"
export const DETECT_CHANGED = "coderouter.detect.changed"

export type ProblemKind = "unsupported" | "scope" | "signedOut" | "unreachable" | "cancelled" | "other"

export interface Problem {
  kind: ProblemKind
  code: string
  message: string
}

const codeOf = (e: unknown): string => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "operation.failed")
const messageOf = (e: unknown): string => (e instanceof Error ? e.message : String(e))

/** The runtime refuses ops outside its allowed list locally, with `scope.missing`
 *  and no `details.scope`: that also covers ops this build does not know. The
 *  host's own refusal names the scope. */
const isLocalRefusal = (e: unknown) => {
  if (codeOf(e) !== "scope.missing") return false
  const details = (e as { details?: unknown }).details
  return !(details && typeof details === "object" && "scope" in details)
}

export function classify(e: unknown): Problem {
  const code = codeOf(e)
  const message = messageOf(e)
  if (code === "operation.unsupported" || isLocalRefusal(e)) return { kind: "unsupported", code, message }
  if (code === "scope.missing" || code === "grant.denied") return { kind: "scope", code, message }
  if (code === "auth.required" || code === "coderouter.not_signed_in") return { kind: "signedOut", code, message }
  if (code === "user.cancelled") return { kind: "cancelled", code, message }
  if (code === "coderouter.unreachable" || code === "network.unreachable" || code === "timeout") return { kind: "unreachable", code, message }
  return { kind: "other", code, message }
}

/** The fallback only applies when this cmux build lacks the proposed op. */
export const isUnsupported = (e: unknown) => codeOf(e) === "operation.unsupported" || isLocalRefusal(e)

export function problemTitle(p: Problem): string {
  switch (p.kind) {
    case "unsupported":
      return t("problem.unsupported", "Not available in this cmux build")
    case "scope":
      return t("problem.scope", "Permission needed")
    case "signedOut":
      return t("problem.signedOut", "Sign in to cmux")
    case "unreachable":
      return t("problem.unreachable", "Cannot reach CodeRouter")
    case "cancelled":
      return t("problem.cancelled", "Cancelled")
    default:
      return t("problem.other", "Something went wrong")
  }
}

/** One quiet sentence. Server messages never echo a credential (control-plane contract). */
export function problemMessage(p: Problem, op: string): string {
  switch (p.kind) {
    case "unsupported":
      return t("problem.unsupported.body", "This build has no {op} operation yet.", { op })
    case "scope":
      return t("problem.scope.body", "Allow CodeRouter in Settings > Apps to use {op}.", { op })
    case "signedOut":
      return t("problem.signedOut.body", "CodeRouter acts as your cmux account and team.")
    default:
      return p.message
  }
}
