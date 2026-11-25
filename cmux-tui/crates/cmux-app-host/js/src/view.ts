// View builders: the authoring API of the old cmux JS sidebars (VStack, Text,
// ForEach, Reorderable, chainable modifiers) plus cmux-native rows. Builders
// only describe; `materialize.ts` turns a description into scene nodes and
// bindings. A prop or child given as a function is a live binding.

import type { Read } from "./reactive.ts"

export type Bindable<T> = T | (() => T)
export type Handler = (...args: never[]) => unknown

export interface ListSpec<T> {
  items: () => readonly T[] | null | undefined
  key: (item: T, index: number) => string | number
  onMove?: (id: string, index: number, extra: { side?: string; block?: boolean }) => unknown
  onDragChange?: (state: unknown) => unknown
  spacing?: number
}

/** A motion scale step (`smooth`, `snappy`, `none`), a motion token, a spring, or a timed curve. Times in
 * seconds, clamped to [0.05, 10]; damping to [0.3, 1]. */
export type Motion =
  | "smooth" | "snappy" | "none"
  | "move" | "appear" | "disappear" | "fade" | "bouncy"
  | { spring: { response: number; dampingFraction: number } }
  | { duration: number; curve?: "easeOut" | "easeInOut" | "linear" }
export type Offset = { x?: number; y?: number }
export type Glow = { color: string; radius: number; opacity?: number }
/** The `gradient` modifier (angle 0 = left to right, 90 = top to bottom); a gradient `fill` or `background` is `SceneGradient`. */
export type LinearGradient = { colors: string[]; angle?: number }
export type Trim = { from?: number; to: number }
export type LoopEffect = "pulse" | "breathe" | "spin" | "float" | "wiggle" | "bounce" | "shimmer"
/** `period` in seconds; `amount` scales the effect's default amplitude. */
export type Loop = { effect: LoopEffect; period?: number; amount?: number }
export type Transition = "opacity" | "slide" | "scale" | "move" | "pop"
/** A transition on its own timing: `motion` times the move and the fade, in and out. Without one the
 * renderer's own springs time it, as the bare kind does. */
export type TimedTransition = { kind: Transition; motion?: Motion | null }
export type ParticlePreset = "confetti" | "sparkles" | "rain" | "snow" | "embers" | "stars"
/** A `cmux.particles/1` document (ABI.md "Particles choreography"); the host validates it. */
export type ParticleChoreography = { $schema: "cmux.particles/1" } & Record<string, unknown>
/** `rate` multiplies a continuous preset's emission (default 1); each increase of `burst` fires one burst.
 * With `choreography` the node plays that glyph instead: `trigger` (an acpmux kind) picks its phases,
 * `phase` loops one phase, `size` and `colors[0]` override the document's particle. */
export type ParticlesProps = {
  preset?: Bindable<ParticlePreset>
  colors?: Bindable<string[] | null>
  rate?: Bindable<number>
  burst?: Bindable<number>
  choreography?: Bindable<ParticleChoreography | null>
  trigger?: Bindable<string | null>
  phase?: Bindable<string | null>
  size?: Bindable<number>
}

export class ViewNode {
  readonly props: Record<string, unknown> = {}
  readonly handlers: Record<string, Handler> = {}
  menu: ViewNode[] | (() => ViewNode[]) | null = null

  constructor(
    readonly type: string,
    readonly children: Array<ViewNode | (() => unknown)> = [],
    readonly list: { spec: ListSpec<unknown>; template: (item: Read<unknown>, key: string) => ViewNode } | null = null
  ) {}

  withProps(props: Record<string, unknown>): this {
    Object.assign(this.props, props)
    return this
  }

  private set(key: string, value: unknown): this {
    this.props[key] = value
    return this
  }

