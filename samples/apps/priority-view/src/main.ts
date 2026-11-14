/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Priority View, as an app: the chats that need you first, built only from public primitives
// (cmux.live, the scene DSL, a tap gesture). It replaces nothing in the native sidebar; it shows
// what the native `sidebar.priorityView.*` feature looks like as a `cmux.section/1` app, reading
// the same chats (`chat.list`: every ACP chat acpmux knows) in the native ranking's order.
// Spec: plans/cmux-next/extensibility-DESIGN.md, "First example: Priority View" and step 3.

type Chat = Cmux.ChatSummary

type Tier = { title: string; symbol: string; tone: string }

/** The native tiers (AgentPriorityRanking.tier), in order. */
const TIERS: Tier[] = [
  { title: "Needs you", symbol: "exclamationmark.bubble", tone: "warning" },
  { title: "Finished", symbol: "checkmark.circle", tone: "success" },
  { title: "Failed", symbol: "exclamationmark.triangle", tone: "danger" },
  { title: "CI failing", symbol: "xmark.octagon", tone: "danger" },
  { title: "Working", symbol: "circle.dotted", tone: "accent" },
  { title: "Idle", symbol: "moon", tone: "secondary" }
]
const NEEDS_YOU = 0, FINISHED = 1, FAILED = 2, CI_FAILING = 3, WORKING = 4, IDLE = 5

/** An idle chat with nothing unseen leaves the view after this long, unless pinned (as natively). */
const IDLE_HORIZON_MS = 24 * 60 * 60 * 1000

/**
 * A chat's tier, as AgentPriorityRanking.state: its turn's, unless failing checks (`ci_failing`)
 * rank higher. A finished turn nobody has seen (`unread`) is Finished; read, it is idle.
 */
export function tier(c: Chat): number {
  const turn =
    c.state === "input" ? NEEDS_YOU
    : c.state === "working" ? WORKING
    : c.state === "failed" || c.state === "lost" ? FAILED
    : c.unread ? FINISHED
    : IDLE
  return c.ci_failing === true && CI_FAILING < turn ? CI_FAILING : turn
}

const since = (c: Chat) => Number(c.since_ms ?? c.updated_ms ?? 0)

/**
 * Ranks chats: tier first, pinned first within a tier, then the most recent change; idle chats are
 * hidden unless `showIdle`, and idle ones older than a day leave unless pinned. Pure, so a test can
 * call it with a fixed `now`.
 */
export function rank(chats: Chat[], showIdle: boolean, now = Date.now()): Chat[] {
  return chats
    .filter((c) => {
      if (tier(c) !== IDLE || c.pinned) return true
      return showIdle && now - since(c) <= IDLE_HORIZON_MS
    })
    .slice()
    .sort((a, b) =>
      tier(a) - tier(b) ||
      Number(b.pinned) - Number(a.pinned) ||
      since(b) - since(a) ||
      (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
    )
}

const subtitle = (c: Chat) => {
  const t = TIERS[tier(c)]!.title
  const where = [c.project, c.machine].filter(Boolean).join(" · ")
  return where ? `${t} · ${where}` : t
}

/** Shows the chat's workspace; only in answer to a tap (the gesture token). */
async function open(c: Chat) {
  const gesture = cmux.gesture() ?? undefined
  if (c.workspace) await cmux.workspace.focus({ workspace: c.workspace }, { gesture })
  if (c.unread) await cmux.chat.mark_read({ chat: c.id }, { gesture })
}

async function pin(c: Chat) {
  await cmux.chat.pin({ chat: c.id, pinned: !c.pinned }, { gesture: cmux.gesture() ?? undefined })
}

async function markRead(c: Chat) {
  await cmux.chat.mark_read({ chat: c.id }, { gesture: cmux.gesture() ?? undefined })
}

export function renderPriority() {
  // One live read; it re-reads only on chat.changed (no timer), and the keyed ForEach sends
  // an `update` op only for the row whose props changed.
  const chats = cmux.live<Chat[]>("chat.list", {})
  const ranked = computed(() => rank(chats() ?? [], cmux.app.settings().showIdle === true))
  const style = (c: Chat) => TIERS[tier(c)]!
  return VStack({ spacing: 2 }, [
    ForEach({ items: ranked, key: (c) => c.id }, (c) =>
      Row({
        title: () => c().title,
        subtitle: () => subtitle(c()),
        symbol: () => (c().pinned ? "pin.fill" : style(c()).symbol),
        tint: () => style(c()).tone,
        unread: () => c().unread
      })
        .onTap(() => open(c()))
        .contextMenu(() => [
          Button(c().pinned ? "Unpin" : "Pin", () => pin(c())),
          Button("Mark as Read", () => markRead(c())).disabled(() => !c().unread)
        ])
    ),
    () => (chats.loading() || ranked().length ? null : EmptyState({ title: "Nothing needs you", symbol: "bell" }))
  ])
}
