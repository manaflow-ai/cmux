// New Tab launcher: a whole page built only on the public cmux-extension-sdk.
// It keeps the page useful without taking over the composer's job: the clock and greeting set a
// little context, recent chats and workspaces are live, and the actions are one click away.

import {
  Button, cmux, computed, Divider, EmptyState, ForEach, HStack, Icon, onCleanup, Panel, Row, signal,
  Spacer, Text, VStack, newTab, recentChats, workspaces, type Chat, type View
} from "cmux-extension-sdk"

type Layout = "focus" | "split" | "compact"

const MINUTE = 60_000

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`

export function clockText(at: number): string {
  const date = new Date(at)
  const hour = date.getHours()
  const minute = String(date.getMinutes()).padStart(2, "0")
  return `${hour % 12 || 12}:${minute} ${hour < 12 ? "AM" : "PM"}`
}

export function greetingText(at: number): string {
  const hour = new Date(at).getHours()
  if (hour < 5) return "A quiet night for a fresh start"
  if (hour < 12) return "Good morning"
  if (hour < 18) return "Good afternoon"
  return "Good evening"
}

function run(id: string, args: Record<string, unknown> = {}) {
  cmux.actions.run(id, args).catch((error: unknown) => {
    cmux.toast({ title: "Couldn't run that action", message: error instanceof Error ? error.message : String(error), tone: "warning" })
  })
}

function openChat(chat: Chat) {
  run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
}

function actionButton(symbol: string, title: string, subtitle: string, action: () => void): View {
  return Button(
    HStack({ spacing: 8 }, [
      Icon(symbol).color(cmux.theme.accent),
      VStack({ spacing: 1, alignment: "leading" }, [
        Text(title).font("callout").weight("semibold"),
        Text(subtitle).font("caption").color(cmux.theme.text.secondary)
      ]),
      Spacer()
    ]).paddingVertical(8).paddingHorizontal(10),
    action
  ).frame({ maxWidth: "infinity" })
}

function actions(): View {
  return Panel({ style: "glass", spacing: 4 }, [
    Text("Start something").font("headline"),
    HStack({ spacing: 8 }, [
      actionButton("bubble.left.and.bubble.right", "New chat", "Ask an agent", () => run("palette.newAgentChat")),
      actionButton("terminal", "Terminal", "Open a shell", () => run("newSurface")),
      actionButton("globe", "Browser", "Open a page", () => run("openBrowser"))
    ])
  ])
}

function recentPanel(recent: () => Chat[] | undefined): View {
  return Panel({ style: "glass", spacing: 4 }, [
    HStack({ spacing: 8 }, [
      Icon("clock.arrow.circlepath").color(cmux.theme.accent),
      Text("Recent chats").font("headline"),
      Spacer(),
      Text(() => plural((recent() ?? []).length, "chat")).font("caption").color(cmux.theme.text.secondary)
    ]),
    Divider(),
    ForEach({ items: () => recent() ?? [], key: (chat) => chat.id }, (chat) =>
      Row({
        title: () => chat().title || "Untitled chat",
        subtitle: () => chat().preview || (chat().project ?? "No project"),
        symbol: () => chat().state === "input" ? "questionmark.bubble" : chat().state === "working" ? "bolt.horizontal" : "bubble.left",
        tint: () => chat().state === "input" ? cmux.theme.warning : chat().state === "working" ? cmux.theme.accent : null
      }).onTap(() => openChat(chat()))
    ),
    () => (recent() === undefined ? EmptyState({ title: "Loading recent chats…", symbol: "clock" }) : recent()!.length === 0 ? EmptyState({ title: "No chats yet", message: "Start a new chat above.", symbol: "bubble.left" }) : null)
  ])
}

function workspacePanel(spaces: () => Array<{ id: string; name: string; focused: boolean }> | undefined): View {
  return Panel({ style: "glass", spacing: 4 }, [
    HStack({ spacing: 8 }, [
      Icon("square.grid.2x2").color(cmux.theme.accent),
      Text("Workspaces").font("headline"),
      Spacer(),
      Text(() => plural((spaces() ?? []).length, "workspace")).font("caption").color(cmux.theme.text.secondary)
    ]),
    Divider(),
    ForEach({ items: () => spaces() ?? [], key: (space) => space.id }, (space) =>
      Row({
        title: () => space().name,
        subtitle: () => space().focused ? "Current workspace" : "Switch here",
        symbol: () => space().focused ? "checkmark.circle.fill" : "square.grid.2x2",
        selected: () => space().focused,
        tint: () => space().focused ? cmux.theme.success : null
      }).onTap(() => cmux.workspace.focus({ workspace: space().id }).catch((error: unknown) => cmux.toast({ title: "Couldn't switch workspace", message: error instanceof Error ? error.message : String(error), tone: "warning" })))
    ),
    () => (spaces() === undefined ? EmptyState({ title: "Loading workspaces…", symbol: "square.grid.2x2" }) : spaces()!.length === 0 ? EmptyState({ title: "No workspaces", symbol: "square.grid.2x2" }) : null)
  ])
}

function header(cwd: string | undefined, now: () => number, showGreeting: () => boolean): View {
  const folder = cwd?.split("/").filter(Boolean).at(-1)
  return HStack({ spacing: 16, alignment: "bottom" }, [
    VStack({ spacing: 3, alignment: "leading" }, [
      () => (showGreeting() ? Text(() => greetingText(now())).font("largeTitle").weight("bold") : Text("Ready when you are").font("largeTitle").weight("bold")),
      Text(() => folder ? `A fresh tab in ${folder}` : "A fresh tab for your next move").font("title3").color(cmux.theme.text.secondary)
    ]),
    Spacer(),
    VStack({ spacing: 2, alignment: "trailing" }, [
      Text(() => clockText(now())).font("largeTitle").weight("light").monospaced(),
      Text("local time").font("caption").color(cmux.theme.text.secondary)
    ]).fixedSize("horizontal")
  ])
}

function compactList(recent: () => Chat[] | undefined, spaces: () => Array<{ id: string; name: string; focused: boolean }> | undefined): View {
  return VStack({ spacing: 2 }, [
    Text("Recent work").font("headline"),
    ForEach({ items: () => recent() ?? [], key: (chat) => chat.id }, (chat) =>
      Row({ title: () => chat().title || "Untitled chat", subtitle: () => chat().preview || chat().project || "No project", symbol: "bubble.left" }).onTap(() => openChat(chat()))
    ),
    Divider(),
    Text(() => `${plural((spaces() ?? []).length, "workspace")} ready`).font("caption").color(cmux.theme.text.secondary)
  ])
}

export const renderNewTab = newTab((context) => {
  const settings = () => cmux.app.settings()
  const layout = computed<Layout>(() => (["focus", "split", "compact"].includes(String(settings().layout)) ? settings().layout : "focus") as Layout)
  const showGreeting = computed(() => settings().showGreeting !== false)
  const limit = computed(() => {
    const value = Number(settings().recentLimit)
    return Number.isInteger(value) && value > 0 ? Math.min(value, 8) : 5
  })
  const recent = recentChats({ limit: 8 })
  const shownRecent = computed(() => (recent() ?? []).slice(0, limit()))
  const spaces = workspaces()
  const [now, setNow] = signal(Date.now())
  const timer = cmux.timer.every(MINUTE, () => setNow(Date.now()))
  onCleanup(() => cmux.timer.clear(timer))

  return VStack({ spacing: 16 }, [
    header(context.cwd, now, showGreeting),
    ForEach({ items: () => [layout()], key: (value) => value }, (value) => {
      if (value() === "compact") return VStack({ spacing: 10 }, [actions(), compactList(shownRecent, spaces)])
      if (value() === "split") return VStack({ spacing: 10 }, [actions(), HStack({ spacing: 12, alignment: "top" }, [recentPanel(shownRecent), workspacePanel(spaces)])])
      return VStack({ spacing: 10 }, [actions(), recentPanel(shownRecent), workspacePanel(spaces)])
    }),
    Spacer()
  ]).padding()
})
