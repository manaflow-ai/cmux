// The three designs of the main pane (DEV/NIGHTLY setting `variant`):
//   connections  list of connections; a row opens its detail (health, sharing, tools)
//   gallery      onboarding first: every provider with Connect, then your connections
//   catalog      every tool of every connection with its Allow / Ask / Block policy
// Detail, add and import screens are shared by all three.

import { t } from "../l10n.ts"
import { refresh } from "../model/actions.ts"
import { counts, displayName, policySourceLabel, type Connection } from "../model/connections.ts"
import { connections, loading, loadProblem, open, route, teamPolicy } from "../model/store.ts"
import { loadTools } from "../model/tools.ts"
import { variant } from "../settings.ts"
import { connectionRow, header, noticeLine, problemState, sectionTitle, smallButton } from "./common.ts"
import { detailView } from "./detail.ts"
import { gallery } from "./gallery.ts"
import { importView } from "./importer.ts"
import { toolList } from "./policy.ts"

const shape = computed(() => (loading() ? "loading" : loadProblem() ? "problem" : connections().length === 0 ? "empty" : "list"))

/** Loading, problem and empty states every home screen shares; null when there are connections to show. */
function homeState(emptyAction: boolean) {
  switch (shape()) {
    case "loading":
      return Text(t("home.loading", "Loading integrations")).font("caption").color("secondary").padding(12)
    case "problem":
      return problemState(loadProblem()!)
    case "empty":
      return VStack({ spacing: 8 }, [
        EmptyState({ title: t("home.empty", "No integrations yet"), message: t("home.empty.message", "Connect GitHub, Linear, Slack or any API so agents and automations can use it."), symbol: "puzzlepiece.extension" }),
        emptyAction ? HStack({ spacing: 0 }, [Spacer(), smallButton(t("action.connectFirst", "Connect an App"), () => open({ screen: "add" })), Spacer()]) : null
      ])
    default:
      return null
  }
}

const teamLine = () => {
  const p = teamPolicy()
  const text = p ? policySourceLabel(p) : null
  return text ? Text(text).font("caption2").color("tertiary").padding({ top: 6, leading: 12, bottom: 8, trailing: 12 }) : null
}

const summary = () => {
  const n = counts(connections())
  if (n.attention > 0) return Text(t("home.attention", "{n} need attention", { n: n.attention })).font("caption").color("warning").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 })
  return null
}

const connectionList = () => ForEach({ items: connections, key: (c: Connection) => c.id }, (c) => connectionRow(c, () => open({ screen: "detail", id: c().id })))

function connectionsHome() {
  return VStack({ spacing: 0 }, [
    header(t("home.title", "Integrations"), [smallButton(t("action.add", "Add"), () => open({ screen: "add" }))]),
    noticeLine(),
    () => {
      shape()
      return untrack(() => homeState(true) ?? VStack({ spacing: 0 }, [() => summary(), connectionList()]))
    },
    () => teamLine()
  ])
}

function galleryHome() {
  return VStack({ spacing: 0 }, [
    header(t("home.title", "Integrations")),
    noticeLine(),
    () => teamLine(),
    gallery(),
    () => {
      const k = shape()
      return untrack(() => (k === "list" ? VStack({ spacing: 0 }, [sectionTitle(t("home.yours", "Your connections")), () => summary(), connectionList()]) : k === "problem" ? problemState(loadProblem()!) : null))
    }
  ])
}

const [filter, setFilter] = signal("")

/** Active connections whose tools to list; loading their catalogs is the screen's only side effect. */
const activeIds = computed(() =>
  connections()
    .filter((c) => c.status === "active")
    .map((c) => c.id)
    .join(",")
)

function catalogHome() {
  effect(() => {
    const ids = activeIds()
    untrack(() => {
      for (const c of connections()) if (ids.split(",").includes(c.id)) loadTools(c)
    })
  })
  return VStack({ spacing: 0 }, [
    header(t("catalog.title", "Tools"), [smallButton(t("action.add", "Add"), () => open({ screen: "add" }))]),
    noticeLine(),
    TextField(filter, { placeholder: t("catalog.filter", "Filter tools"), onEdit: setFilter, onCancel: () => setFilter("") }).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
    Text(t("catalog.help", "Allow runs without asking. Ask needs your approval each time. Block never runs.")).font("caption2").color("tertiary").lineLimit(2).padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }),
    () => {
      const ids = activeIds()
      shape()
      return untrack(() => catalogSections(ids))
    },
    () => teamLine()
  ])
}

function catalogSections(activeList: string) {
  return (
      homeState(true) ??
      VStack(
        { spacing: 0 },
        activeList
          .split(",")
          .filter(Boolean)
          .map((id) => {
            const c = () => connections().find((x) => x.id === id)!
            return VStack({ spacing: 0 }, [
              HStack({ spacing: 6 }, [Text(() => displayName(c())).font("caption").weight("semibold"), Spacer()])
                .padding({ top: 10, leading: 12, bottom: 2, trailing: 12 })
                .cursor("pointer")
                .onTap(() => open({ screen: "detail", id })),
              toolList(c, filter, 25)
            ])
          })
      )
  )
}

function addView() {
  return VStack({ spacing: 0 }, [header(t("add.title", "Connect"), [], true), noticeLine(), gallery()])
}

/** The pane: one function child keyed on the screen, so a list reload never rebuilds a screen. */
export function paneView() {
  const screen = computed(() => {
    const r = route()
    return r.screen === "detail" ? `detail:${r.id}` : r.screen === "home" ? `home:${variant()}` : r.screen
  })
  return VStack({ spacing: 0 }, [
    () => {
      const key = screen()
      // Build untracked: a screen's own reads and loads must not rebuild the screen.
      return untrack(() => {
        if (key.startsWith("detail:")) return detailView(key.slice("detail:".length))
        if (key === "add") return addView()
        if (key === "import") return importView()
        if (key === "home:gallery") return galleryHome()
        if (key === "home:catalog") return catalogHome()
        return connectionsHome()
      })
    }
  ])
}

export { refresh }
