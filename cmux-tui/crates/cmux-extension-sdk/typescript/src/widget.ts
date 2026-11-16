// Widgets (`cmux.widget/1`): the place, its context, and glanceable layout helpers tuned to
// Apple's widget type scale and insets, so a good widget is about 30 lines.
//
// The page draws the tile itself (its rounded card, its size on the grid, the edit-mode
// wiggle); a widget draws only what is inside. The helpers are plain views built on the scene
// DSL: use them, mix them with VStack and Text, or ignore them.

import { ForEach, HStack, Icon, ProgressView, Spacer, Text, VStack, type View } from "./index.ts"

/** A widget's size, as Apple's widget families: small is a 1x1 tile, medium 2x1, large 2x2. */
export type WidgetSize = "small" | "medium" | "large"
/** Where the person placed it: the New Tab page's grid or the sidebar. */
export type WidgetPlace = "newtab" | "sidebar"
/** Each size's tiles on the grid, [columns, rows]. */
export const WIDGET_TILES: Readonly<Record<WidgetSize, readonly [number, number]>> = { small: [1, 1], medium: [2, 1], large: [2, 2] }

/**
 * Context a widget render gets. `instance` is stable for the placed tile (keep state that must
 * outlive the extension in `cmux.storage` under it); `settings` are the tile's own. `now()` is the
 * host's clock in Unix milliseconds: a render or effect that reads it redraws on each tick, which
 * the host sends on the minute (or the manifest's `refresh.everySeconds`, at least 60) and only
 * while the tile is shown. A resize remounts the widget at its new size.
 */
export type WidgetContext = {
  surface: "widget"
  place: WidgetPlace
  size: WidgetSize
  instance: string
  settings: Record<string, unknown>
  refresh: { everySeconds: number } | null
  now(): number
  /** True for a preview the Add Widget gallery draws: show sample data, write nothing. */
  preview?: boolean
}

/**
 * A widget (`cmux.widget/1`): a glanceable tile the person places on the New Tab page or in the
 * sidebar. cmux ships none of its own; the person adds yours from Edit Widgets > Add Widget.
 *
 *     // cmux-app.json: "implements": { "cmux.widget/1": { "export": "renderClock", "title": "Clock",
 *     //   "symbol": "clock", "options": { "sizes": ["small", "medium"], "refresh": { "everySeconds": 60 } } } }
 *     export const renderClock = widget((ctx) =>
 *       WidgetFrame([WidgetTitle("Clock", { symbol: "clock" }), Spacer(), BigNumber(() => hhmm(ctx.now()))]))
 */
export function widget(render: (context: WidgetContext) => View): (context: WidgetContext) => View {
  return render
}

/** Picks the view for the tile's size: `medium` falls back to `small`, `large` to `medium` then `small`. */
export function bySize(context: Pick<WidgetContext, "size">, views: { small: () => View; medium?: () => View; large?: () => View }): View {
  if (context.size === "large") return (views.large ?? views.medium ?? views.small)()
  if (context.size === "medium") return (views.medium ?? views.small)()
  return views.small()
}

/** The type scale, in points (Apple's widget text styles). */
export const WIDGET_TYPE = { bigNumber: 34, title: 15, label: 13, body: 13, caption: 12, footnote: 11 } as const
/** The tile's inset on each side, in points (Apple's standard widget margin), and the sidebar's tighter one. */
export const WIDGET_INSET = { newtab: 16, sidebar: 12 } as const

/**
 * The widget's content frame: a leading-aligned column filling the tile, inset 16 points (12 in
 * the sidebar when `place` is given). Put a `Spacer()` in it to push content to the bottom, as
 * Apple's widgets do with their big number.
 */
export function WidgetFrame(
  children: Array<View | null | undefined | false>,
  options: { place?: WidgetPlace; spacing?: number; background?: string } = {}
): View {
  const inset = options.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab
  const frame = VStack({ spacing: options.spacing ?? 4, alignment: "leading" }, children)
    .padding(inset)
    .frame({ maxWidth: "infinity", maxHeight: "infinity" })
  return options.background ? frame.background(options.background) : frame
}

/** The tile's header: an optional symbol and a short name, tinted (Apple's widget heading). */
export function WidgetTitle(text: string | (() => string), options: { symbol?: string; tint?: string } = {}): View {
  const tint = options.tint ?? "accent"
  const label = Text(text).font(WIDGET_TYPE.label).weight("semibold").color(tint).lineLimit(1)
  if (!options.symbol) return label
  return HStack({ spacing: 4 }, [Icon(options.symbol).size(WIDGET_TYPE.label).color(tint), label])
}

