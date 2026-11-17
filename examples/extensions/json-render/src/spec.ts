// A json-render spec (github.com/vercel-labs/json-render, its format only, not the library) drawn
// with cmux's own kit. An agent writes {root, elements, state}; check() (check.ts) refuses anything
// outside catalog.json, and draw() maps each element to a kit view, so the app's renderers (AppKit
// and web) draw it like any extension. Supported: $state, $bindState, $item, $bindItem, $index,
// $cond/$then/$else, $template, visible ($state/$item/$index with eq/neq/gt/gte/lt/lte/not,
// $and/$or), repeat {statePath, key}, and the setState, pushState and removeState actions.

import {
  Badge, Button, computed, Divider, EmptyState, ForEach, HStack, Panel, ProgressView, Row, signal, Spacer, Text,
  TextField, Toggle, VStack, type View
} from "cmux-extension-sdk"
import { check, isObj, type Spec } from "./check.ts"

// JSON Pointer (RFC 6901) reads and immutable writes.
const parts = (pointer: string) => pointer.split("/").slice(1).map((p) => p.replace(/~1/g, "/").replace(/~0/g, "~"))
export function getAt(root: unknown, pointer: string): unknown {
  let at: unknown = root
  for (const p of parts(pointer)) at = isObj(at) || Array.isArray(at) ? (at as Record<string, unknown>)[p] : undefined
  return at
}
export function setAt(root: unknown, pointer: string, value: unknown): unknown {
  const [head, ...rest] = parts(pointer)
  if (head === undefined) return value
  const tail = rest.length ? "/" + rest.join("/") : ""
  if (Array.isArray(root)) {
    const copy = root.slice()
    copy[Number(head)] = tail ? setAt(copy[Number(head)], tail, value) : value
    return copy
  }
  const obj = isObj(root) ? root : {}
  return { ...obj, [head]: tail ? setAt(obj[head], tail, value) : value }
}

/** One spec's live state: a signal over the whole document, saved through `save` on each change. */
export function createState(initial: Record<string, unknown>, save?: (state: unknown) => void) {
  const [state, setState] = signal<unknown>(initial)
  return {
    state,
    get: (pointer: string) => getAt(state(), pointer),
    set: (pointer: string, value: unknown) => {
      const next = setAt(state(), pointer, value)
      setState(next)
      save?.(next)
    }
  }
}
type State = ReturnType<typeof createState>

// Inside a repeat, where the current item is now: read live, so a row keeps pointing at its own
// item after an earlier one is removed.
interface Scope { at?: () => { path: string; index: number } }
const itemPath = (scope: Scope, field: string) => (scope.at ? `${scope.at().path}/${field}` : `/__none/${field}`)

let nextId = 0
const newId = () => `${Date.now().toString(36)}-${(nextId++).toString(36)}`

function evaluate(cond: unknown, s: State, scope: Scope): boolean {
  if (cond === undefined) return true
  if (typeof cond === "boolean") return cond
  if (Array.isArray(cond)) return cond.every((c) => evaluate(c, s, scope))
  if (!isObj(cond)) return false
  if (Array.isArray(cond.$and)) return cond.$and.every((c) => evaluate(c, s, scope))
  if (Array.isArray(cond.$or)) return cond.$or.some((c) => evaluate(c, s, scope))
  const left = "$state" in cond ? s.get(String(cond.$state))
    : "$item" in cond ? s.get(itemPath(scope, String(cond.$item)))
    : "$index" in cond ? scope.at?.().index : undefined
  const right = (v: unknown) => (isObj(v) && "$state" in v ? s.get(String(v.$state)) : v)
  let out = !!left
  if ("eq" in cond) out = left === right(cond.eq)
  else if ("neq" in cond) out = left !== right(cond.neq)
  else if ("gt" in cond) out = Number(left) > Number(right(cond.gt))
  else if ("gte" in cond) out = Number(left) >= Number(right(cond.gte))
  else if ("lt" in cond) out = Number(left) < Number(right(cond.lt))
  else if ("lte" in cond) out = Number(left) <= Number(right(cond.lte))
  return cond.not === true ? !out : out
}

/** A prop's value now: expressions read state (and the repeat item); anything else is itself. */
function resolve(v: unknown, s: State, scope: Scope): unknown {
  if (Array.isArray(v)) return v.map((x) => resolve(x, s, scope))
  if (!isObj(v)) return v === "$id" ? newId() : v
  if ("$state" in v) return s.get(String(v.$state))
  if ("$bindState" in v) return s.get(String(v.$bindState))
  if ("$item" in v) return s.get(itemPath(scope, String(v.$item)))
  if ("$bindItem" in v) return s.get(itemPath(scope, String(v.$bindItem)))
  if ("$index" in v) return scope.at?.().index
  if ("$cond" in v) return resolve(evaluate(v.$cond, s, scope) ? v.$then : v.$else, s, scope)
  if ("$template" in v) return String(v.$template).replace(/\$\{([^}]+)\}/g, (_, p: string) => String(s.get(p) ?? ""))
  return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, resolve(x, s, scope)]))
}

