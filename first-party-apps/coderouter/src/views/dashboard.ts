// The dashboard pane: status, accounts, routing, usage, keys and the test.
// Two layouts: every section on one scrolling page, or one section per tab.

import * as act from "../actions.ts"
import type { Core, Insights } from "../data.ts"
import { t } from "../l10n.ts"
import {
  accountStateWord,
  accountTone,
  formatTokens,
  formatUsd,
  healthTone,
  healthWord,
  moveTo,
  recommend,
  relativeAge,
  shares,
  stateWord,
  usageSummary,
  visibilityWord,
  type Account,
  type ApiKey,
  type RouteEntry
} from "../model.ts"
import { OP } from "../ops.ts"
import { isBusy } from "../store.ts"
import { bar, caption, choice, dot, header, loaded, noticeLine, small } from "./common.ts"
import { setupPending } from "./onboarding.ts"
import { addKeyMenu, createdKeyLine, line, testBody } from "./steps.ts"

export type Tab = "overview" | "accounts" | "keys" | "usage" | "routing"

export function statusSection(d: Core) {
  return loaded(d.status, OP.status, (s) => {
    if (!s.signed_in)
      return VStack({ spacing: 6 }, [
        EmptyState({ title: t("problem.signedOut", "Sign in to cmux"), message: t("problem.signedOut.body", "CodeRouter acts as your cmux account and team."), symbol: "person.crop.circle" }),
        HStack([Spacer(), Button(t("action.signIn", "Sign In"), act.signIn), Spacer()])
      ])
    const scope = s.scope?.kind === "team" ? s.scope.team_name : t("scope.personal", "Personal")
    return VStack({ spacing: 4 }, [
      HStack({ spacing: 8 }, [
        dot(() => healthTone(s.health), 10),
        Text(t("status.title", "CodeRouter")).font("title3").weight("semibold"),
        Badge(scope, s.scope?.kind === "team" ? "accent" : "secondary"),
        Spacer(),
        Text(healthWord(s.health)).font("caption").color(healthTone(s.health))
      ]),
      caption(
        [s.user?.name, s.agents_routed ? t("status.agentsOn", "agents use CodeRouter") : t("status.agentsOff", "agents use their own sign-ins"), usageSummary(s.usage_today)].filter(Boolean).join(" · ")
      ),
      () => (setupPending(d) ? HStack([Spacer(), small(t("action.finishSetup", "Finish Setup"), () => act.openPane("onboarding"))]) : null)
    ])
  })
}

function accountRow(a: Account) {
  const now = Date.now()
  const menu = [
    a.visibility === "private"
      ? Button(t("action.shareWithTeam", "Share with Team"), () => act.share([a.id], "team")).disabled(!a.mine)
      : Button(t("action.makePrivate", "Make Private"), () => act.share([a.id], "private")).disabled(!a.mine),
    Button(t("action.signInAgain", "Sign In Again"), () => act.reauthenticate(a.provider)),
    Divider(),
    Button(t("action.remove", "Remove from CodeRouter…"), () => act.remove(a)).destructive()
  ]
  return Row({
    title: a.label,
    subtitle: `${a.name} · ${accountStateWord(a, now)}`,
    symbol: a.visibility === "team" ? "person.2" : "lock",
    tint: accountTone(a, now),
    badge: visibilityWord(a.visibility)
  })
    .help(a.mine ? t("account.mine", "You connected this account") : t("account.teammate", "A teammate shared this account"))
    .contextMenu(menu)
}

