/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Priority View, as an app: every agent chat on every machine, the ones that need you first,
// built only from public primitives (cmux.live, the scene DSL, a tap gesture). The Mac ranks the
// chats (`chat.list`, the native Priority view's order); this app only draws them.
// Spec: plans/cmux-next/extensibility-DESIGN.md, "First example: Priority View".

type ChatState = "needs_you" | "done" | "failed" | "lost" | "ci_failing" | "working" | "idle"
type Chat = {
  id: string
  title: string
  project: string | null
  machine: string | null
  state: ChatState
  unread: boolean
  pinned: boolean
}

const STYLE: Record<ChatState, { title: string; symbol: string; tone: string }> = {
  needs_you: { title: "Needs you", symbol: "exclamationmark.bubble", tone: "warning" },
  done: { title: "Finished", symbol: "checkmark.circle", tone: "success" },
  failed: { title: "Failed", symbol: "xmark.octagon", tone: "danger" },
  lost: { title: "Lost", symbol: "bolt.slash", tone: "danger" },
  ci_failing: { title: "Red CI", symbol: "xmark.circle", tone: "danger" },
  working: { title: "Working", symbol: "circle.dotted", tone: "accent" },
  idle: { title: "Idle", symbol: "moon", tone: "secondary" }
}

/** The chats to draw: the Mac's order, idle ones hidden unless pinned or `showIdle` is on. */
export function visible(chats: Chat[], showIdle: boolean): Chat[] {
  return chats.filter((c) => showIdle || c.pinned || c.state !== "idle")
}

const subtitle = (c: Chat) => [STYLE[c.state]?.title ?? c.state, c.project ?? c.machine].filter(Boolean).join(" · ")

export function renderPriority() {
  // One live read; it re-reads only on chat.changed (no timer), and the keyed ForEach sends an
  // `update` op only for the row whose props changed.
  const list = cmux.live<{ chats: Chat[] }>("chat.list", {})
  const rows = computed(() => visible(list()?.chats ?? [], cmux.app.settings().showIdle === true))
  const style = (c: Chat) => STYLE[c.state] ?? STYLE.idle
  return VStack({ spacing: 2 }, [
    ForEach({ items: rows, key: (c) => c.id }, (c) =>
      Row({
        title: () => c().title,
        subtitle: () => subtitle(c()),
        symbol: () => style(c()).symbol,
        tint: () => style(c()).tone,
        unread: () => c().unread
      })
    ),
    () => (list.loading() || rows().length ? null : EmptyState({ title: "Nothing needs you", symbol: "bell" }))
  ])
}
