// A machine and its peer can each list a session with the same id.
const key = (chat) => JSON.stringify([chat.machine || "", chat.id])
const lastActivity = (chat) => Math.max(Number(chat.updated_ms) || 0, Number(chat.created_ms) || 0, Number(chat.since_ms) || 0)
const week = 7 * 24 * 60 * 60 * 1000
const title = (chat) => chat.title || chat.id
const byAge = (a, b) => lastActivity(b) - lastActivity(a) || key(a).localeCompare(key(b))
const target = (chat) => ({ chat: chat.id, ...(chat.machine ? { machine: chat.machine } : {}) })

function childrenByParent(chats) {
  const children = new Map()
  for (const chat of chats) {
    if (!chat.parent) continue
    const parent = JSON.stringify([chat.machine || "", chat.parent])
    if (!children.has(parent)) children.set(parent, [])
    children.get(parent).push(chat)
  }
  return children
}

// Flatten only rows belonging to this view. A child whose parent is archived, pinned
// or in another group stays reachable. A malformed cycle still draws each chat once.
function orderedTree(chats) {
  const ids = new Set(chats.map(key))
  const children = childrenByParent(chats)
  const roots = chats.filter((chat) => !ids.has(JSON.stringify([chat.machine || "", chat.parent])))
  const visited = new Set()
  const rows = []
  function visit(root) {
    const stack = [{ chat: root, depth: 0 }]
    while (stack.length) {
      const row = stack.pop()
      const id = key(row.chat)
      if (visited.has(id)) continue
      visited.add(id)
      rows.push(row)
      const nested = children.get(id) || []
      for (let i = nested.length - 1; i >= 0; i--) stack.push({ chat: nested[i], depth: row.depth + 1 })
    }
  }
  for (const root of roots) visit(root)
  for (const chat of chats) if (!visited.has(key(chat))) visit(chat)
  return rows
}

function branch(chat, children) {
  const result = []
  const seen = new Set()
  const stack = [chat]
  while (stack.length) {
    const item = stack.pop()
    const id = key(item)
    if (seen.has(id)) continue
    seen.add(id)
    result.push(item)
    for (const child of children.get(id) || []) stack.push(child)
  }
  return result
}

function renderRecents() {
  const chats = cmux.live("chat.list", { include_archived: true })
  const [view, setView] = signal("Sessions")
  const [archived, setArchived] = signal(false)
  const [limit, setLimit] = signal(18)
  const [busy, setBusy] = signal(false)
  const [error, setError] = signal("")
  const [order, setOrder] = signal([])
  const [orderReady, setOrderReady] = signal(false)
  let writing = Promise.resolve()

  const problem = (e) => e instanceof Error ? e.message : String(e)
  cmux.storage.get("session-recents.pin-order").then((saved) => {
    if (Array.isArray(saved)) setOrder(saved)
    setOrderReady(true)
  }).catch((e) => setError(problem(e)))

  const all = computed(() => [...(chats() || [])].sort(byAge))
  const children = computed(() => childrenByParent(all()))
  const pins = computed(() => {
    const positions = new Map(order().map((id, index) => [id, index]))
    return all().filter((c) => c.pinned && !c.archived)
      .sort((a, b) => (positions.get(key(a)) ?? positions.size) - (positions.get(key(b)) ?? positions.size))
  })
  const recent = computed(() => all().filter((c) => !c.archived && !c.pinned))
  const rows = computed(() => {
    const shown = archived() ? all().filter((c) => c.archived) : recent()
    if (view() === "Sessions") return orderedTree(shown)
    const groups = new Map()
    for (const chat of shown) {
      const group = view() === "Projects" ? (chat.cwd || chat.project || "No project") : (chat.harness || "Other agents")
      if (!groups.has(group)) groups.set(group, [])
      groups.get(group).push(chat)
    }
    return [...groups].flatMap(([group, members]) => [{ group }, ...orderedTree(members)])
  })

  function movePin(id, index) {
    if (!orderReady()) return
    const ids = pins().map(key)
    const from = ids.indexOf(id)
    if (from < 0 || !Number.isInteger(index)) return
    ids.splice(from, 1)
    ids.splice(Math.max(0, Math.min(ids.length, index)), 0, id)
    setOrder(ids)
    writing = writing.then(() => cmux.storage.set("session-recents.pin-order", ids))
      .catch((e) => setError(problem(e)))
  }

  async function archive(items, value) {
    if (busy()) return
    setBusy(true)
    setError("")
    let completed = 0
    try {
      for (const chat of items) {
        if (Boolean(chat.archived) === value) continue
        await cmux.call("chat.archive", { ...target(chat), archived: value })
        completed++
      }
    } catch (e) {
      setError(`${completed} ${value ? "archived" : "restored"}. ${problem(e)}`)
    } finally {
      setBusy(false)
    }
  }

  function row(getChat, depth) {
    const open = () => {
      const chat = getChat()
      return cmux.actions.run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
        .catch((e) => setError(problem(e)))
    }
    return Row({ title: () => title(getChat()) }).padding(() => ({ leading: 12 * Math.min(depth(), 5) }))
      .onTap(open)
      .contextMenu(() => {
        const chat = getChat()
        const next = !chat.archived
        const nested = branch(chat, children())
        const items = [
          Button("Open", open),
          Button(chat.pinned ? "Unpin" : "Pin", () => cmux.call("chat.pin", { ...target(chat), pinned: !chat.pinned })
            .catch((e) => setError(problem(e)))),
          Button(next ? "Archive" : "Restore", () => archive([chat], next)).disabled(busy),
        ]
        if (nested.length > 1) items.push(Button(next ? "Archive with nested sessions" : "Restore with nested sessions",
          () => archive(nested, next)).disabled(busy))
        return items
      })
  }

  const older = () => {
    const cutoff = Date.now() - week
    return recent().filter((c) => lastActivity(c) > 0 && lastActivity(c) < cutoff)
  }
  const switchView = (name) => { setView(name); setLimit(18) }
  return VStack({ spacing: 2 }, [
    HStack([
      Menu(() => archived() ? "Archived" : view(), [
        ...["Sessions", "Projects", "Agents"].map((name) => Button(name, () => { setArchived(false); switchView(name) })),
        Button("Show archived", () => { setArchived(true); setLimit(18) }),
      ]),
      Spacer(),
      Menu("Archive", [
        Button("Archive all recent sessions", () => archive(recent(), true)).disabled(() => busy() || !recent().length),
        Button("Archive older than a week", () => archive(older(), true)).disabled(() => busy() || !recent().length),
        Button("Show archived", () => { setArchived(true); setLimit(18) }),
      ]),
    ]),
    () => error() ? Text(error()) : null,
    () => chats.status() === "error" ? Text(chats.error()?.message || "Could not load sessions") : null,
    () => !archived() && pins().length ? Text("Pinned").secondary() : null,
    ForEach({ items: () => archived() ? [] : pins(), key, onMove: movePin }, (c) => row(c, () => 0)),
    ForEach({ items: () => rows().slice(0, limit()), key: (r) => r.group === undefined ? key(r.chat) : "group:" + r.group }, (r) =>
      r().group === undefined ? row(() => r().chat, () => r().depth) : Text(() => r().group).secondary()),
    () => rows().length > limit() ? Button("Show more", () => setLimit(limit() + 18)) : null,
    () => archived() && chats.status() === "fresh" && !rows().length ? Text("No archived sessions").secondary() : null,
  ])
}

globalThis.__cmuxAppExports = { renderRecents }
