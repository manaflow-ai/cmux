// Agent pet: a small cat in the sidebar whose mood follows your agents. It imports nothing but the
// public SDK.
// - It naps when nothing runs, gets busy while agents work, rings when a chat waits for your
//   answer and worries when one failed. A click on it then opens that chat.
// - agents() and chats() re-read when cmux sends agent.changed and agent_chat.changed: nothing
//   polls, so the pet costs nothing while your agents are quiet.
// - Its name is a setting (Settings > Apps > Agent pet).

import { agents, chats, cmux, computed, HStack, Icon, Panel, Spacer, Text, VStack, type Chat, type View } from "cmux-extension-sdk"

export type Mood = "waiting" | "worried" | "busy" | "napping" | "lonely"

export interface Feeling {
  mood: Mood
  /** What the pet says. */
  line: string
  /** The small symbol beside the cat. */
  symbol: string
  tone: string
  /** The chat a click opens, when one needs you. */
  chat: Chat | null
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`

/** The pet's mood from the agents and chats: what needs you first, then what is going on. */
export function feel(agentList: Array<{ state: string }>, chatList: Chat[]): Feeling {
  const waiting = chatList.filter((c) => c.state === "input")
  const failed = chatList.filter((c) => c.state === "failed" || c.state === "lost")
  const working = agentList.filter((a) => a.state === "working").length + chatList.filter((c) => c.state === "working").length
  if (waiting.length > 0) {
    const first = waiting[0]!
    const line = waiting.length === 1 ? `${first.title} is waiting for you` : `${plural(waiting.length, "chat")} are waiting for you`
    return { mood: "waiting", line, symbol: "bell.fill", tone: cmux.theme.warning, chat: first }
  }
  if (failed.length > 0) {
    const first = failed[0]!
    return { mood: "worried", line: `${first.title} stopped`, symbol: "exclamationmark.triangle.fill", tone: cmux.theme.danger, chat: first }
  }
  if (working > 0) return { mood: "busy", line: `Watching ${plural(working, "agent")} work`, symbol: "pawprint.fill", tone: cmux.theme.success, chat: null }
  if (agentList.length + chatList.length > 0) return { mood: "napping", line: "Napping: every agent is idle", symbol: "moon.zzz.fill", tone: cmux.theme.text.secondary, chat: null }
  return { mood: "lonely", line: "No agents yet. Start one and I'll keep an eye on it.", symbol: "sparkles", tone: cmux.theme.text.secondary, chat: null }
}

function openChat(chat: Chat) {
  cmux.actions
    .run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
    .catch((e: unknown) => cmux.toast({ title: "Couldn't open the chat", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
}

export function renderPet(): View {
  const agentList = agents()
  const chatList = chats()
  const feeling = computed(() => feel(agentList() ?? [], chatList() ?? []))
  const name = computed(() => String(cmux.app.settings().name ?? "").trim() || "Byte")
  return Panel({ style: "glass" }, [
    HStack({ spacing: 8 }, [
      Icon("cat.fill").font("largeTitle").color(() => feeling().tone),
      VStack({ spacing: 2 }, [
        HStack({ spacing: 4 }, [Text(name).font("headline"), Icon(() => feeling().symbol).font("caption").color(() => feeling().tone)]),
        Text(() => feeling().line).font("caption").color(cmux.theme.text.secondary).lineLimit(2)
      ]),
      Spacer()
    ])
  ])
    .help(() => (feeling().chat ? "Click to open the chat" : name()))
    .onTap(() => {
      const chat = feeling().chat
      if (chat) openChat(chat)
    })
}