  // Text and font
  font(v: Bindable<string | number>) { return this.set("font", v) }
  weight(v: Bindable<string>) { return this.set("weight", v) }
  bold() { return this.set("weight", "bold") }
  italic() { return this.set("italic", true) }
  monospaced() { return this.set("monospaced", true) }
  /** The system font's design at the same type-scale size: `rounded` (heavy and rounded is the
   * Lock Screen's time), `serif`, `monospaced` or `default`. */
  fontDesign(v: Bindable<"default" | "rounded" | "serif" | "monospaced">) { return this.set("fontDesign", v) }
  color(v: Bindable<string | null>) { return this.set("color", v) }
  foregroundColor(v: Bindable<string | null>) { return this.set("color", v) }
  secondary() { return this.set("color", "secondary") }
  lineLimit(v: Bindable<number>) { return this.set("lineLimit", v) }
  truncation(v: Bindable<"head" | "middle" | "tail">) { return this.set("truncation", v) }
  /** Draws a line through the text (a done reminder, a struck price). */
  strikethrough(v: Bindable<boolean> = true) { return this.set("strikethrough", v) }
  marquee(delaySeconds = 0.5) { return this.set("marquee", delaySeconds) }
  fade(width: Bindable<number>) { return this.set("fade", width) }
  // Layout
  padding(v: Bindable<number | Record<string, number>> = 8) { return this.set("padding", v) }
  paddingHorizontal(v: Bindable<number>) { return this.set("paddingHorizontal", v) }
  paddingVertical(v: Bindable<number>) { return this.set("paddingVertical", v) }
  frame(v: Bindable<Record<string, number | string>>) { return this.set("frame", v) }
  layoutPriority(v: Bindable<number>) { return this.set("layoutPriority", v) }
  fixedSize(axis: "both" | "horizontal" | "vertical" = "both") { return this.set("fixedSize", axis) }
  // Surface
  /** A color token, `#RRGGBB[AA]`, or a gradient (`linearGradient(...)`, `radialGradient(...)`). */
  background(v: Bindable<SceneFill | null>) { return this.set("background", v) }
  hoverBackground(v: Bindable<string | null>) { return this.set("hoverBackground", v) }
  /** The App's own glass at `level` under the node (paint only; null drops it). Levels: chrome, popover, menu, chip. */
  glass(level: Bindable<"chrome" | "popover" | "menu" | "chip" | null> = "popover") { return this.set("glass", level) }
  cornerRadius(v: Bindable<number>) { return this.set("cornerRadius", v) }
  borderColor(v: Bindable<string | null>) { return this.set("borderColor", v) }
  borderWidth(v: Bindable<number>) { return this.set("borderWidth", v) }
  opacity(v: Bindable<number>) { return this.set("opacity", v) }
  /** A shape's fill: a color token, `#RRGGBB[AA]`, or a gradient. */
  fill(v: Bindable<SceneFill | null>) { return this.set("fill", v) }
  stroke(v: Bindable<string | null>) { return this.set("stroke", v) }
  strokeWidth(v: Bindable<number>) { return this.set("strokeWidth", v) }
  size(v: Bindable<number>) { return this.set("size", v) }
  rotation(degrees: Bindable<number>) { return this.set("rotation", degrees) }
  // Motion (ABI.md "Motion"): declared here, run by the host renderer at display rate, never ticked from JS.
  /** Animates this node's own prop changes from the value on screen: `smooth` (the motion scale's
   * standard step, the default), `snappy` (its micro step) and `none` animate opacity, colors,
   * rotation and strikethrough; a motion token, a spring or a timed curve animates every animatable
   * prop (ABI.md "Motion"), retargeting mid-flight. `null` stops. */
  animation(v: Bindable<Motion | null> = "smooth") { return this.set("animation", v) }
  /** Scale about the node's center (1 = identity). */
  scale(v: Bindable<number>) { return this.set("scale", v) }
  /** Move the drawing by points without changing layout. */
  offset(v: Bindable<Offset>) { return this.set("offset", v) }
  /** Gaussian blur radius in points. */
  blur(v: Bindable<number>) { return this.set("blur", v) }
  /** A colored, zero-offset shadow around the node's shape; `null` removes it. */
  glow(v: Bindable<Glow | null>) { return this.set("glow", v) }
  /** A linear gradient fill (shapes) or background (stacks, panels); angle 0 = left to right, 90 (default) = top to bottom. */
  gradient(v: Bindable<LinearGradient | null>) { return this.set("gradient", v) }
  /** Draw only this fraction of a stroked shape's outline (a circle starts at 12 o'clock, clockwise). */
  trim(v: Bindable<Trim | null>) { return this.set("trim", v) }
  /** A host-run effect that repeats forever; `null` stops it. */
  loop(v: Bindable<Loop | null>) { return this.set("loop", v) }
  /** How the node comes in and goes out when a render adds or removes it (kept on screen until its
   * exit ends): `opacity` fades, `slide` comes up from below and leaves upward, `scale` grows from
   * 90 %, `move` slides in from the leading edge and out to the trailing one, `pop` grows from 60 %
   * past full size and back. A node the first scene draws does not animate in. `{kind, motion}`
   * times it with a motion token, spring or timed curve (a panel matching another app's timing). */
  transition(v: Bindable<Transition | TimedTransition | null>) { return this.set("transition", v) }
  /** Clip the node's content (children, a sliding transition, a glow) to its frame and corner radius. */
  clipped(v: Bindable<boolean> = true) { return this.set("clipped", v) }
  /** SwiftUI's name for `rotation`: turns the node clockwise by `degrees` about its center. A change
   * animates only under `.animation(...)`, behind the motion gate. */
  rotationEffect(degrees: Bindable<number>) { return this.set("rotation", degrees) }
  /** Moves the node's drawing by `{x, y}` points without moving its layout; a rotation turns the
   * moved drawing about the node's center (a clock hand: offset by half its length, then rotated). */
  offset(v: Bindable<{ x?: number; y?: number }>) { return this.set("offset", v) }
  /** In a ZStack: places the node's center at `{x, y}`, in points or, with `unit: "fraction"`, as 0...1
   * of the stack (SwiftUI's `.position`); an axis left out stays centered. A placed child does not size
   * the stack: an hour grid sizes it and the events and now line sit on it. */
  position(v: Bindable<{ x?: number; y?: number; unit?: "points" | "fraction" }>) { return this.set("position", v) }
  cursor(v: "pointer" | "default") { return this.set("cursor", v) }
  help(v: Bindable<string>) { return this.set("help", v) }
  // Motion: the host animates these (the app never runs a timer for them). Reduce Motion and
  // cmux's calm motion turn each movement into a crossfade; motion off draws the end state.
  /** How a Text's new content replaces the old: `numericText` rolls the changed digits (up when
   * the number grows, down when it shrinks), `opacity` crossfades. */
  contentTransition(v: "numericText" | "opacity") { return this.set("contentTransition", v) }
  // Behavior
  fixed() { return this.set("fixed", true) }
  destructive() { return this.set("destructive", true) }
  disabled(v: Bindable<boolean> = true) { return this.set("disabled", v) }
  onTap(fn: () => unknown) {
    this.handlers.tap = fn
    return this
  }
  contextMenu(items: ViewNode[] | (() => ViewNode[])) {
    this.menu = items
    return this
  }
  // Symbols
  /** How an `Icon`'s layers take color, as SF Symbols draw them: `monochrome` (the default: all in
   * `color`), `hierarchical` (the layers in `color` at falling opacity), `palette` (the layers in
   * `colors`, 1 to 3 tokens or `#RRGGBB[AA]`, in order) or `multicolor` (the symbol's own colors,
   * a sun yellow and rain blue, with `color` where it has none). */
  symbolRendering(mode: SymbolRendering, colors?: readonly string[]) {
    if (!SYMBOL_RENDERINGS.includes(mode)) throw new TypeError(`symbolRendering: unknown mode ${JSON.stringify(mode)}`)
    this.set("symbolRendering", mode)
    if (colors === undefined) return this
    if (!Array.isArray(colors) || colors.length < 1 || colors.length > 3 || !colors.every(isSceneColor))
      throw new TypeError(`symbolRendering: colors must be 1 to 3 color tokens or #RRGGBB[AA], got ${JSON.stringify(colors)}`)
    return this.set("symbolColors", [...colors])
  }
}

