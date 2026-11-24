// A machine and its peer can each list a session with the same id.
const key = (chat) => JSON.stringify([chat.machine || "", chat.id])
const lastActivity = (chat) => Math.max(Number(chat.updated_ms) || 0, Number(chat.created_ms) || 0, Number(chat.since_ms) || 0)
const week = 7 * 24 * 60 * 60 * 1000
const title = (chat) => chat.title || chat.id
const byAge = (a, b) => lastActivity(b) - lastActivity(a) || key(a).localeCompare(key(b))
const target = (chat) => ({ chat: chat.id, peer: chat.machine || null })

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
  const [recentPage, setRecentPage] = signal(0)
  const [pinPage, setPinPage] = signal(0)
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

  // One row overlaps pinned pages so a drag can move a pin across a page boundary.
  function pages(items, page, setPage, overlap = 0) {
    const size = 18
    const stride = size - overlap
    const last = () => Math.max(0, Math.ceil((items().length - size) / stride))
    const current = () => Math.min(page(), last())
    const start = () => current() * stride
    return {
      visible: () => items().slice(start(), start() + size),
      start,
      controls: () => last() ? HStack([
        Button("Previous", () => setPage(current() - 1)).disabled(() => current() === 0),
        Spacer(),
        Button("Next", () => setPage(current() + 1)).disabled(() => current() === last()),
      ]) : null,
    }
  }
  const recentPages = pages(rows, recentPage, setRecentPage)
  const pinPages = pages(pins, pinPage, setPinPage, 1)

  function movePin(id, index) {
    if (!orderReady()) return
    const ids = pins().map(key)
    const from = ids.indexOf(id)
    if (from < 0 || !Number.isInteger(index)) return
    ids.splice(from, 1)
    ids.splice(Math.max(0, Math.min(ids.length, pinPages.start() + index)), 0, id)
    setOrder(ids)
    writing = writing.then(() => cmux.storage.set("session-recents.pin-order", ids))
      .catch((e) => setError(problem(e)))
  }

  async function archive(items, value) {
    if (busy()) return
    setBusy(true)
    setError("")
    try {
      const targets = items.filter((chat) => Boolean(chat.archived) !== value).map(target)
      if (!targets.length) return
      const results = await cmux.call("chat.archive", { targets, archived: value })
      const failed = results.filter((r) => r.error != null)
      if (failed.length) {
        const first = failed[0]
        const where = first.peer ? first.peer + "/" + first.chat : first.chat
        setError(`${results.length - failed.length} ${value ? "archived" : "restored"}, ${failed.length} failed. ${where}: ${first.error}`)
      }
    } catch (e) {
      setError(problem(e))
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
    return Row({ title: () => title(getChat()), subtitle: () => getChat().machine || undefined }).padding(() => ({ leading: 12 * Math.min(depth(), 5) }))
      .onTap(open)
      .contextMenu(() => {
        const chat = getChat()
        const next = !chat.archived
        const nested = children().has(key(chat))
        const items = [Button("Open", open)]
        if (!chat.archived) items.push(Button(chat.pinned ? "Unpin" : "Pin", () =>
          cmux.call("chat.pin", { ...target(chat), pinned: !chat.pinned }).catch((e) => setError(problem(e)))))
        items.push(Button(next ? "Archive" : "Restore", () => archive([chat], next)).disabled(busy))
        if (nested) items.push(Button(next ? "Archive with nested sessions" : "Restore with nested sessions",
          () => archive(branch(chat, children()), next)).disabled(busy))
        return items
      })
  }

  const older = () => {
    const cutoff = Date.now() - week
    return recent().filter((c) => lastActivity(c) > 0 && lastActivity(c) < cutoff)
  }
  const switchView = (name) => {
    setView(name)
    setArchived(false)
    setRecentPage(0)
  }
  return VStack({ spacing: 2 }, [
    HStack([
      Menu(() => archived() ? "Archived" : view(), [
        ...["Sessions", "Projects", "Agents"].map((name) => Button(name, () => switchView(name))),
      ]),
      Spacer(),
      () => archived() ? Button("Back to recents", () => switchView(view())) : Menu("Archive", [
        Button("Archive all recent sessions", () => archive(recent(), true)).disabled(() => busy() || !recent().length),
        Button("Archive older than a week", () => archive(older(), true)).disabled(() => busy() || !recent().length),
        Button("Show archived", () => { setArchived(true); setRecentPage(0) }),
      ]),
    ]),
    () => error() ? Text(error()) : null,
    () => chats.error() ? Text(chats.error().message) : null,
    () => !archived() && pins().length ? Text("Pinned").secondary() : null,
    Reorderable({ items: () => archived() ? [] : pinPages.visible(), key, onMove: movePin }, (c) => row(c, () => 0)),
    () => archived() ? null : pinPages.controls(),
    () => !archived() && view() === "Sessions" && pins().length && rows().length ? Text("Recents").secondary() : null,
    ForEach({ items: recentPages.visible, key: (r) => r.group === undefined ? key(r.chat) : "group:" + r.group }, (r) =>
      r().group === undefined ? row(() => r().chat, () => r().depth) : Text(() => r().group).secondary()),
    recentPages.controls,
    () => archived() && !chats.loading() && !chats.error() && !rows().length ? Text("No archived sessions").secondary() : null,
  ])
}

globalThis.__cmuxAppExports = { renderRecents }
