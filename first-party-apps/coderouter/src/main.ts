/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// CodeRouter: status, accounts, keys, usage, failover order, a test request,
// and first-run setup for cmux's hosted model router. Exports are the
// contributions in cmux-app.json. Every secret stays in the host.

import * as act from "./actions.ts"
import { core, factsOf, insights } from "./data.ts"
import { t } from "./l10n.ts"
import { recommend, type Account, type Detected, type KeyCreated, type Status } from "./model.ts"
import { OP } from "./ops.ts"
import { applyLocale, cycleVariant as cycle, loadProgress, onboard, variant } from "./store.ts"
import { sectionsLayout, tabsLayout } from "./views/dashboard.ts"
import { checklist, page, wizard } from "./views/onboarding.ts"
import { section, statusItem } from "./views/surfaces.ts"

type Ctx = { locale?: string }

function prepare(ctx: Ctx) {
  applyLocale(ctx)
  loadProgress()
}

export function renderSection(ctx: Ctx = {}) {
  prepare(ctx)
  return section(core())
}

export function renderStatus(ctx: Ctx = {}) {
  prepare(ctx)
  return statusItem(core(true))
}

/** Pane kind `dashboard`. */
export function renderDashboard(ctx: Ctx = {}) {
  prepare(ctx)
  const d = core()
  const i = insights()
  return VStack([() => (variant() === "tabs" ? tabsLayout(d, i, () => page(d, 0)) : sectionsLayout(d, i))])
}

/** Pane kind `onboarding`: the variant's setup layout. */
export function renderOnboarding(ctx: Ctx = {}) {
  prepare(ctx)
  const d = core()
  return VStack([
    () => {
      switch (variant()) {
        case "wizard":
          return wizard(d)
        case "tabs":
          return page(d)
        default:
          return checklist(d).padding(16)
      }
    }
  ])
}

// MARK: Commands (palette, CLI, MCP). Each returns plain metadata.

export async function open() {
  return { opened: await act.openPane("dashboard") }
}

/** Connects `provider`, or the best account found on this Mac that is not connected yet. */
export async function connectAccount(args: { provider?: string } = {}) {
  let provider = args.provider
  let name = provider ?? ""
  if (!provider) {
    const [detected, accounts] = await Promise.all([cmux.call<Detected[]>(OP.detect, {}), cmux.call<Account[]>(OP.accounts, {})])
    const best = recommend(detected, accounts)[0]
    if (!best) return { connected: false, reason: t("command.nothingToConnect", "Nothing new to connect on this Mac.") }
    provider = best.provider
    name = best.name
  }
  return { provider, connected: await act.connect(provider, name) }
}

export async function createKey(args: { label?: string } = {}) {
  const created: KeyCreated | null = await act.createKey(args.label ?? "")
  return created ? { id: created.key.id, label: created.key.label, prefix: created.key.prefix, shownBy: "cmux" } : { created: false }
}

export async function runTest() {
  return act.runTest()
}

export async function startOnboarding() {
  await loadProgress()
  const [status, accounts] = await Promise.all([cmux.call<Status>(OP.status, {}).catch(() => undefined), cmux.call<Account[]>(OP.accounts, {}).catch(() => undefined)])
  const p = onboard({ type: "restart" }, factsOf(status, accounts, undefined, false))
  return { step: p.current, opened: await act.openPane("onboarding") }
}

export async function cycleVariant() {
  return { variant: await cycle() }
}
