// Design systems (`cmux.design/1`): cmux's own type roles, spacing scale, color roles and limits
// as data, a person's system on top of it, and a view that shows one.
//
// A person's system is a file, `cmux-design.json`, beside the extension's manifest. Everything it
// does not set comes from cmux's: it overrides type roles or adds its own, replaces the spacing
// scale, names cmux color roles (so dark mode and contrast still hold) and moves the limits.
// `cmux ext dev` reads the same file and checks the extension's scenes against the merged system.
//
//     import spec from "../cmux-design.json" with { type: "json" }
//     const design = defineDesign(spec)
//     export const renderStat = widget(() => WidgetFrame([design.text("numeral", "72°"), design.text("caption", "Lisbon")]))

import { Badge, Button, Divider, HStack, Icon, ProgressView, Spacer, Text, Toggle, VStack, signal, type View } from "./index.ts"
import { SPACE, TYPE_ROLES } from "./tokens.ts"

/** The weights a type role may have. */
export type DesignWeight = "regular" | "medium" | "semibold" | "bold"
/** The cmux color roles a system's color names may stand for: the ones that keep contrast in light and dark. */
export type ColorRole = "primary" | "secondary" | "tertiary" | "accent" | "success" | "warning" | "danger" | "separator"
/** One type role: a point size and a weight, monospaced digits and letters when `monospaced`. */
export type DesignType = { size: number; weight: DesignWeight; monospaced?: boolean }

/**
 * A design system: cmux's (`cmuxDesign`) or a person's merged over it (`defineDesign`). Draw text
 * with `text(role, ...)` and name colors with `color(name)`, so every view follows the system.
 */
export type DesignSystem = {
  readonly name: string
  readonly type: Readonly<Record<string, DesignType>>
  /** The spacing scale, in points: ascending, from 0. Every gap and padding is one of these. */
  readonly space: readonly number[]
  /** The system's color names, each a cmux color role (cmux's own map each role to itself). */
  readonly colors: Readonly<Record<string, ColorRole>>
  /** Text styles and accent colors one view may use. */
  readonly limits: { readonly typeRoles: number; readonly accents: number }
  /** Text in one of the system's type roles, one line unless `lines` says more. */
  text(role: string, text: string | number | (() => string | number), options?: { lines?: number }): View
  /** The cmux color role a system color name stands for. */
  color(name: string): ColorRole
}

/**
 * A `cmux-design.json` document as it reads from JSON: loose types, checked by `defineDesign`.
 * Every field but `design` is optional; what it leaves out comes from cmux's system.
 */
export type DesignSpec = {
  design: string
  name?: string
  type?: Record<string, { size: number; weight?: string; monospaced?: boolean }>
  space?: readonly number[]
  colors?: Record<string, string>
  limits?: { typeRoles?: number; accents?: number }
}

/** The format a design system file declares. */
export const DESIGN_FORMAT = "cmux.design/1"
/** The cmux color roles, in the order a viewer lists them. */
export const COLOR_ROLES: readonly ColorRole[] = ["primary", "secondary", "tertiary", "accent", "success", "warning", "danger", "separator"]
const WEIGHTS: readonly DesignWeight[] = ["regular", "medium", "semibold", "bold"]
/** Type roles a system may have in all. */
const MAX_ROLES = 12

function system(name: string, type: Record<string, DesignType>, space: readonly number[], colors: Record<string, ColorRole>, limits: DesignSystem["limits"]): DesignSystem {
  return {
    name,
    type,
    space,
    colors,
    limits,
    text(role, text, options = {}) {
      const style = type[role]
      if (!style) throw new Error(`cmux design: no type role ${JSON.stringify(role)} in ${name}; use one of ${Object.keys(type).join(", ")}, or add it under "type" in cmux-design.json`)
      const view = Text(text).font(style.size).weight(style.weight).lineLimit(options.lines ?? 1)
      return style.monospaced ? view.monospaced() : view
    },
    color(color) {
      const role = colors[color]
      if (!role) throw new Error(`cmux design: no color ${JSON.stringify(color)} in ${name}; use one of ${Object.keys(colors).join(", ")}, or name it under "colors" in cmux-design.json`)
      return role
    },
  }
}

