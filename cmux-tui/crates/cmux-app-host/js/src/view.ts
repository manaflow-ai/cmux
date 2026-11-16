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

/** A motion token, a spring, or a timed curve. Times in seconds, clamped to [0.05, 10]; damping to [0.3, 1]. */
export type Motion =
  | "move" | "appear" | "disappear" | "fade" | "snappy" | "bouncy"
  | { spring: { response: number; dampingFraction: number } }
  | { duration: number; curve?: "easeOut" | "easeInOut" | "linear" }
export type Offset = { x?: number; y?: number }
export type Glow = { color: string; radius: number; opacity?: number }
export type Gradient = { colors: string[]; angle?: number }
export type Trim = { from?: number; to: number }
export type LoopEffect = "pulse" | "breathe" | "spin" | "float" | "wiggle" | "bounce" | "shimmer"
/** `period` in seconds; `amount` scales the effect's default amplitude. */
export type Loop = { effect: LoopEffect; period?: number; amount?: number }
export type Transition = "fade" | "scale" | "slide" | "pop"
export type ParticlePreset = "confetti" | "sparkles" | "rain" | "snow" | "embers" | "stars"
/** `rate` multiplies a continuous preset's emission (default 1); each increase of `burst` fires one burst. */
export type ParticlesProps = {
  preset: Bindable<ParticlePreset>
  colors?: Bindable<string[] | null>
  rate?: Bindable<number>
  burst?: Bindable<number>
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
  color(v: Bindable<string | null>) { return this.set("color", v) }
  foregroundColor(v: Bindable<string | null>) { return this.set("color", v) }
  secondary() { return this.set("color", "secondary") }
  lineLimit(v: Bindable<number>) { return this.set("lineLimit", v) }
  truncation(v: Bindable<"head" | "middle" | "tail">) { return this.set("truncation", v) }
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
  background(v: Bindable<string | null>) { return this.set("background", v) }
  hoverBackground(v: Bindable<string | null>) { return this.set("hoverBackground", v) }
  cornerRadius(v: Bindable<number>) { return this.set("cornerRadius", v) }
  borderColor(v: Bindable<string | null>) { return this.set("borderColor", v) }
  borderWidth(v: Bindable<number>) { return this.set("borderWidth", v) }
  opacity(v: Bindable<number>) { return this.set("opacity", v) }
  fill(v: Bindable<string | null>) { return this.set("fill", v) }
  stroke(v: Bindable<string | null>) { return this.set("stroke", v) }
  strokeWidth(v: Bindable<number>) { return this.set("strokeWidth", v) }
  size(v: Bindable<number>) { return this.set("size", v) }
  rotation(degrees: Bindable<number>) { return this.set("rotation", degrees) }
  // Motion (ABI.md "Motion"): declared here, run by the host renderer at display rate, never ticked from JS.
  /** Animate this node's animatable props from the value on screen whenever they change; `null` stops. */
  animation(v: Bindable<Motion | null>) { return this.set("animation", v) }
  /** Scale about the node's center (1 = identity). */
  scale(v: Bindable<number>) { return this.set("scale", v) }
  /** Move the drawing by points without changing layout. */
  offset(v: Bindable<Offset>) { return this.set("offset", v) }
  /** Gaussian blur radius in points. */
  blur(v: Bindable<number>) { return this.set("blur", v) }
  /** A colored, zero-offset shadow around the node's shape; `null` removes it. */
  glow(v: Bindable<Glow | null>) { return this.set("glow", v) }
  /** A linear gradient fill (shapes) or background (stacks, panels); angle 0 = left to right, 90 (default) = top to bottom. */
  gradient(v: Bindable<Gradient | null>) { return this.set("gradient", v) }
  /** Draw only this fraction of a stroked shape's outline (a circle starts at 12 o'clock, clockwise). */
  trim(v: Bindable<Trim | null>) { return this.set("trim", v) }
  /** A host-run effect that repeats forever; `null` stops it. */
  loop(v: Bindable<Loop | null>) { return this.set("loop", v) }
  /** How the node enters when created and leaves when removed (kept on screen until its exit ends). */
  transition(v: Bindable<Transition | null>) { return this.set("transition", v) }
  /** Clip the node's content (children, a sliding transition, a glow) to its frame and corner radius. */
  clipped(v: Bindable<boolean> = true) { return this.set("clipped", v) }
  cursor(v: "pointer" | "default") { return this.set("cursor", v) }
  help(v: Bindable<string>) { return this.set("help", v) }
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

export function Text(text: Bindable<string | number | null | undefined>): ViewNode {
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
