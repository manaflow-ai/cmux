// A live inbox of real agent questions. A click opens that chat in a tab.
function renderNeedsYou() {
  const chats = cmux.live("agent_chat.list")
  const waiting = computed(() => (chats()?.chats || []).filter((chat) => chat.state === "input"))
  const open = (chat) => cmux.actions.run("agent.openSessionTab", {
    session: chat.id,
    ...(chat.machine ? { host: chat.machine } : {})
  }).catch((error) =>
    cmux.toast({ title: "Cannot open chat", message: String(error), tone: "warning" })
  )
  return VStack([
    ForEach({ items: waiting, key: (chat) => chat.id }, (chat) =>
      Row({
        title: () => chat().title,
        subtitle: () => chat().step || chat().project || "Waiting for your answer",
        symbol: "questionmark.bubble",
        tint: cmux.theme.warning
      }).onTap(() => open(chat()))
    ),
    () => chats.loading() && !chats() ? EmptyState({ title: "Reading chats…" }) : null,
    () => chats.error() ? EmptyState({ title: "Cannot read chats", message: chats.error().message }) : null,
    () => chats() && !chats.error() && !waiting().length ? EmptyState({ title: "No questions waiting", symbol: "checkmark.circle" }) : null
  ])
}

globalThis.__cmuxAppExports = { renderNeedsYou }