function cmuxSystem(): DesignSystem {
  return system(
    "cmux",
    Object.fromEntries(Object.entries(TYPE_ROLES).map(([role, { size, weight }]) => [role, { size, weight }])),
    Object.values(SPACE),
    Object.fromEntries(COLOR_ROLES.map((role) => [role, role])) as Record<ColorRole, ColorRole>,
    { typeRoles: 4, accents: 2 }
  )
}

/** cmux's own design system: `TYPE_ROLES`, `SPACE`, the color roles themselves, 4 type roles and 2 accents a view. */
// A pure call with no arguments: a bundle that never names cmuxDesign drops it and all of this file.
export const cmuxDesign: DesignSystem = /* @__PURE__ */ cmuxSystem()

const isNumber = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n)
// A declaration, not an arrow: a call to it then narrows what follows (`size` is a number after it).
function fail(message: string): never {
  throw new Error(`cmux-design.json: ${message}`)
}

/**
 * A person's system (`cmux.design/1`) merged over cmux's. An entry that does not hold throws an
 * error naming the field and the fix, the same rule `cmux ext dev` checks the file with.
 */
export function defineDesign(spec: DesignSpec): DesignSystem {
  if (!spec || typeof spec !== "object" || Array.isArray(spec)) fail("the file is not a JSON object")
  if (spec.design !== DESIGN_FORMAT) fail(`"design" must be "${DESIGN_FORMAT}"`)
  if (spec.name !== undefined && typeof spec.name !== "string") fail(`"name" must be a string`)
  const type: Record<string, DesignType> = { ...cmuxDesign.type }
  if (spec.type !== undefined) {
    if (!spec.type || typeof spec.type !== "object" || Array.isArray(spec.type)) fail(`"type" must be an object of roles`)
    for (const [role, entry] of Object.entries(spec.type)) {
      const size = (entry as { size?: unknown } | null)?.size
      if (!isNumber(size) || size < 9 || size > 64) fail(`type.${role}.size must be a number of points, 9 to 64`)
      const weight = entry.weight ?? "regular"
      if (!WEIGHTS.includes(weight as DesignWeight)) fail(`type.${role}.weight must be one of ${WEIGHTS.join(", ")}`)
      if (entry.monospaced !== undefined && typeof entry.monospaced !== "boolean") fail(`type.${role}.monospaced must be true or false`)
      const style: DesignType = entry.monospaced ? { size, weight: weight as DesignWeight, monospaced: true } : { size, weight: weight as DesignWeight }
      // defineProperty, not assignment: a role named "__proto__" stays a role, as `cmux ext dev` reads it.
      Object.defineProperty(type, role, { value: style, enumerable: true, writable: true, configurable: true })
    }
    const count = Object.keys(type).length
    if (count > MAX_ROLES) fail(`${count} type roles in all; a system has ${MAX_ROLES} at most`)
  }
  let space = cmuxDesign.space
  if (spec.space !== undefined) {
    if (!Array.isArray(spec.space)) fail(`"space" must be a list of points`)
    if (!spec.space.every((n) => isNumber(n) && n >= 0 && n <= 64)) fail("space steps must be numbers of points, 0 to 64")
    const ascending = spec.space.every((n, i) => i === 0 || spec.space![i - 1]! < n)
    if (spec.space[0] !== 0 || !ascending || spec.space.length < 2 || spec.space.length > 16) fail(`"space" must start at 0 and go up, 2 to 16 steps`)
    space = [...spec.space]
  }
  const colors: Record<string, ColorRole> = { ...cmuxDesign.colors }
  if (spec.colors !== undefined) {
    if (!spec.colors || typeof spec.colors !== "object" || Array.isArray(spec.colors)) fail(`"colors" must be an object of names`)
    for (const [name, role] of Object.entries(spec.colors)) {
      // Hex is not a role: a raw color does not follow the theme, dark mode or contrast.
      if (!COLOR_ROLES.includes(role as ColorRole)) fail(`colors.${name} must name a cmux color role: ${COLOR_ROLES.join(", ")}`)
      colors[name] = role as ColorRole
    }
  }
  const limits = { ...cmuxDesign.limits }
  if (spec.limits !== undefined) {
    const limit = (key: "typeRoles" | "accents", min: number, max: number) => {
      const n = spec.limits?.[key]
      if (n === undefined) return
      if (!Number.isInteger(n) || n < min || n > max) fail(`limits.${key} must be ${min} to ${max}`)
      limits[key] = n
    }
    limit("typeRoles", 1, 8)
    limit("accents", 1, 4)
  }
  return system(spec.name ?? cmuxDesign.name, type, space, colors, limits)
}