// Fills: a color, or a gradient value the renderers validate the same way the builders below do.

const SCENE_COLOR_TOKENS: readonly string[] = ["primary", "secondary", "tertiary", "accent", "separator", "success", "warning", "danger", "hover", "selected", "badge", "clear"]
const HEX_COLOR = /^#[\da-f]{6}([\da-f]{2})?$/i
const isSceneColor = (value: unknown): value is string => typeof value === "string" && (SCENE_COLOR_TOKENS.includes(value) || HEX_COLOR.test(value))

/** A gradient for `background` and a shape's `fill`. */
export type SceneGradient = { linear: { colors: string[]; angle?: number } } | { radial: { colors: string[] } }
/** A color token, `#RRGGBB[AA]`, or a gradient. */
export type SceneFill = string | SceneGradient
export type SymbolRendering = "monochrome" | "hierarchical" | "palette" | "multicolor"
const SYMBOL_RENDERINGS: readonly string[] = ["monochrome", "hierarchical", "palette", "multicolor"]

function gradientStops(name: string, colors: readonly string[]): string[] {
  if (!Array.isArray(colors) || colors.length < 2 || colors.length > 8 || !colors.every(isSceneColor))
    throw new TypeError(`${name}: colors must be 2 to 8 color tokens or #RRGGBB[AA], got ${JSON.stringify(colors)}`)
  return [...colors]
}

/** A linear gradient for `.background(...)` or a shape's `.fill(...)`: 2 to 8 stops (tokens or
 * `#RRGGBB[AA]`) spaced evenly along `angle` degrees, the CSS way (0 up, 90 right, 180 down, the default). */
