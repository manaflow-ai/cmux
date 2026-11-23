// json-render widgets: an agent describes a widget as a json-render spec made only of
// catalog.json's parts, and cmux draws it with its own kit, on every renderer the kit has.
// - A chat widget (cmux.chat.widget/1): a widget part an agent sends, {type: "widget", app:
//   "local/json-render", props: {spec}, fallback}, draws the spec under the message. "Pin" keeps
//   it as the sidebar widget.
// - A sidebar section (cmux.section/1): the pinned spec, or specs/todo.json, which an agent made
//   from the catalog (generate/generate.ts). Its state (the todos) is kept in cmux.storage, so it
//   survives a reload and a relaunch.

import { Button, chatWidget, cmux, HStack, section, signal, Spacer, Text, VStack, type ChatWidgetContext } from "cmux-extension-sdk"
import todo from "../specs/todo.json"
import { check, isObj, type Spec } from "./check.ts"
import { createState, render } from "./spec.ts"

const PINNED = "pinned"
const stateKey = (id: string) => `state:${id}`

/** A spec's live state, first from storage under `id`, saved back on each change. */
function stored(spec: Spec, id: string) {
  const s = createState(spec.state ?? {}, (next) => cmux.storage.set(stateKey(id), next))
  cmux.storage.get<Record<string, unknown>>(stateKey(id)).then((saved) => { if (isObj(saved)) s.set("", saved) })
  return s
}

export const renderCard = chatWidget((context: ChatWidgetContext) => {
  const spec = (context.props as { spec?: unknown } | undefined)?.spec
  const issues = check(spec)
  const view = render(spec, issues.length ? null : stored(spec as Spec, context.widget.key))
  if (issues.length) return view
  return VStack({ spacing: 4 }, [
    view,
    HStack([Spacer(), Button("Pin to sidebar", () => {
      cmux.storage.set(PINNED, spec)
      setPinned(spec as Spec)
      cmux.toast({ title: "Pinned to the sidebar" })
    })])
  ])
})

const [pinned, setPinned] = signal<Spec | null>(null)
let pinnedLoaded = false

export const renderSection = section(() => {
  if (!pinnedLoaded) {
    pinnedLoaded = true
    cmux.storage.get<Spec>(PINNED).then((saved) => { if (!check(saved).length) setPinned(saved) })
  }
  return VStack([
    () => {
      const spec = pinned() ?? (todo as unknown as Spec)
      return check(spec).length ? Text("No widget yet") : render(spec, stored(spec, pinned() ? PINNED : "todo"))
    }
  ])
})