/** Where a two-way prop writes, or null when it is not bound. */
function bound(v: unknown, scope: Scope): string | null {
  if (!isObj(v)) return null
  if ("$bindState" in v) return String(v.$bindState)
  if ("$bindItem" in v && scope.at) return itemPath(scope, String(v.$bindItem))
  return null
}

function run(binding: { action: string; params?: Record<string, unknown> } | undefined, s: State, scope: Scope) {
  if (!binding) return
  const p = (resolve(binding.params ?? {}, s, scope) ?? {}) as Record<string, unknown>
  const path = String(p.statePath ?? "")
  if (binding.action === "setState") s.set(path, p.value)
  else if (binding.action === "pushState") {
    const list = s.get(path)
    s.set(path, [...(Array.isArray(list) ? list : []), p.value])
    if (typeof p.clearStatePath === "string") s.set(p.clearStatePath, "")
  } else if (binding.action === "removeState") {
    const list = s.get(path)
    if (Array.isArray(list)) s.set(path, list.filter((_, i) => i !== Number(p.index)))
  }
}

/** The kit view for one element. Call only on a spec check() passed. */
export function draw(spec: Spec, key: string, s: State, scope: Scope = {}): View {
  const el = spec.elements[key]
  const props = el.props ?? {}
  const live = (name: string) => () => resolve(props[name], s, scope)
  const str = (name: string) => () => String(live(name)() ?? "")
  const kids = (sc: Scope) => (el.children ?? []).map((c) => draw(spec, c, s, sc))

  let children: Array<View | (() => unknown)>
  if (el.repeat) {
    const path = el.repeat.statePath
    const keyField = el.repeat.key
    const items = computed(() => { const v = s.get(path); return Array.isArray(v) ? v : [] })
    children = [ForEach({ items, key: (item: unknown, i: number) => String(keyField && isObj(item) ? item[keyField] : i) }, (_item, itemKey) => {
      const at = () => {
        const index = items().findIndex((it, i) => String(keyField && isObj(it) ? it[keyField] : i) === itemKey)
        return { path: `${path}/${index}`, index }
      }
      return VStack({ spacing: 2 }, kids({ at }))
    })]
  } else children = kids(scope)

  let view: View
  switch (el.type) {
    case "Panel": view = Panel({ title: props.title == null ? undefined : str("title") }, children); break
    case "Stack": view = (props.direction === "horizontal" ? HStack : VStack)({ spacing: Number(props.spacing ?? 6) }, children); break
    case "Text": {
      const t = Text(str("text"))
      if (props.font) t.font(String(props.font))
      if (props.color) t.color(String(props.color))
      view = t
      break
    }
    case "Row": view = Row({ title: str("title"), subtitle: props.subtitle == null ? undefined : str("subtitle"), symbol: props.symbol == null ? undefined : str("symbol"), tint: props.tint == null ? undefined : str("tint") }); break
    case "Button": view = Button(str("label"), () => run(el.on?.press, s, scope)); break
    case "TextField": {
      const to = bound(props.value, scope)
      view = TextField(str("value"), {
        placeholder: props.placeholder == null ? undefined : String(props.placeholder),
        onEdit: to ? (t) => s.set(to, t) : undefined,
        onSubmit: (t) => { if (to) s.set(to, t); run(el.on?.submit, s, scope) }
      })
      break
    }
    case "Toggle": {
      const to = bound(props.checked, scope)
      view = Toggle(() => !!live("checked")(), { label: props.label == null ? undefined : str("label"), onChange: to ? (on) => s.set(to, on) : undefined })
      break
    }
    case "Badge": view = Badge(str("text"), () => String(live("tone")() ?? "secondary")); break
    case "ProgressView": view = ProgressView(() => Number(live("value")() ?? 0)); break
    case "EmptyState": view = EmptyState({ title: str("title"), message: props.message == null ? undefined : str("message"), symbol: props.symbol == null ? undefined : str("symbol") }); break
    case "Divider": view = Divider(); break
    default: view = Spacer()
  }
  if (el.visible === undefined) return view
  const shown = computed(() => evaluate(el.visible, s, scope))
  return VStack({ spacing: 0 }, [() => (shown() ? view : null)])
}

/** A whole spec, or why it cannot draw. */
export function render(spec: unknown, state: State | null): View {
  const issues = check(spec)
  if (issues.length) return EmptyState({ title: "This widget can't draw", message: issues.slice(0, 3).join("; "), symbol: "exclamationmark.triangle" })
  return draw(spec as Spec, (spec as Spec).root, state ?? createState((spec as Spec).state ?? {}))
}