/** The glanceable value: a large, semibold, single-line number or word (a time, a temperature, a count). Its
 * digits roll when it changes (Apple's numeric content transition; a crossfade under Reduce Motion). */
export function BigNumber(text: string | number | (() => string | number), options: { size?: number; tint?: string } = {}): View {
  const view = Text(text).font(options.size ?? WIDGET_TYPE.bigNumber).weight("semibold").lineLimit(1).contentTransition("numericText")
  return options.tint ? view.color(options.tint) : view
}

/** A line of emphasis under or over the big number. */
export function Headline(text: string | (() => string)): View {
  return Text(text).font(WIDGET_TYPE.title).weight("semibold").lineLimit(1)
}

/** Secondary text: a date, a place, a condition. */
export function Caption(text: string | (() => string)): View {
  return Text(text).font(WIDGET_TYPE.caption).color("secondary").lineLimit(1)
}

/** The quietest text: an updated time, a source. */
export function Footnote(text: string | (() => string)): View {
  return Text(text).font(WIDGET_TYPE.footnote).color("tertiary").lineLimit(1)
}

/** A symbol at a widget size (SF Symbols names; cmux maps them to its own set). */
export function WidgetSymbol(name: string | (() => string), options: { size?: number; tint?: string } = {}): View {
  return Icon(name).size(options.size ?? 20).color(options.tint ?? "primary")
}

/** A gauge: a 0 to 1 bar with an optional caption beside it (a battery, a progress, a ring's value). */
export function Gauge(value: number | (() => number), options: { label?: string | (() => string); tint?: string } = {}): View {
  const bar = ProgressView(value)
  const tinted = options.tint ? bar.color(options.tint) : bar
  if (options.label === undefined) return tinted
  return VStack({ spacing: 2, alignment: "leading" }, [tinted, Caption(options.label)])
}

/** One row of a widget list: a tinted bar (as Apple's Calendar widget marks an event), a title and a detail.
 * `done` strikes the title through and dims it (a checked reminder). */
export type ListItem = { id: string; title: string; detail?: string; trailing?: string; tint?: string; symbol?: string; done?: boolean; onTap?: () => unknown }

/**
 * A compact list for medium and large tiles: at most `max` rows (Apple's widgets show 2 to 4 in a
 * medium, 6 to 8 in a large), each a title, an optional detail under it and a trailing value.
 * Rows slide in and out as the list changes; the host animates it.
 */
export function RowList(items: () => readonly ListItem[], options: { max?: number; spacing?: number } = {}): View {
  const max = options.max ?? 4
  return VStack({ spacing: options.spacing ?? 6, alignment: "leading" }, [
    ForEach({ items: () => (items() ?? []).slice(0, max), key: (item) => item.id }, (item) => {
      const leading = item().symbol
        ? Icon(() => item().symbol ?? "").size(WIDGET_TYPE.label).color(() => item().tint ?? "accent")
        : VStack([]).frame({ width: 3, minHeight: 28 }).background(() => item().tint ?? "accent").cornerRadius(1.5)
      const row = HStack({ spacing: 8 }, [
        leading,
        VStack({ spacing: 1, alignment: "leading" }, [
          Text(() => item().title)
            .font(WIDGET_TYPE.body)
            .weight("semibold")
            .lineLimit(1)
            .strikethrough(() => item().done === true)
            .color(() => (item().done ? "secondary" : "primary"))
            .animation("smooth"),
          () => (item().detail ? Caption(() => item().detail ?? "") : null),
        ]),
        Spacer(),
        () => (item().trailing ? Text(() => item().trailing ?? "").font(WIDGET_TYPE.caption).color("secondary") : null),
      ])
      // Rows slide in when added and out when removed (a crossfade under Reduce Motion).
      row.transition("slide")
      const tap = item().onTap
      return tap ? row.onTap(tap) : row
    }),
  ])
}

/** What a widget shows before it has data, or when it has none: a symbol, a line and a hint. */
export function WidgetEmpty(title: string, options: { message?: string; symbol?: string } = {}): View {
  return VStack({ spacing: 4, alignment: "leading" }, [
    options.symbol ? WidgetSymbol(options.symbol, { size: 18, tint: "secondary" }) : null,
    Text(title).font(WIDGET_TYPE.body).weight("semibold"),
    options.message ? Caption(options.message) : null,
  ])
}
