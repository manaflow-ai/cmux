// Whether a json-render spec may draw: only catalog.json's parts, props, events and actions, every
// child present, no cycle, within the limits. Pure (no SDK), so the generator runs it too.

import catalog from "../catalog.json"

export interface Element {
  type: string
  props?: Record<string, unknown>
  children?: string[]
  visible?: unknown
  repeat?: { statePath: string; key?: string }
  on?: Record<string, { action: string; params?: Record<string, unknown> }>
}
export interface Spec { root: string; elements: Record<string, Element>; state?: Record<string, unknown> }

type Catalog = {
  components: Record<string, { children?: boolean; events?: string[]; props: Record<string, { type?: string; enum?: string[]; required?: boolean }> }>
  actions: string[]
  limits: { elements: number; depth: number }
}
const CATALOG = catalog as unknown as Catalog

export const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)

/** Every problem with a spec, empty when it draws. A spec with any problem draws nothing. */
export function check(spec: unknown): string[] {
  if (!isObj(spec) || typeof spec.root !== "string" || !isObj(spec.elements)) return ["a spec is {root, elements, state?}"]
  const elements = spec.elements as Record<string, unknown>
  const keys = Object.keys(elements)
  const issues: string[] = []
  if (keys.length > CATALOG.limits.elements) issues.push(`${keys.length} elements, more than ${CATALOG.limits.elements}`)
  if (!(spec.root in elements)) issues.push(`root "${spec.root}" is not an element`)
  for (const key of keys) {
    const el = elements[key]
    if (!isObj(el)) { issues.push(`${key}: not an object`); continue }
    const part = CATALOG.components[String(el.type)]
    if (!part) { issues.push(`${key}: "${String(el.type)}" is not in the catalog`); continue }
    const props = isObj(el.props) ? el.props : {}
    for (const name of Object.keys(props)) if (!(name in part.props)) issues.push(`${key}: ${el.type} has no prop "${name}"`)
    for (const [name, p] of Object.entries(part.props)) {
      const v = props[name]
      if (p.required && v == null) issues.push(`${key}: ${el.type} needs "${name}"`)
      if (p.enum && typeof v === "string" && !p.enum.includes(v)) issues.push(`${key}: ${name} "${v}" is not one of ${p.enum.join(", ")}`)
    }
    const children = el.children ?? []
    if (!Array.isArray(children)) issues.push(`${key}: children is not a list`)
    else {
      if (children.length && !part.children && !el.repeat) issues.push(`${key}: ${el.type} takes no children`)
      for (const c of children) if (!(String(c) in elements)) issues.push(`${key}: child "${String(c)}" is not an element`)
    }
    if (el.repeat !== undefined && !(isObj(el.repeat) && typeof el.repeat.statePath === "string")) issues.push(`${key}: repeat needs a statePath`)
    if (el.on !== undefined) {
      if (!isObj(el.on)) issues.push(`${key}: on is not an object`)
      else for (const [event, b] of Object.entries(el.on)) {
        if (!(part.events ?? []).includes(event)) issues.push(`${key}: ${el.type} has no event "${event}"`)
        if (!isObj(b) || !CATALOG.actions.includes(String(b.action))) issues.push(`${key}: action "${isObj(b) ? String(b.action) : "?"}" is not in the catalog`)
      }
    }
  }
  // Cycles and depth, from the root.
  const walk = (key: string, path: string[]): void => {
    if (path.includes(key)) { issues.push(`${key}: a cycle through ${path.join(" > ")}`); return }
    if (path.length >= CATALOG.limits.depth) { issues.push(`${key}: deeper than ${CATALOG.limits.depth}`); return }
    const el = elements[key]
    if (isObj(el) && Array.isArray(el.children)) for (const c of el.children) if (String(c) in elements) walk(String(c), [...path, key])
  }
  if (!issues.length) walk(spec.root, [])
  return issues
}
