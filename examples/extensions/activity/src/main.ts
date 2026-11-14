// Activity: an example extension that imports nothing but the public SDK.
// - A sidebar section (cmux.section/1): each workspace, with the chats in it that wait for you,
//   and how many agents are working. Click a row to show that workspace.
// - A pane (cmux.pane/1): a live feed of the workspace, agent and chat events cmux sends.
// The lists re-read when cmux pushes their event; nothing polls.

import {
  agents, chats, cmux, computed, EmptyState, ForEach, on, pane, Row, section, signal, Text, VStack, workspaces,
  type Chat, type EventStream
} from "cmux-extension-sdk"

const waiting = (c: Chat) => c.state === "input" || c.unread

function plural(n: number, one: string, many = `${one}s`) {
  return `${n} ${n === 1 ? one : many}`
}

export const renderSection = section(() => {
  const spaces = workspaces()
  const chatList = chats()
  const agentList = agents()
  const working = computed(() => (agentList() ?? []).filter((a) => a.state === "working").length)
  const waitingIn = (workspace: string) => (chatList() ?? []).filter((c) => c.workspace === workspace && waiting(c))

  return VStack({ spacing: 2 }, [
    Row({
      title: () => (working() === 0 ? "No agent working" : `${plural(working(), "agent")} working`),
      symbol: "bolt.horizontal",
      tint: () => (working() === 0 ? cmux.theme.text.secondary : cmux.theme.success)
    }),
    ForEach({ items: () => spaces() ?? [], key: (w) => w.id }, (w) =>
      Row({
        title: () => w().name,
        subtitle: () => {
          const n = waitingIn(w().id).length
          return n === 0 ? null : `${plural(n, "chat")} waiting for you`
        },
        symbol: () => (w().focused ? "rectangle.inset.filled" : "rectangle"),
        badge: () => waitingIn(w().id).length || null,
        selected: () => w().focused
      }).onTap(() => cmux.workspace.focus({ workspace: w().id }))
    ),
    () => (spaces.error() ? EmptyState({ title: "Can't read workspaces", message: spaces.error()!.message, symbol: "exclamationmark.triangle" }) : null)
  ])
})

// The feed: one entry per event, newest first, the last 50 kept for as long as the extension runs.
interface Entry { id: number; stream: EventStream; at: number }
const [feed, setFeed] = signal<Entry[]>([])
let next = 0
const label: Record<string, string> = {
  "workspace.changed": "Workspaces changed",
  "agent.changed": "An agent changed state",
  "agent_chat.changed": "A chat changed",
  "tab.changed": "Tabs changed",
  "pane.changed": "Panes changed"
}
const symbol: Record<string, string> = {
  "workspace.changed": "rectangle.stack",
  "agent.changed": "bolt.horizontal",
  "agent_chat.changed": "bubble.left.and.bubble.right",
  "tab.changed": "rectangle.topthird.inset.filled",
  "pane.changed": "rectangle.split.2x1"
}
const time = (ms: number) => new Date(ms).toTimeString().slice(0, 8)

export const renderPane = pane(() => {
  for (const stream of Object.keys(label) as EventStream[]) {
    on(stream, () => setFeed((list) => [{ id: next++, stream, at: Date.now() }, ...list].slice(0, 50)))
  }
  return VStack({ spacing: 2 }, [
    Text(() => `${plural(feed().length, "event")} since this pane opened`),
    ForEach({ items: feed, key: (e) => String(e.id) }, (e) =>
      Row({ title: () => label[e().stream] ?? e().stream, subtitle: () => `${e().stream} · ${time(e().at)}`, symbol: () => symbol[e().stream] ?? "circle" })
    ),
    () => (feed().length === 0 ? EmptyState({ title: "Waiting for events", message: "Open a workspace, start an agent or answer a chat.", symbol: "waveform.path.ecg" }) : null)
  ])
})
