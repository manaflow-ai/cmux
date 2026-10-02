// The five setup steps: title, one sentence, a one-line state for lists, and
// the body. The wizard, the sidebar checklist and the setup page all use them.

import * as act from "../actions.ts"
import type { Core } from "../data.ts"
import { t } from "../l10n.ts"
import { formatLatency, isConnected, localStatusWord, needsReauth, recommend, relativeAge, type Account, type Detected, type TestResult } from "../model.ts"
import type { Step } from "../onboarding.ts"
import { OP } from "../ops.ts"
import { createdKey, isBusy, lastTest } from "../store.ts"
import { caption, loaded, small } from "./common.ts"

export interface StepSpec {
  title: string
  sentence: string
  /** One line for the checklist row. */
  summary: () => string
  body: () => CmuxView
}

/** Providers the user can add without a local sign-in: cmux asks for the key in its own secure field. */
const PASTE_PROVIDERS: Array<[string, string]> = [
  ["openai", "OpenAI API"],
  ["anthropic", "Anthropic API"],
  ["openrouter", "OpenRouter"],
  ["claude", "Claude Code"]
]

export function stepSpec(step: Step, d: Core): StepSpec {
  switch (step) {
    case "detect":
      return {
        title: t("step.detect", "See what you have"),
        sentence: t("step.detect.body", "cmux checks this Mac for sign-ins and keys. It reads only names and emails, never a key."),
        summary: () => {
          const found = (d.detected() ?? []).filter((x) => x.status !== "missing").length
          return found ? t("step.detect.found", "{n} found on this Mac", { n: found }) : t("step.detect.none", "Nothing found yet")
        },
        body: () => detectBody(d)
      }
    case "connect":
      return {
        title: t("step.connect", "Connect accounts"),
        sentence: t("step.connect.body", "CodeRouter fails over between the accounts you connect. cmux sends each one to CodeRouter; this app never sees it."),
        summary: () => {
          const n = (d.accounts() ?? []).length
          return n ? t("step.connect.count", "{n} connected", { n }) : t("step.connect.none", "None connected")
        },
        body: () => VStack([connectBody(d)])
      }
    case "share":
      return {
        title: t("step.share", "Share with your team"),
        sentence: t("step.share.body", "New accounts are private. Your team's API keys and machines use only shared accounts."),
        summary: () => {
          if (d.status()?.scope?.kind === "personal") return t("step.share.personal", "Personal: not needed")
          if (!mine(d).length) return t("step.share.nothing", "Connect an account first.")
          const n = mine(d).filter((a) => a.visibility === "private").length
          return n ? t("step.share.private", "{n} private", { n }) : t("step.share.allShared", "All shared")
        },
        body: () => VStack([shareBody(d)])
      }
    case "use":
      return {
        title: t("step.use", "Use CodeRouter"),
        sentence: t("step.use.body", "Route the agents you start in cmux through CodeRouter, or create an API key for other tools."),
        summary: () => (d.status()?.agents_routed ? t("step.use.agents", "Agents use CodeRouter") : keyCount(d) ? t("step.use.keys", "{n} API keys", { n: keyCount(d) }) : t("step.use.none", "Not used yet")),
        body: () => useBody(d)
      }
    case "test":
      return {
        title: t("step.test", "Send a test"),
        sentence: t("step.test.body", "cmux sends one tiny prompt through CodeRouter and shows which model and account answered."),
        summary: () => testSummary(lastTest()),
        body: () => testBody()
      }
  }
}

const mine = (d: Core) => (d.accounts() ?? []).filter((a) => a.mine)
const keyCount = (d: Core) => (d.keys() ?? []).filter((k) => !k.revoked).length

/** One line: name, quiet detail, trailing control. */
export function line(title: () => string, detail: () => string | null, trailing: () => CmuxView | null) {
  return HStack({ spacing: 8 }, [
    VStack({ spacing: 0 }, [Text(title).lineLimit(1), () => (detail() ? Text(detail).font("caption").secondary().lineLimit(1).truncation("middle") : null)]).layoutPriority(1),
    Spacer(),
    trailing
  ]).frame({ minHeight: 28 })
}

function busyOr(key: string, view: () => CmuxView | null): () => CmuxView | null {
  return () => (isBusy(key) ? ProgressView().frame({ width: 16, height: 16 }) : view())
}

function detectBody(d: Core) {
  return VStack({ spacing: 4 }, [
    loaded(d.detected, OP.detect, (all) => {
      const found = all.filter((x) => x.status !== "missing")
      if (!found.length) return caption(t("step.detect.empty", "No sign-ins or keys on this Mac. You can paste a key in the next step."))
      return VStack(
        { spacing: 2 },
        found.map((x) =>
          line(
            () => x.name,
            () => [x.identity, x.plan].filter(Boolean).join(" · ") || x.source || null,
            () => Text(localStatusWord(x)).font("caption").color(x.status === "signed_in" ? "success" : x.status === "expired" ? "warning" : "secondary")
          )
        )
      )
    }, t("step.detect.scanning", "Checking this Mac…")),
    HStack([Spacer(), small(t("action.rescan", "Check Again"), () => d.detected.refresh())])
  ])
}

/** "Add with a Key…": cmux opens its own secure paste field for the chosen provider. */
export function addKeyMenu(accounts: () => readonly Account[], exclude: readonly string[] = []) {
  return Menu(
    t("action.addKey", "Add with a Key…"),
    PASTE_PROVIDERS.filter(([p]) => !exclude.includes(p) && !isConnected(p, accounts())).map(([p, name]) => Button(name, () => act.connect(p, name)))
  ).font("caption")
}

