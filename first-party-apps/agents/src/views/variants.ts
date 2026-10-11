// The hub pane's three designs (DEV/NIGHTLY setting `variant`):
//   byCli     one block per CLI, a line per machine, accounts under each line
//   byMachine one section per machine, a row per CLI, missing ones folded
//   matrix    CLI by machine grid of versions, details of the selected cell below

import { type CliEntry, highestLevel, type Machine, statusOf } from "../model/entries.ts"
import { displayName, providerRank } from "../model/providers.ts"
import { shortVersion } from "../model/version.ts"
import { t } from "../l10n.ts"
import { showMissing } from "../settings.ts"
import { byMachine, jobOf, loaded, machines, machinesError, selected, setSelected, stateOf } from "../store.ts"
import { accountLines, allLists, badgeFor, errorState, hintLines, levelBadge, machineName, nameOf, primaryAction, statusSymbol, statusTone, toolbar, versionLine } from "./common.ts"
import { summaryText } from "./section.ts"
import { jobText } from "./common.ts"

type Cell = { machine: Machine; entry: CliEntry | null }
type CliGroup = { cli: string; name: string; cells: Cell[]; installedAnywhere: boolean }

/** Every CLI any machine reports, with one cell per machine. */
export function groups(): CliGroup[] {
  const ms = machines()
  const all = byMachine()
  const ids = new Set<string>()
  for (const m of ms) for (const e of all[m.id]?.entries ?? []) ids.add(e.cli)
  const out = [...ids].map((cli) => {
    const cells = ms.map((m) => ({ machine: m, entry: all[m.id]?.entries.find((e) => e.cli === cli) ?? null }))
    const any = cells.find((c) => c.entry)?.entry
    return { cli, name: displayName(cli, any?.name), cells, installedAnywhere: cells.some((c) => c.entry?.installed) }
  })
  return out.sort((a, b) => Number(b.installedAnywhere) - Number(a.installedAnywhere) || providerRank(a.cli) - providerRank(b.cli) || a.cli.localeCompare(b.cli))
}

/** Loading, a whole-pane error, or nothing (the variant renders). */
function gate() {
  const err = machinesError()
  if (err) return errorState(err)
  const ms = machines()
  if (!loaded()) return Text(t("loading", "Looking for agent CLIs…")).font("callout").secondary().padding(16)
  const errors = ms.map((m) => stateOf(m.id).error)
  if (ms.length && errors.every(Boolean)) return errorState(errors[0]!)
  if (allLists().every((l) => l.length === 0)) return EmptyState({ title: t("empty.none", "No agent CLIs reported"), symbol: "terminal" })
  return null
}

const frame = (body: () => unknown) =>
  VStack({ spacing: 0 }, [toolbar(() => summaryText(allLists())), Divider(), () => gate() ?? body()])

const machineError = (m: Machine) => {
  const err = stateOf(m.id).error
  return err ? Text(t("machine.error", "{machine}: {message}", { machine: machineName(m), message: err.message })).font("caption").color("danger").lineLimit(2) : null
}

// MARK: byCli

function cliLine(c: Cell) {
  const entry = () => c.entry!
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 8 }, [
      Icon(statusSymbol(statusOf(c.entry!))).font("caption").color(statusTone(statusOf(c.entry!))),
      Text(machineName(c.machine)).font("callout").frame({ width: 110 }).lineLimit(1).truncation("tail"),
      Text(() => versionLine(entry())).font("callout").monospaced().secondary().lineLimit(1),
      Spacer(),
      primaryAction(c.machine.id, entry)
    ]),
    HStack({ spacing: 0 }, [Spacer().frame({ width: 26 }), accountLines(c.machine.id, entry)])
  ])
}

function cliBlock(g: () => CliGroup) {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 8 }, [
      Text(() => g().name).font("headline"),
      () => badgeFor(highestLevel(g().cells.map((c) => c.entry))),
      Spacer()
    ]),
    () => VStack({ spacing: 6 }, g().cells.filter((c) => c.entry?.installed).map(cliLine)),
    () => {
      const missingOn = g().cells.filter((c) => !c.entry?.installed)
      if (!missingOn.length || (!showMissing() && g().installedAnywhere)) return null
      const local = missingOn[0]!
      return VStack({ spacing: 3 }, [
        HStack({ spacing: 8 }, [
          Text(t("missingOn", "Not on {machines}", { machines: missingOn.map((c) => machineName(c.machine)).join(", ") })).font("caption").secondary().lineLimit(1),
          Spacer(),
          primaryAction(local.machine.id, () => local.entry ?? { cli: g().cli, installed: false, version: null, latest: null, install_method: null, updatable: false, accounts: [] })
        ]),
        hintLines(local.machine.id, g().cli)
      ])
    }
  ]).padding({ top: 10, leading: 12, bottom: 10, trailing: 12 })
}

export function byCliView() {
  return frame(() =>
    VStack({ spacing: 0 }, [
      VStack({ spacing: 2 }, machines().map(machineError)).padding({ top: 0, leading: 12, bottom: 0, trailing: 12 }),
      ForEach({ items: () => groups().filter((g) => g.installedAnywhere || showMissing()), key: (g) => g.cli }, (g) => VStack({ spacing: 0 }, [cliBlock(g), Divider()]))
    ])
  )
}

// MARK: byMachine

const [unfolded, setUnfolded] = signal<Record<string, boolean>>({})

