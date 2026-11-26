// User-initiated flows. Each runs from a tap or a command, so the host sees
// origin = user. Every flow that touches a secret is performed by the host:
// the app passes a provider id, an account id or an opaque handle, never a
// key or token, and gets back metadata only.

import { t } from "./l10n.ts"
import type { Account, KeyCreated, Surface, TestResult, Visibility } from "./model.ts"
import { ACTION, OP, classify, isUnsupported, problemMessage, problemTitle } from "./ops.ts"
import { STORAGE, say, setCreatedKey, setLastTest, withBusy } from "./store.ts"

function report(e: unknown, op: string): void {
  const p = classify(e)
  if (p.kind === "cancelled") return
  say("danger", `${problemTitle(p)}. ${problemMessage(p, op)}`)
}

/** Runs the proposed op; when this build lacks it, runs the existing action instead. */
async function opOrAction<T>(op: string, params: Record<string, unknown>, action: string, args: Record<string, unknown>): Promise<{ via: "op"; value: T } | { via: "action" }> {
  try {
    return { via: "op", value: await cmux.call<T>(op, params) }
  } catch (e) {
    if (!isUnsupported(e)) throw e
    await cmux.actions.run(action, args)
    return { via: "action" }
  }
}

/** cmux reads the local sign-in or asks for a paste in its own secure field, then sends it to CodeRouter. */
export const connect = (provider: string, name: string) =>
  withBusy(`connect:${provider}`, async () => {
    try {
      const r = await opOrAction<{ status: "connected" | "cancelled" }>(OP.connect, { provider }, ACTION.connect, { provider })
      if (r.via === "action") {
        say("secondary", t("notice.connectHandedOff", "Finish connecting {name} in cmux.", { name }))
        return true
      }
      if (r.value.status !== "connected") return false
      say("success", t("notice.connected", "{name} connected. It stays private until you share it.", { name }))
      return true
    } catch (e) {
      report(e, OP.connect)
      return false
    }
  })

/** Runs the provider's own login in a visible cmux terminal tab. */
export async function reauthenticate(provider: string) {
  try {
    await cmux.actions.run(ACTION.reauthenticate, { provider })
  } catch (e) {
    report(e, ACTION.reauthenticate)
  }
}

/** The host confirms before removing. */
export const remove = (account: Account) =>
  withBusy(`account:${account.id}`, async () => {
    try {
      const r = await opOrAction<{ removed: boolean }>(OP.remove, { account: account.id }, ACTION.remove, { account: account.id })
      if (r.via === "op" && r.value.removed) say("secondary", t("notice.removed", "{label} removed from CodeRouter.", { label: account.label }))
    } catch (e) {
      report(e, OP.remove)
    }
  })

/** One call for any number of accounts, so "Share all" is one user action. */
export const share = (accounts: readonly string[], visibility: Visibility) =>
  withBusy(`share:${accounts.join(",")}`, async () => {
    if (!accounts.length) return false
    try {
      await cmux.call(OP.share, { accounts, visibility })
      say("success", visibility === "team" ? t("notice.shared", "Shared with your team.") : t("notice.private", "Now private to you."))
      return true
    } catch (e) {
      report(e, OP.share)
      return false
    }
  })

/** The host shows the new key once in its own sheet (copy button there). The app keeps only the handle. */
export const createKey = (label: string) =>
  withBusy("key:create", async () => {
    const name = label.trim() || t("key.defaultLabel", "cmux key")
    try {
      const created = await cmux.call<KeyCreated>(OP.createKey, { label: name, present: "sheet" })
      setCreatedKey(created)
      return created
    } catch (e) {
      report(e, OP.createKey)
      return null
    }
  })

export async function revealKey(handle: string) {
  try {
    await cmux.call(OP.reveal, { handle })
  } catch (e) {
    report(e, OP.reveal)
  }
}

export async function copyKey(handle: string) {
  try {
    await cmux.call(OP.copySecret, { handle })
    say("success", t("notice.copied", "Copied. The clipboard clears in 60 seconds."))
  } catch (e) {
    report(e, OP.copySecret)
  }
}

export const revokeKey = (id: string) =>
  withBusy(`key:${id}`, async () => {
    try {
      await cmux.call(OP.revokeKey, { key: id })
      setCreatedKey((k) => (k && k.key.id === id ? null : k))
    } catch (e) {
      report(e, OP.revokeKey)
    }
  })

/** cmux injects a route token into agents it launches; the token never reaches this app. */
export const setAgentsRouted = (enabled: boolean) =>
  withBusy("agents", async () => {
    try {
      await cmux.call(OP.agents, { enabled })
      say("success", enabled ? t("notice.agentsOn", "New agent sessions in cmux use CodeRouter.") : t("notice.agentsOff", "Agents use their own sign-ins again."))
      return true
    } catch (e) {
      report(e, OP.agents)
      return false
    }
  })

export const setOrder = (surface: Surface, accounts: readonly string[]) =>
  withBusy(`route:${surface}`, async () => {
    try {
      await cmux.call(OP.setOrder, { surface, accounts })
    } catch (e) {
      report(e, OP.setOrder)
    }
  })

/** The host sends a fixed tiny prompt with its own credential and reports latency and model. */
export const runTest = () =>
  withBusy("test", async (): Promise<TestResult> => {
    let result: TestResult
    try {
      result = { ...(await cmux.call<TestResult>(OP.test, { surface: "auto" })), at_ms: Date.now() }
    } catch (e) {
      const p = classify(e)
      result = { ok: false, at_ms: Date.now(), error: { code: p.code, message: problemMessage(p, OP.test) } }
    }
    setLastTest(result)
    cmux.storage.set(STORAGE.lastTest, result).catch(() => undefined)
    return result
  })

export async function openPane(kind: "dashboard" | "onboarding") {
  try {
    await cmux.call(OP.openPane, { kind })
    return "pane"
  } catch (e) {
    if (!isUnsupported(e)) report(e, OP.openPane)
    if (kind === "dashboard") await cmux.actions.run(ACTION.showAccounts, {}).catch((e2: unknown) => report(e2, ACTION.showAccounts))
    else say("secondary", t("notice.noPanes", "This cmux build cannot open app panes yet. Use Next CodeRouter Variant for the sidebar checklist."))
    return "fallback"
  }
}

export async function signIn() {
  try {
    await cmux.actions.run(ACTION.signIn, {})
  } catch (e) {
    report(e, ACTION.signIn)
  }
}