export function accountsSection(d: Core) {
  return VStack({ spacing: 2 }, [
    header(t("section.accounts", "Accounts"), () => addKeyMenu(() => d.accounts() ?? [])),
    loaded(d.accounts, OP.accounts, (accounts) => {
      const found = recommend(d.detected() ?? [], accounts)
      if (!accounts.length && !found.length) return EmptyState({ title: t("accounts.empty", "No accounts yet"), message: t("accounts.empty.body", "Sign in to a provider's CLI on this Mac, or add a key."), symbol: "person.crop.circle.badge.plus" })
      return VStack({ spacing: 2 }, [
        ...accounts.map(accountRow),
        found.length ? caption(t("accounts.found", "Found on this Mac")) : null,
        ...found.map((x) => line(() => x.name, () => x.label ?? null, () => (isBusy(`connect:${x.provider}`) ? ProgressView().frame({ width: 16, height: 16 }) : small(t("action.connect", "Connect"), () => act.connect(x.provider, x.name)))))
      ])
    })
  ])
}

export function routingSection(i: Insights) {
  return VStack({ spacing: 2 }, [
    header(
      t("section.routing", "Failover order"),
      choice(
        [
          ["responses", t("route.responses", "OpenAI API")],
          ["messages", t("route.messages", "Anthropic API")]
        ],
        i.surface,
        i.setSurface
      )
    ),
    loaded(i.route, OP.route, (r) => {
      if (!r.order.length) return caption(t("route.empty", "No account serves this API yet."))
      const ids = r.order.map((e) => e.account)
      return VStack({ spacing: 2 }, [
        caption(r.strategy === "ordered" ? t("route.ordered", "CodeRouter tries these in order. Drag to change it.") : t("route.headroom", "CodeRouter picks the account with the most room left, in this order on a tie.")),
        Reorderable<RouteEntry>(
          { items: () => r.order, key: (e) => e.account, onMove: (id, index) => act.setOrder(r.surface, moveTo(ids, id, index)) },
          (e) => Row({ title: () => e().label, subtitle: () => `${e().name} · ${stateWord(e().state, e().cooldown_until_ms, Date.now())}`, symbol: () => `${ids.indexOf(e().account) + 1}.circle`, tint: () => (e().cooldown_until_ms && e().cooldown_until_ms! > Date.now() ? "warning" : "secondary") })
        )
      ])
    })
  ])
}

export function usageSection(i: Insights) {
  return VStack({ spacing: 4 }, [
    header(
      t("section.usage", "Usage"),
      choice(
        [
          ["24h", t("usage.24h", "24 h")],
          ["7d", t("usage.7d", "7 d")],
          ["30d", t("usage.30d", "30 d")]
        ],
        i.usageWindow,
        i.setUsageWindow
      )
    ),
    choice(
      [
        ["account", t("usage.byAccount", "By account")],
        ["model", t("usage.byModel", "By model")],
        ["key", t("usage.byKey", "By key")]
      ],
      i.usageGroup,
      i.setUsageGroup
    ),
    loaded(i.usage, OP.usage, (u) => {
      const f = shares(u.rows)
      return VStack({ spacing: 4 }, [
        HStack({ spacing: 12 }, [
          Text(formatUsd(u.totals.api_equivalent_usd)).font("title3").weight("semibold").monospaced(),
          caption(t("usage.totals", "{tokens} tokens · {requests} requests", { tokens: formatTokens(u.totals.total_tokens), requests: u.totals.requests.toLocaleString("en-US") }))
        ]),
        !u.rows.length
          ? caption(t("usage.empty", "No requests in this window."))
          : VStack(
              { spacing: 4 },
              u.rows.map((row, k) =>
                HStack({ spacing: 8 }, [
                  Text(row.label).font("caption").lineLimit(1).truncation("middle").frame({ width: 140 }),
                  bar(() => f[k] ?? 0, 110),
                  Spacer(),
                  Text(formatTokens(row.total_tokens)).font("caption").monospaced().secondary(),
                  Text(formatUsd(row.api_equivalent_usd)).font("caption").monospaced().frame({ minWidth: 52 })
                ])
              )
            ),
        caption(t("usage.note", "Spend is the API list price of the tokens, not your bill."))
      ])
    })
  ])
}