function machineRow(machine: string, e: () => CliEntry) {
  return HStack({ spacing: 10 }, [
    Icon(() => statusSymbol(statusOf(e()))).color(() => statusTone(statusOf(e()))),
    VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [Text(() => nameOf(e())).font("body").weight("medium"), () => levelBadge(e())]),
      Text(() => versionLine(e())).font("caption").monospaced().secondary(),
      accountLines(machine, e),
      () => (e().installed ? null : hintLines(machine, e().cli))
    ]).frame({ maxWidth: "infinity" }),
    primaryAction(machine, e)
  ]).padding({ top: 6, leading: 12, bottom: 6, trailing: 12 })
}

function machineSection(m: () => Machine) {
  const id = () => m().id
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 6 }, [
      Icon(() => (m().origin === "local" ? "laptopcomputer" : "server.rack")).secondary(),
      Text(() => machineName(m())).font("headline"),
      Text(() => (m().status === "running" ? "" : m().status)).font("caption").secondary(),
      Spacer()
    ]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }),
    () => machineError(m()),
    ForEach({ items: () => stateOf(id()).entries.filter((e) => e.installed), key: (e) => e.cli }, (e) => machineRow(id(), e)),
    () => {
      const missing = stateOf(id()).entries.filter((e) => !e.installed)
      if (!missing.length || !showMissing()) return null
      const open = !!unfolded()[id()]
      return VStack({ spacing: 0 }, [
        HStack({ spacing: 6 }, [
          Icon(open ? "chevron.down" : "chevron.right").font("caption").secondary(),
          Text(t("folded.missing", "Not installed ({n})", { n: missing.length })).font("callout").secondary(),
          Spacer()
        ])
          .padding({ top: 6, leading: 12, bottom: 6, trailing: 12 })
          .onTap(() => setUnfolded((u) => ({ ...u, [id()]: !open }))),
        open ? VStack({ spacing: 0 }, missing.map((e) => machineRow(id(), () => e))) : null
      ])
    },
    Divider()
  ])
}

export function byMachineView() {
  return frame(() => ForEach({ items: machines, key: (m) => m.id || "local" }, (m) => machineSection(m)))
}

// MARK: matrix

const NAME_W = 120
const CELL_W = 96

function cellView(g: CliGroup, c: Cell) {
  const e = c.entry
  const s = e ? statusOf(e) : "missing"
  const job = e ? jobOf(c.machine.id, e.cli) : null
  const text = job ? "…" : s === "missing" ? "—" : shortVersion(e!.version) || "?"
  const isSel = () => selected()?.machine === c.machine.id && selected()?.cli === g.cli
  return HStack({ spacing: 4 }, [Icon(statusSymbol(s)).font("caption").color(statusTone(s)), Text(text).font(11).monospaced().lineLimit(1)])
    .padding({ top: 4, leading: 6, bottom: 4, trailing: 6 })
    .frame({ width: CELL_W })
    .background(() => (isSel() ? "selected" : null))
    .hoverBackground("hover")
    .cornerRadius(5)
    .onTap(() => setSelected({ machine: c.machine.id, cli: g.cli }))
}

function detail() {
  return () => {
    const sel = selected()
    const g = sel ? groups().find((x) => x.cli === sel.cli) : groups()[0]
    if (!g) return null
    const c = g.cells.find((x) => x.machine.id === (sel?.machine ?? g.cells[0]?.machine.id)) ?? g.cells[0]
    if (!c) return null
    const entry = () => groups().find((x) => x.cli === g.cli)?.cells.find((x) => x.machine.id === c.machine.id)?.entry ?? { cli: g.cli, installed: false, version: null, latest: null, install_method: null, updatable: false, accounts: [] }
    const e = entry()
    const job = jobOf(c.machine.id, g.cli)
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 8 }, [Text(t("detail.title", "{cli} on {machine}", { cli: g.name, machine: machineName(c.machine) })).font("headline"), levelBadge(e), Spacer(), primaryAction(c.machine.id, entry)]),
      Text(versionLine(e)).font("callout").monospaced().secondary(),
      e.path_label ? Text(e.path_label).font("caption").monospaced().secondary().lineLimit(1).truncation("middle") : null,
      e.install_method && e.installed ? Text(t("detail.method", "Installed with {method}", { method: e.install_method })).font("caption").secondary() : null,
      job && job.phase === "succeeded" ? Text(jobText(job)).font("caption").color("success") : null,
      accountLines(c.machine.id, entry),
      e.installed ? null : hintLines(c.machine.id, g.cli)
    ]).padding(12)
  }
}

export function matrixView() {
  return frame(() =>
    VStack({ spacing: 0 }, [
      HStack({ spacing: 0 }, [
        Text("").frame({ width: NAME_W }),
        ...machines().map((m) => Text(machineName(m)).font("caption").weight("semibold").secondary().lineLimit(1).truncation("tail").frame({ width: CELL_W }).padding({ top: 0, leading: 6, bottom: 0, trailing: 0 })),
        Spacer()
      ]).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 }),
      ForEach({ items: () => groups().filter((g) => g.installedAnywhere || showMissing()), key: (g) => g.cli }, (g) =>
        HStack({ spacing: 0 }, [
          Text(() => g().name).font("callout").lineLimit(1).truncation("tail").frame({ width: NAME_W }),
          () => HStack({ spacing: 0 }, g().cells.map((c) => cellView(g(), c))),
          Spacer()
        ]).padding({ top: 1, leading: 12, bottom: 1, trailing: 12 })
      ),
      Divider().padding({ top: 6, leading: 0, bottom: 0, trailing: 0 }),
      detail()
    ])
  )
}