export function linearGradient(colors: readonly string[], angle?: number): SceneGradient {
  const stops = gradientStops("linearGradient", colors)
  if (angle === undefined) return { linear: { colors: stops } }
  if (typeof angle !== "number" || !Number.isFinite(angle)) throw new TypeError("linearGradient: angle must be a finite number of degrees")
  return { linear: { colors: stops, angle } }
}

/** A radial gradient, an ellipse from the center out to the box's edges: 2 to 8 stops (tokens or `#RRGGBB[AA]`). */
export function radialGradient(colors: readonly string[]): SceneGradient {
  return { radial: { colors: gradientStops("radialGradient", colors) } }
}

type Children = Array<ViewNode | (() => unknown) | null | undefined | false>

const clean = (children: Children) => children.filter((c): c is ViewNode | (() => unknown) => !!c)

function container(type: string) {
  return (propsOrChildren?: Record<string, unknown> | Children, maybeChildren?: Children): ViewNode => {
    const hasProps = propsOrChildren !== undefined && !Array.isArray(propsOrChildren)
    const node = new ViewNode(type, clean((hasProps ? maybeChildren : (propsOrChildren as Children)) ?? []))
    if (hasProps) Object.assign(node.props, propsOrChildren)
    return node
  }
}

export const VStack = container("VStack")
export const HStack = container("HStack")
export const ZStack = container("ZStack")
export const LazyVStack = container("LazyVStack")
export const Group = container("Group")

export type DateTextStyle = "time" | "timer" | "relative" | "date" | "offset"

/** A Text the host formats and ticks itself, like SwiftUI's `Text(date, style:)`: no render, no
 * timer and no scene batch per second. `date` is Unix ms. `time` "9:41 AM", `date` "November 16,
 * 2026", `timer` "4:05" (counts down to a future date, up from a past one), `relative` "2 hr, 23
 * min", `offset` "+2 hours". The page's locale and time zone; `timeZone` (an IANA name) overrides
 * the zone (a world clock). */
export interface DateText {
  date: Bindable<number>
  style?: Bindable<DateTextStyle>
  timeZone?: Bindable<string>
}

export function Text(text: Bindable<string | number | null | undefined> | DateText): ViewNode {
  if (text !== null && typeof text === "object") {
    const node = new ViewNode("Text")
    node.props.text = ""
    node.props.date = text.date
    node.props.dateStyle = text.style ?? "time"
    if (text.timeZone !== undefined) node.props.timeZone = text.timeZone
    return node
  }
  const node = new ViewNode("Text")
  node.props.text = typeof text === "function" ? () => String((text as () => unknown)() ?? "") : String(text ?? "")
  return node
}

/** SF Symbol by name (mapped to an equivalent glyph on web and TUI). */
export function Icon(name: Bindable<string>): ViewNode {
  const node = new ViewNode("Icon")
  node.props.symbol = name
  return node
}

/** Image from the app bundle (`assets/x.png`) or an SF Symbol (`{systemName}`). */
export function Image(source: Bindable<string> | { systemName: Bindable<string> }): ViewNode {
  if (typeof source === "object" && source !== null && "systemName" in source) return Icon(source.systemName)
  const node = new ViewNode("Image")
  node.props.src = source
  return node
}

export function Button(label: Bindable<string> | ViewNode, action?: () => unknown): ViewNode {
  const node = label instanceof ViewNode ? new ViewNode("Button", [label]) : new ViewNode("Button")
  if (!(label instanceof ViewNode)) node.props.title = label
  if (action) node.handlers.tap = action
  return node
}

/** A pull-down menu as a view, or a submenu inside `.contextMenu([...])`. */
export function Menu(title: Bindable<string>, items: ViewNode[]): ViewNode {
  const node = new ViewNode("Menu")
  node.props.title = title
  node.menu = items
  return node
}

export const Spacer = () => new ViewNode("Spacer")
export const Divider = () => new ViewNode("Divider")
export const Circle = (props: Record<string, unknown> = {}) => new ViewNode("Circle").withProps(props)
export const Capsule = (props: Record<string, unknown> = {}) => new ViewNode("Capsule").withProps(props)
export const Rectangle = (props: Record<string, unknown> = {}) => new ViewNode("Rectangle").withProps(props)
/** A stroke along its width: `strokeWidth` thick (1 by default) in `stroke` (the separator ink by default). */
export const Line = (props: Record<string, unknown> = {}) => new ViewNode("Line").withProps(props)
export const RoundedRectangle = (props: Record<string, unknown> = {}) => new ViewNode("RoundedRectangle").withProps(props)

