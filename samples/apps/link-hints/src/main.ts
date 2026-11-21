/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Link hints: label every link of the focused browser tab (`page.hints show`), pick one by its
// label, and follow it (`page.follow`) in the same tab or a new split. The commands "Link hints"
// and "Link hints: open in new split" (palette, CLI, MCP) show the labels; the sidebar section
// is the picker: type a label (it follows as soon as the label is complete) or click a row.
// Escape or Cancel removes the labels (`page.hints clear`).

type Hint = CmuxPageHint

const [hints, setHints] = signal<Hint[] | null>(null)
const [newSplit, setNewSplit] = signal(false)
const [typed, setTyped] = signal("")
const [error, setError] = signal<string | null>(null)
// The tab the labels were drawn on: follow and clear go to it even if focus moved since.
let hintedTab: string | undefined

const message = (e: unknown) => (e instanceof Error ? e.message : String(e))
const norm = (s: string) => s.trim().toLowerCase()
const onTab = () => (hintedTab ? { tab: hintedTab } : {})

/** Command `link_hints.show`: label the links of the focused browser tab. */
export async function show(args: { new_split?: boolean } = {}, ctx?: CmuxCommandContext) {
  const api = ctx?.cmux ?? cmux
  try {
    const r = await api.page.hints({ action: "show" })
    hintedTab = r.tab
    setHints(r.hints)
    setNewSplit(args.new_split === true)
    setTyped("")
    setError(r.hints.length === 0 ? "No links on this page" : null)
    return { hints: r.hints, new_split: args.new_split === true }
  } catch (e) {
    setHints(null)
    setError(message(e))
    throw e
  }
}

/** Command `link_hints.show_split`: the same labels; the chosen link opens in a new split. */
export async function showSplit(_args: Record<string, never> = {}, ctx?: CmuxCommandContext) {
  return show({ new_split: true }, ctx)
}

/** Command `link_hints.follow`: follow the link labeled `label`. */
export async function follow(args: { label?: string; new_split?: boolean } = {}, ctx?: CmuxCommandContext) {
  const typedLabel = String(args.label ?? "").trim()
  if (!typedLabel) throw new Error("label is empty")
  // Send the label as the page drew it; labels are matched without regard to case.
  const label = (hints() ?? []).find((h) => h.label.toLowerCase() === typedLabel.toLowerCase())?.label ?? typedLabel
  const api = ctx?.cmux ?? cmux
  const r = await api.page.follow({ ...onTab(), label, new_split: args.new_split ?? newSplit() })
  hintedTab = undefined
  setHints(null)
  setTyped("")
  setError(r.followed ? null : `No link labeled ${label}`)
  return r
}

/** Command `link_hints.clear`: remove the labels from the page. */
export async function clear(_args: Record<string, never> = {}, ctx?: CmuxCommandContext) {
  const api = ctx?.cmux ?? cmux
  const tab = onTab()
  hintedTab = undefined
  setHints(null)
  setTyped("")
  setError(null)
  await api.page.hints({ ...tab, action: "clear" })
  return { cleared: true }
}

/** The hints whose label starts with what was typed. */
const matching = () => {
  const t = norm(typed())
  return (hints() ?? []).filter((h) => h.label.toLowerCase().startsWith(t))
}

// Section handlers call the op before any await, so the click's or key's gesture goes with it.
const pick = (label: string) => follow({ label }).catch((e) => setError(message(e)))
const cancel = () => clear().catch((e) => setError(message(e)))

function onEdit(text: string) {
  setTyped(text)
  const t = norm(text)
  const all = hints() ?? []
  // Follow as soon as the label is complete: one label equals it and no longer label starts with it.
  const exact = all.find((h) => h.label.toLowerCase() === t)
  if (exact && !all.some((h) => h !== exact && h.label.toLowerCase().startsWith(t))) pick(exact.label)
}

function onSubmit(text: string) {
  const t = norm(text)
  const exact = (hints() ?? []).find((h) => h.label.toLowerCase() === t)
  const only = matching().length === 1 ? matching()[0] : undefined
  const hit = exact ?? only
  if (hit) pick(hit.label)
  else setError(`No link labeled ${text.trim()}`)
}

function picker() {
  return VStack({ spacing: 6 }, [
    Text(() => (newSplit() ? "Type a label to open it in a new split" : "Type a label to follow it")).font("callout").secondary(),
    TextField(typed, { placeholder: "Label", autofocus: true, onEdit, onSubmit, onCancel: cancel }),
    () => (error() ? Text(error()!).font("caption").color("danger") : null),
    ForEach({ items: matching, key: (h) => h.label }, (h) =>
      Row({ title: () => h().text || h().href || h().label, subtitle: () => h().href, badge: () => h().label, symbol: "link" })
        .help(() => h().href ?? h().text)
        .onTap(() => pick(h().label))
    ),
    HStack([Spacer(), Button("Cancel", cancel).help("Escape")])
  ])
}

function idle() {
  return VStack({ spacing: 6 }, [
    () => (error() ? EmptyState({ title: "No link hints", message: error()!, symbol: "exclamationmark.triangle" }) : null),
    HStack({ spacing: 8 }, [
      Button("Show link hints", () => show().catch(() => {})),
      Button("Open in new split", () => showSplit().catch(() => {})),
      Spacer()
    ])
  ])
}

/** `cmux.section/1`: the picker while labels are on the page, else the two buttons. */
export function renderHints() {
  // A new picker each time labels appear, so its field takes focus.
  return VStack({ spacing: 0 }, [() => (hints() && hints()!.length > 0 ? picker() : idle())])
}