// ---------------------------------------------------------------------------------------------
// The viewer.

/** The step of `system`'s scale nearest `points` (the larger one on a tie, so a gap never vanishes). */
function step(system: DesignSystem, points: number): number {
  let best = system.space[0] ?? 0
  for (const s of system.space) if (Math.abs(s - points) <= Math.abs(best - points)) best = s
  return best
}

const SPECIMEN = "The quick brown fox"

/** How a role differs from cmux's: added, overridden, or cmux's own. */
function typeMark(role: string, style: DesignType): "adds" | "overrides" | null {
  const base = cmuxDesign.type[role]
  if (!base) return "adds"
  return base.size === style.size && base.weight === style.weight && !!base.monospaced === !!style.monospaced ? null : "overrides"
}

function section(system: DesignSystem, title: string, note: string, rows: View[]): View {
  return VStack({ spacing: step(system, 8), alignment: "leading" }, [
    VStack({ spacing: step(system, 2), alignment: "leading" }, [system.text("title", title), system.text("caption", note, { lines: 2 }).color("secondary")]),
    VStack({ spacing: step(system, 12), alignment: "leading" }, rows),
  ])
}

function typeRows(system: DesignSystem): View[] {
  return Object.entries(system.type).map(([role, style]) => {
    const mark = typeMark(role, style)
    const facts = `${style.size} pt ${style.weight}${style.monospaced ? ", monospaced" : ""}`
    return VStack({ spacing: step(system, 2), alignment: "leading" }, [
      HStack({ spacing: step(system, 8) }, [system.text(role, SPECIMEN), system.text(role, "72°"), Spacer()]),
      HStack({ spacing: step(system, 8) }, [
        system.text("label", role),
        system.text("caption", facts).color("secondary"),
        mark ? Badge(mark, mark === "adds" ? "success" : "accent") : null,
        Spacer(),
      ]),
    ])
  })
}

function spaceRows(system: DesignSystem): View[] {
  return system.space.map((points) =>
    HStack({ spacing: step(system, 8) }, [
      system.text("caption", `${points}`).monospaced().frame({ width: 28, alignment: "trailing" }),
      VStack([]).frame({ width: Math.max(points * 4, 1), height: 8 }).background("accent").cornerRadius(2),
      Spacer(),
    ])
  )
}

function colorRows(system: DesignSystem): View[] {
  return Object.entries(system.colors).map(([name, role]) =>
    HStack({ spacing: step(system, 8) }, [
      VStack([]).frame({ width: 20, height: 20 }).background(role).cornerRadius(5).borderColor("separator").borderWidth(1),
      system.text("label", name),
      name === role ? null : system.text("caption", `→ ${role}`).color("secondary"),
      name === role ? null : Badge("alias", "accent"),
      Spacer(),
    ])
  )
}