/** A particle field that fills its frame and takes no input; first in a ZStack, it draws behind its siblings. */
export function Particles(props: ParticlesProps): ViewNode {
  return new ViewNode("Particles").withProps(props)
}

export function ProgressView(value?: Bindable<number | null>): ViewNode {
  const node = new ViewNode("ProgressView")
  if (value !== undefined) node.props.value = value
  return node
}

export function TextField(
  value: Bindable<string>,
  options: { placeholder?: string; autofocus?: boolean; onSubmit?: (t: string) => unknown; onEdit?: (t: string) => unknown; onCancel?: () => unknown } = {}
): ViewNode {
  const node = new ViewNode("TextField")
  node.props.text = value
  if (options.placeholder) node.props.placeholder = options.placeholder
  node.props.autofocus = options.autofocus ?? false
  if (options.onSubmit) node.handlers.submit = options.onSubmit
  if (options.onEdit) node.handlers.edit = options.onEdit
  if (options.onCancel) node.handlers.cancel = options.onCancel
  return node
}

/** A native switch, two-way bound like TextField: `value` is the state, `onChange` gets the new one. */
export function Toggle(value: Bindable<boolean>, options: { label?: Bindable<string>; disabled?: Bindable<boolean>; onChange?: (on: boolean) => unknown } = {}): ViewNode {
  const node = new ViewNode("Toggle")
  node.props.value = value
  if (options.label !== undefined) node.props.label = options.label
  if (options.disabled !== undefined) node.props.disabled = options.disabled
  if (options.onChange) node.handlers.change = options.onChange as Handler
  return node
}

/** A native slider over `min...max` (default 0...1), snapped to `step`; `onChange` gets the number. */
export function Slider(value: Bindable<number>, options: { min?: number; max?: number; step?: number; disabled?: Bindable<boolean>; onChange?: (v: number) => unknown } = {}): ViewNode {
  const node = new ViewNode("Slider")
  node.props.value = value
  node.props.min = options.min ?? 0
  node.props.max = options.max ?? 1
  if (options.step !== undefined) node.props.step = options.step
  if (options.disabled !== undefined) node.props.disabled = options.disabled
  if (options.onChange) node.handlers.change = options.onChange as Handler
  return node
}

/** The app's own card surface with its padding and radius: `style` `glass` (default, the sidebar card's glass) or `card` (opaque). */
export function Panel(propsOrChildren?: { title?: Bindable<string>; style?: "glass" | "card"; spacing?: number } | Children, maybeChildren?: Children): ViewNode {
  const hasProps = propsOrChildren !== undefined && !Array.isArray(propsOrChildren)
  const node = new ViewNode("Panel", clean((hasProps ? maybeChildren : (propsOrChildren as Children)) ?? []))
  if (hasProps) Object.assign(node.props, propsOrChildren)
  node.props.style ??= "glass"
  return node
}

/** The standard sidebar row: matches built-in rows so app sections look native. */
export function Row(props: {
  title: Bindable<string>
  subtitle?: Bindable<string | null>
  symbol?: Bindable<string | null>
  badge?: Bindable<string | number | null>
  unread?: Bindable<boolean>
  selected?: Bindable<boolean>
  tint?: Bindable<string | null>
  accessory?: Bindable<string | null>
}): ViewNode {
  return new ViewNode("Row").withProps(props)
}

export function Badge(text: Bindable<string | number>, tone: Bindable<string> = "secondary"): ViewNode {
  const node = new ViewNode("Badge")
  node.props.text = typeof text === "function" ? () => String((text as () => unknown)()) : String(text)
  node.props.tone = tone
  return node
}

export function EmptyState(props: { title: Bindable<string>; message?: Bindable<string>; symbol?: Bindable<string> }): ViewNode {
  return new ViewNode("EmptyState").withProps(props)
}

export function ForEach<T>(spec: ListSpec<T>, template: (item: Read<T>, key: string) => ViewNode): ViewNode {
  return new ViewNode("ForEach", [], { spec: spec as ListSpec<unknown>, template: template as (item: Read<unknown>, key: string) => ViewNode })
}

export function Reorderable<T>(spec: ListSpec<T>, template: (item: Read<T>, key: string) => ViewNode): ViewNode {
  const node = new ViewNode("Reorderable", [], { spec: spec as ListSpec<unknown>, template: template as (item: Read<unknown>, key: string) => ViewNode })
  if (spec.spacing !== undefined) node.props.spacing = spec.spacing
  if (spec.onMove) node.handlers.move = spec.onMove as Handler
  if (spec.onDragChange) node.handlers.dragChange = spec.onDragChange as Handler
  return node
}