function keyRow(k: ApiKey) {
  return Row({
    title: k.label,
    subtitle: `${k.prefix}… · ${relativeAge(k.last_used_at_ms, Date.now())}${k.usage_7d ? ` · ${formatTokens(k.usage_7d.total_tokens)} ${t("key.tokens7d", "tok 7 d")}` : ""}`,
    symbol: "key",
    tint: k.revoked ? "tertiary" : "secondary",
    badge: k.revoked ? t("key.revoked", "Revoked") : null
  }).contextMenu(k.revoked ? [] : [Button(t("action.revoke", "Revoke Key…"), () => act.revokeKey(k.id)).destructive()])
}

export function keysSection(d: Core) {
  const [label, setLabel] = signal("")
  return VStack({ spacing: 2 }, [
    header(t("section.keys", "API keys")),
    loaded(d.keys, OP.keys, (keys) => {
      const active = keys.filter((k) => !k.revoked)
      return VStack({ spacing: 2 }, [
        ...active.map(keyRow),
        !active.length ? caption(t("keys.empty", "No keys. A key lets any tool use your team's shared accounts.")) : null
      ])
    }),
    HStack({ spacing: 8 }, [
      TextField(label, { placeholder: t("key.placeholder", "Key name, e.g. editor"), onEdit: setLabel, onSubmit: (text) => act.createKey(text) }),
      () => (isBusy("key:create") ? ProgressView().frame({ width: 16, height: 16 }) : small(t("action.createKey", "Create Key"), () => act.createKey(label())))
    ]).padding({ top: 4, leading: 0, bottom: 0, trailing: 0 }),
    createdKeyLine()
  ])
}

export function testSection() {
  return VStack({ spacing: 2 }, [header(t("section.test", "Test request")), testBody()])
}

/** One problem view instead of the same failure in every section; signed out shows only sign-in. */
function whenReachable(d: Core, body: () => CmuxView): () => CmuxView | null {
  const mode = computed(() => {
    const s = d.status()
    if (s === undefined) return d.status.problem() ? "problem" : "loading"
    return s.signed_in ? "ok" : "signedOut"
  })
  return () => {
    switch (mode()) {
      case "ok":
        return body()
      case "loading":
        return caption(t("state.loading", "Loading…"))
      default:
        return statusSection(d)()
    }
  }
}

/** Every section on one page. */
export function sectionsLayout(d: Core, i: Insights) {
  return VStack({ spacing: 8 }, [whenReachable(d, () => VStack({ spacing: 8 }, [statusSection(d), noticeLine(), accountsSection(d), routingSection(i), usageSection(i), keysSection(d), testSection()]))]).padding(16)
}

/** One section per tab; Overview combines status, a short usage line and the test. */
export function tabsLayout(d: Core, i: Insights, setup: () => CmuxView) {
  // Chosen lazily inside the content binding, so building the layout reads no signal.
  const [chosen, setTab] = signal<Tab | "setup" | null>(null)
  const tab = () => chosen() ?? (setupPending(d) ? "setup" : "overview")
  const tabs: Array<[Tab | "setup", string]> = [
    ["overview", t("tab.overview", "Overview")],
    ["accounts", t("section.accounts", "Accounts")],
    ["keys", t("tab.keys", "Keys")],
    ["usage", t("section.usage", "Usage")],
    ["routing", t("tab.routing", "Routing")],
    ["setup", t("tab.setup", "Setup")]
  ]
  return VStack({ spacing: 10 }, [whenReachable(d, () => VStack({ spacing: 10 }, [
    choice(tabs, tab, setTab),
    Divider(),
    noticeLine(),
    () => {
      switch (tab()) {
        case "overview":
          return VStack({ spacing: 8 }, [statusSection(d), header(t("section.test", "Test request")), testBody()])
        case "accounts":
          return accountsSection(d)
        case "keys":
          return keysSection(d)
        case "usage":
          return usageSection(i)
        case "routing":
          return routingSection(i)
        case "setup":
          return setup()
      }
    }
  ]))]).padding(16)
}