function connectRow(x: Detected) {
  return line(
    () => x.name,
    () => x.identity ?? null,
    busyOr(`connect:${x.provider}`, () => small(t("action.connect", "Connect"), () => act.connect(x.provider, x.name)))
  )
}

function connectBody(d: Core) {
  return loaded(d.accounts, OP.accounts, (accounts) => {
    const detected = d.detected() ?? []
    const best = recommend(detected, accounts)
    const expired = needsReauth(detected).filter((x) => !isConnected(x.provider, accounts))
    const others = PASTE_PROVIDERS.filter(([p]) => !isConnected(p, accounts) && !best.some((b) => b.provider === p))
    return VStack({ spacing: 2 }, [
      ...accounts.map((a) => line(() => a.name, () => a.label, () => Text(t("state.connected", "Connected")).font("caption").color("success"))),
      ...best.map(connectRow),
      ...expired.map((x) => line(() => x.name, () => t("detect.expired", "Expired"), () => small(t("action.signInAgain", "Sign In Again"), () => act.reauthenticate(x.provider)))),
      others.length ? HStack([Spacer(), addKeyMenu(() => accounts, best.map((b) => b.provider))]) : null,
      !accounts.length && !best.length ? caption(t("step.connect.empty", "Nothing to connect yet. Add a key, or sign in to a provider's CLI and check again.")) : null
    ])
  })
}

function shareBody(d: Core) {
  return loaded(d.accounts, OP.accounts, () => {
    const scope = d.status()?.scope
    if (scope?.kind === "personal") return caption(t("step.share.personalBody", "You are in your personal scope: your accounts already serve your own machines and keys."))
    const own = mine(d)
    const privateIds = own.filter((a) => a.visibility === "private").map((a) => a.id)
    if (!own.length) return caption(t("step.share.nothing", "Connect an account first."))
    return VStack({ spacing: 2 }, [
      ...own.map((a: Account) =>
        line(
          () => a.name,
          () => a.label,
          busyOr(`share:${a.id}`, () =>
            a.visibility === "team" ? small(t("action.makePrivate", "Make Private"), () => act.share([a.id], "private")) : small(t("action.share", "Share"), () => act.share([a.id], "team"))
          )
        )
      ),
      privateIds.length > 1 ? HStack([Spacer(), busyOr(`share:${privateIds.join(",")}`, () => small(t("action.shareAll", "Share All with {team}", { team: scope?.team_name ?? "" }), () => act.share(privateIds, "team")))]) : null
    ])
  })
}

function useBody(d: Core) {
  const [label, setLabel] = signal("")
  return VStack({ spacing: 6 }, [
    line(
      () => t("use.agents", "cmux agents"),
      () => (d.status()?.agents_routed ? t("use.agents.on", "Use CodeRouter") : t("use.agents.off", "Use their own sign-ins")),
      busyOr("agents", () => (d.status()?.agents_routed ? small(t("action.turnOff", "Turn Off"), () => act.setAgentsRouted(false)) : small(t("action.turnOn", "Turn On"), () => act.setAgentsRouted(true))))
    ),
    HStack({ spacing: 8 }, [
      TextField(label, { placeholder: t("key.placeholder", "Key name, e.g. editor"), onEdit: setLabel, onSubmit: (text) => act.createKey(text) }),
      busyOr("key:create", () => small(t("action.createKey", "Create Key"), () => act.createKey(label())))
    ]),
    createdKeyLine()
  ])
}

/** After create: the masked prefix and host-performed Show / Copy while the handle is valid. */
export function createdKeyLine() {
  return () => {
    const k = createdKey()
    if (!k) return null
    const live = !k.handle_expires_at_ms || k.handle_expires_at_ms > Date.now()
    return HStack({ spacing: 8 }, [
      Icon("key").color("success"),
      Text(t("key.created", "{label} created ({prefix}…)", { label: k.key.label, prefix: k.key.prefix })).font("caption").lineLimit(1),
      Spacer(),
      live ? small(t("action.show", "Show"), () => act.revealKey(k.handle)) : null,
      live ? small(t("action.copy", "Copy"), () => act.copyKey(k.handle)) : null
    ])
  }
}

export function testSummary(r: TestResult | null): string {
  if (!r) return t("test.never", "Not run yet")
  if (!r.ok) return t("test.failed", "Failed: {message}", { message: r.error?.message ?? "" })
  return t("test.ok", "{model} in {latency}", { model: r.model ?? "?", latency: formatLatency(r.latency_ms ?? NaN) })
}

export function testBody() {
  return VStack({ spacing: 6 }, [
    HStack([busyOr("test", () => Button(t("action.runTest", "Run Test"), () => act.runTest())), Spacer()]),
    () => {
      const r = lastTest()
      if (!r) return null
      if (!r.ok) return Text(testSummary(r)).font("caption").color("danger").lineLimit(3)
      return VStack({ spacing: 2 }, [
        HStack({ spacing: 6 }, [Icon("checkmark.circle.fill").color("success"), Text(testSummary(r)).font("callout").monospaced()]),
        caption(t("test.detail", "via {account} · {age}", { account: [r.provider_name, r.account_label].filter(Boolean).join(" "), age: relativeAge(r.at_ms, Date.now()) })),
        r.request_id ? Text(t("test.request", "Request {id}", { id: r.request_id })).font("caption2").color("tertiary").monospaced().lineLimit(1).truncation("middle") : null
      ])
    }
  ])
}
