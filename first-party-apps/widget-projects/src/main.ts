// Projects: your recent projects as a widget, each with its own tile, and which machine they are on.
// - small: the machine's name with its colored dot, then four project tiles in a 2x2 grid.
// - medium: the same header, eight tiles in two rows of four.
// - large: a list of eight: tile, name, short path and how long ago it was used.
// A tile is the project's letter on a color of its own (a hash of its path, so it never moves).
// Tapping a project opens a new workspace there (workspace.create with its folder as cwd).
//
// It imports nothing but the public SDK. Projects come from the daemon's project index
// (project.list: pinned first, then the most recently used, hidden and missing ones left out); the
// machine's name from machine.get. The index has no change stream yet, so the list re-reads on the
// host's minute tick, and only while the tile is shown.

import { cmux, effect, HStack, Spacer, Text, VStack, WIDGET_INSET, ZStack, type View, type WidgetContext } from "cmux-extension-sdk"
import { age, colorOf, COUNT, displayName, letterOf, machineColor, READ, recent, shortPath, type Project, type Size } from "./projects.ts"
import { SAMPLE_MACHINE, SAMPLE_PROJECTS } from "./sample.ts"

type Load = { state: "loading" } | { state: "ready"; projects: Project[] } | { state: "error"; code: string }
type Machine = { id?: string; name: string }

/** Apple's widget type scale for this layout, in points. */
const TYPE = { heading: 11, name: 11, row: 13, detail: 11 } as const
/** The tile's side per size, in points. */
const TILE: Record<Size, number> = { small: 40, medium: 40, large: 28 }

const t = (key: string, fallback: string, params?: Record<string, unknown>) => cmux.t(key, fallback, params)

export function renderProjects(ctx: WidgetContext): View {
  const size: Size = (ctx.size as Size) ?? "small"
  const preview = Boolean(ctx.preview)
  const list = preview ? null : cmux.live<{ projects?: Project[] }>("project.list", { ...READ })
  const machine = preview ? null : cmux.live<Machine>("machine.get", {})
  // The index has no change stream: re-read on the host's minute tick (sent only while the tile shows).
  if (list) {
    let first = true
    effect(() => {
      ctx.now()
      if (first) first = false
      else list.refresh()
    })
  }

  const load = (): Load => {
    if (!list) return { state: "ready", projects: SAMPLE_PROJECTS(ctx.now()) }
    const answer = list()
    const error = list.error()
    if (!answer && error) return { state: "error", code: error.code ?? "operation.failed" }
    if (!answer) return { state: "loading" }
    return { state: "ready", projects: answer.projects ?? [] }
  }
  const machineNow = (): Machine | null => (machine ? (machine() ?? null) : SAMPLE_MACHINE)

  const open = (p: Project) => {
    if (preview) return
    cmux.workspace
      .create({ initial_content: "terminal", cwd: p.path, name: displayName(p), focus: true })
      .catch(() => cmux.toast({ title: t("openFailed", "Could not open {name}", { name: displayName(p) }), tone: "warning" }))
  }

  const inset = ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab
  const body = () => {
    const current = load()
    const head = header(machineNow(), size === "small")
    if (current.state === "loading") return VStack({ spacing: 8, alignment: "leading" }, [head, Spacer()])
    if (current.state === "error") return VStack({ spacing: 8, alignment: "leading" }, [head, notice(errorText(current.code)), Spacer()])
    const shown = recent(current.projects, COUNT[size])
    if (shown.length === 0) return VStack({ spacing: 8, alignment: "leading" }, [head, notice(t("empty", "Open a folder in cmux and it shows here.")), Spacer()])
    if (size === "large") return VStack({ spacing: 8, alignment: "leading" }, [head, ...shown.map((p) => row(p, ctx.now(), open)), Spacer()])
    return VStack({ spacing: 10, alignment: "leading" }, [head, grid(shown, size === "small" ? 2 : 4, open), Spacer()])
  }
  return VStack({ alignment: "leading", spacing: 0 }, [body])
    .padding(inset)
    .frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" })
}

/** "PROJECTS" and, on the right, the machine's name after its own colored dot: which Mac these are on.
 * The small tile has room for one of them: the machine's name when it has one. */
function header(machine: Machine | null, compact: boolean): View {
  const title = Text(t("title", "PROJECTS")).font(TYPE.heading).weight("semibold").color("secondary").lineLimit(1)
  return HStack({ spacing: 6, alignment: "center" }, [
    compact && machine?.name ? null : title,
    compact && machine?.name ? null : Spacer(),
    machine?.name
      ? HStack({ spacing: 4, alignment: "center" }, [
          VStack([]).frame({ width: 7, height: 7 }).background(machineColor(machine.id, machine.name)).cornerRadius(3.5),
          Text(machine.name).font(TYPE.heading).weight("semibold").lineLimit(1)
        ])
      : null
  ]).frame({ maxWidth: "infinity" })
}

/** The project's tile: its letter in white on its own color, a continuous corner like an app icon. */
function tile(p: Project, side: number): View {
  return ZStack([
    VStack([]).frame({ width: side, height: side }).background(colorOf(p.path)).cornerRadius(side * 0.225),
    Text(letterOf(displayName(p))).font(Math.round(side * 0.5)).weight("semibold").color("#ffffff")
  ]).frame({ width: side, height: side })
}

/** Tiles in rows of `columns`, each with its name under it, like the Home Screen. */
function grid(projects: Project[], columns: number, open: (p: Project) => void): View {
  const rows: View[] = []
  for (let i = 0; i < projects.length; i += columns) {
    const cells: View[] = projects.slice(i, i + columns).map((p) =>
      VStack({ spacing: 4, alignment: "center" }, [tile(p, TILE.small), Text(displayName(p)).font(TYPE.name).lineLimit(1)])
        .frame({ maxWidth: "infinity" })
        .onTap(() => open(p))
    )
    while (cells.length < columns) cells.push(VStack([]).frame({ maxWidth: "infinity" }))
    rows.push(HStack({ spacing: 8, alignment: "top" }, cells).frame({ maxWidth: "infinity" }))
  }
  return VStack({ spacing: 8, alignment: "leading" }, rows).frame({ maxWidth: "infinity" })
}

/** A list row: tile, name over the short path, and how long ago on the right. */
function row(p: Project, now: number, open: (p: Project) => void): View {
  return HStack({ spacing: 8, alignment: "center" }, [
    tile(p, TILE.large),
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(displayName(p)).font(TYPE.row).weight("medium").lineLimit(1),
      Text(shortPath(p.path)).font(TYPE.detail).color("secondary").lineLimit(1)
    ]),
    Spacer(),
    Text(age(Number(p.last_used_ms) || 0, now)).font(TYPE.detail).color("secondary").lineLimit(1)
  ])
    .frame({ maxWidth: "infinity" })
    .onTap(() => open(p))
}

function notice(text: string): View {
  return Text(text).font(TYPE.detail).color("secondary").lineLimit(4)
}

function errorText(code: string): string {
  if (code === "scope.missing") return t("scope", "Turn on project access for Projects in Settings > Apps.")
  return t("failed", "Your projects could not be read just now.")
}
