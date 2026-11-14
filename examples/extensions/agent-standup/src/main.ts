// Standup: what your agents did since yesterday, by project, in a sidebar section. It imports
// nothing but the public SDK.
// - One line sums it up (finished, still working, waiting for you); then each project with the
//   chats that changed in it, newest first. A click opens the chat.
// - chats() re-reads when cmux sends agent_chat.changed; a five-minute timer only keeps the
//   "2 h ago" labels honest. How far back it looks is a setting (Settings > Apps > Standup).

import { chats, cmux, computed, EmptyState, ForEach, onCleanup, Row, signal, Text, VStack, type Chat, type View } from "cmux-extension-sdk"

const HOUR = 3_600_000

export interface Project { name: string; chats: Chat[]; latest: number }

const changedAt = (c: Chat) => Number(c.updated_ms) || 0
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`

/** The chats that changed in the last `hours`, grouped by project, the most recent project first. */
export function standup(list: Chat[], now: number, hours: number): Project[] {
  const since = now - hours * HOUR
  const byProject = new Map<string, Chat[]>()
  for (const c of list) {
    if (changedAt(c) < since) continue
    const name = c.project || c.cwd?.split("/").filter(Boolean).at(-1) || "No project"
    byProject.set(name, [...(byProject.get(name) ?? []), c])
  }
  return [...byProject.entries()]
    .map(([name, cs]) => {
      const sorted = cs.sort((a, b) => changedAt(b) - changedAt(a))
      return { name, chats: sorted, latest: changedAt(sorted[0]!) }
    })
    .sort((a, b) => b.latest - a.latest)
}

export function summary(projects: Project[]): string {
  const all = projects.flatMap((p) => p.chats)
  const count = (pred: (c: Chat) => boolean) => all.filter(pred).length
  const parts = [
    `${plural(count((c) => c.state === "idle"), "chat")} finished`,
    `${count((c) => c.state === "working")} working`,
    `${count((c) => c.state === "input")} waiting for you`
  ]
  const stopped = count((c) => c.state === "failed" || c.state === "lost")
  if (stopped) parts.push(`${stopped} stopped`)
  return parts.join(" · ")
}

export function ago(ms: number, now: number): string {
  const minutes = Math.max(0, Math.round((now - ms) / 60_000))
  if (minutes < 1) return "just now"
  if (minutes < 60) return `${minutes} min ago`
  return `${Math.round(minutes / 60)} h ago`
}

const STATE: Record<string, { label: string; symbol: string; tone: string | null }> = {
  idle: { label: "Finished", symbol: "checkmark.circle", tone: null },
  working: { label: "Working", symbol: "bolt.horizontal", tone: "success" },
  input: { label: "Waiting for you", symbol: "questionmark.bubble", tone: "warning" },
  failed: { label: "Failed", symbol: "exclamationmark.triangle", tone: "danger" },
  lost: { label: "Lost", symbol: "exclamationmark.triangle", tone: "danger" }
}
const stateOf = (c: Chat) => STATE[c.state] ?? { label: c.state, symbol: "circle", tone: null }

function openChat(chat: Chat) {
  cmux.actions
    .run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
    .catch((e: unknown) => cmux.toast({ title: "Couldn't open the chat", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
}

export function renderStandup(): View {
  const list = chats()
  const [now, setNow] = signal(Date.now())
  const timer = cmux.timer.every(5 * 60_000, () => setNow(Date.now()))
  onCleanup(() => cmux.timer.clear(timer))
  const hours = computed(() => {
    const h = Number(cmux.app.settings().hours)
    return Number.isFinite(h) && h > 0 ? h : 24
  })
  const projects = computed(() => standup(list() ?? [], now(), hours()))
  return VStack({ spacing: 2 }, [
    () => (projects().length ? Text(() => summary(projects())).font("caption").color(cmux.theme.text.secondary) : null),
    ForEach({ items: projects, key: (p) => p.name }, (p) =>
      VStack({ spacing: 0 }, [
        Text(() => p().name).font("headline").lineLimit(1),
        ForEach({ items: () => p().chats, key: (c) => c.id }, (c) =>
          Row({
            title: () => c().title || "Untitled chat",
            subtitle: () => `${stateOf(c()).label} · ${ago(changedAt(c()), now())}`,
            symbol: () => stateOf(c()).symbol,
            tint: () => stateOf(c()).tone
          }).onTap(() => openChat(c()))
        )
      ])
    ),
    () => (list.error() ? EmptyState({ title: "Can't read your chats", message: list.error()!.message, symbol: "exclamationmark.triangle" }) : null),
    () => (!list.error() && list() !== undefined && projects().length === 0 ? EmptyState({ title: "A quiet day", message: `No agent chat changed in the last ${hours()} hours.`, symbol: "sun.max" }) : null)
  ])
}