/** The widget helpers' examples, drawn in the system's own roles and on its own scale. */
function componentRows(system: DesignSystem): View[] {
  const [on, setOn] = signal(true)
  const rows = [
    { title: "Design review", detail: "Today, 2:00", trailing: "30 min", tint: "accent" },
    { title: "Ship the tokens", detail: "Due Friday", trailing: "3 left", tint: "success" },
    { title: "Read the RFD", detail: "Optional", trailing: "12 min", tint: "warning" },
  ]
  const example = (label: string, view: View) =>
    VStack({ spacing: step(system, 4), alignment: "leading" }, [system.text("caption", label).color("tertiary"), view])
  return [
    example(
      "Stat: BigNumber and Caption",
      VStack({ spacing: step(system, 2), alignment: "leading" }, [
        system.text("numeral", "72°").contentTransition("numericText"),
        system.text("caption", "Lisbon, clear").color("secondary"),
      ])
    ),
    example(
      "RowList of 3",
      VStack(
        { spacing: step(system, 6), alignment: "leading" },
        rows.map((row) =>
          HStack({ spacing: step(system, 8) }, [
            VStack([]).frame({ width: 3, minHeight: 28 }).background(row.tint).cornerRadius(1.5),
            VStack({ spacing: step(system, 2), alignment: "leading" }, [
              system.text("label", row.title),
              system.text("caption", row.detail).color("secondary"),
            ]),
            Spacer(),
            system.text("caption", row.trailing).color("secondary"),
          ])
        )
      )
    ),
    example(
      "Gauge",
      VStack({ spacing: step(system, 2), alignment: "leading" }, [ProgressView(0.62), system.text("caption", "62% charged").color("secondary")])
    ),
    example(
      "WidgetEmpty",
      VStack({ spacing: step(system, 4), alignment: "leading" }, [
        Icon("checkmark.circle").size(18).color("secondary"),
        system.text("label", "Nothing due"),
        system.text("caption", "Add a task to see it here").color("secondary"),
      ])
    ),
    example("Badge, Button and Toggle", HStack({ spacing: step(system, 12) }, [Badge("3 new", "accent"), Button("Open"), Toggle(on, { label: "Notify", onChange: setOn }), Spacer()])),
  ]
}

/**
 * A page that shows a design system: its name, each type role as a specimen with its size and
 * weight (the roles it overrides or adds marked), the spacing scale as bars, each color name and
 * the cmux role it stands for, the widget components drawn with it, and its limits. It is drawn
 * with the system it shows, so it passes the design check for it.
 *
 *     export const renderPane = pane(() => DesignSystemView(defineDesign(spec)))
 */
export function DesignSystemView(system: DesignSystem = cmuxDesign): View {
  const own = system === cmuxDesign
  const added = Object.entries(system.type).filter(([role, style]) => typeMark(role, style) === "adds").length
  const changed = Object.entries(system.type).filter(([role, style]) => typeMark(role, style) === "overrides").length
  const scaleNote = system.space.join(" ") === cmuxDesign.space.join(" ") ? "cmux's scale, in points" : "Replaces cmux's scale, in points"
  return VStack({ spacing: step(system, 24), alignment: "leading" }, [
    VStack({ spacing: step(system, 4), alignment: "leading" }, [
      system.text("heading", system.name),
      system.text("caption", own ? "cmux's own design system" : "Built on cmux").color("secondary"),
    ]),
    section(system, "Type", own ? "Each role, at its size and weight" : `${changed} overridden, ${added} added; the rest are cmux's`, typeRows(system)),
    Divider(),
    section(system, "Spacing", scaleNote, spaceRows(system)),
    Divider(),
    section(system, "Color", "Each name and the cmux role it draws as, so light, dark and contrast hold", colorRows(system)),
    Divider(),
    section(system, "Components", "The widget helpers, drawn with this system", componentRows(system)),
    Divider(),
    section(system, "Limits", "What one view may use before the design check warns", [
      HStack({ spacing: step(system, 8) }, [system.text("label", "Type roles"), Spacer(), system.text("body", `${system.limits.typeRoles}`)]),
      HStack({ spacing: step(system, 8) }, [system.text("label", "Accent colors"), Spacer(), system.text("body", `${system.limits.accents}`)]),
    ]),
  ])
    .padding(step(system, 16))
    .frame({ maxWidth: "infinity", alignment: "leading" })
}
