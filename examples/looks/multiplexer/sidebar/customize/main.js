// Sidebar: the tree a multiplexer draws, host, then session, then tab. cmux groups workspaces by
// computer itself (sidebar.groupByComputer); this file adds what settings cannot: a Hosts section
// with a collapsible row per host, a row per session under it (status dot, how many chats it
// holds), collapse controls that show on hover, and plain one-line decorations on the native rows.
// One read per change (workspace.changed, agent_chat.changed); nothing polls.

;(() => {
  const [workspaces, setWorkspaces] = signal([])
  const [chats, setChats] = signal([])
  const [machines, setMachines] = signal([])
  const [closed, setClosed] = signal({}) // host id -> true when its group is collapsed

  const message = (e) => (e instanceof Error ? e.message : String(e))
  const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this view`, message: message(e), tone: "warning" })

  let reading = false
  let again = false
  async function load() {
    if (reading) return void (again = true)
    reading = true
    try {
      const [ws, list, ms] = await Promise.all([
        cmux.workspace.list({}).catch(() => []),
        cmux.call("agent_chat.list", {}).catch(() => ({ chats: [] })),
        cmux.call("machine.list", {}).catch(() => [])
      ])
      setWorkspaces(ws)
      setChats(list.chats || [])
      setMachines(Array.isArray(ms) ? ms : ms.machines || [])
    } finally {
      reading = false
      if (again) {
        again = false
        load()
      }
    }
  }

  let following = false
  function follow() {
    if (following) return
    following = true
    load()
    cmux.events.on("workspace.changed", load)
    cmux.events.on("agent_chat.changed", load)
  }

  const localId = () => (machines().find((m) => m.origin === "local") || {}).id || "local"
  const hostOf = (id) => machines().find((m) => m.id === id) || null

  function dotOf(list) {
    if (list.some((c) => c.state === "input")) return { tone: cmux.theme.warning, symbol: "circle.fill" }
    if (list.some((c) => c.state === "failed" || c.state === "lost")) return { tone: cmux.theme.danger, symbol: "circle.fill" }
    if (list.some((c) => c.state === "working")) return { tone: cmux.theme.accent, symbol: "status.inprogress" }
    if (list.some((c) => c.unread)) return { tone: cmux.theme.success, symbol: "circle.fill" }
    return null
  }

  // Hosts, each with its sessions. A workspace belongs to the host of the chats in it, else to
  // this Mac.
  const hosts = computed(() => {
    const groups = new Map()
    const group = (id) => {
      if (!groups.has(id)) {
        const m = hostOf(id)
        groups.set(id, { id, name: !m || m.origin === "local" ? "This Mac" : m.name, symbol: !m || m.origin === "local" ? "laptopcomputer" : m.origin === "cloud" ? "cloud" : "server.rack", sessions: [] })
      }
      return groups.get(id)
    }
    group(localId())
    for (const w of workspaces()) {
      const own = chats().filter((c) => c.workspace === w.id)
      const id = (own[0] && own[0].machine) || localId()
      group(id).sessions.push({ id: w.id, name: w.name, focused: !!w.focused, chats: own, dot: dotOf(own) })
    }
    return [...groups.values()].filter((g) => g.sessions.length || g.id === localId())
  })

  function sessionRow(s) {
    return HStack({ spacing: 6 }, [
      Text(() => s().name).font(12).weight(() => (s().focused ? "medium" : "regular")).color(() => (s().focused ? "primary" : "secondary")).lineLimit(1),
      Spacer(),
      () => (s().chats.length > 1 ? Badge(() => String(s().chats.length), "secondary") : null),
      () => (s().dot ? Icon(s().dot.symbol).size(8).color(s().dot.tone) : null)
    ])
      .paddingHorizontal(10)
      .frame({ height: 26 })
      .cornerRadius(13)
      .background(() => (s().focused ? "selected" : null))
      .hoverBackground(() => (s().focused ? "selected" : "hover"))
      .cursor("pointer")
      .onTap(() => cmux.workspace.focus({ workspace: s().id }).then(load, refused("Change workspaces")))
  }

  function hostHeader(g) {
    const open = () => !closed()[g().id]
    return HStack({ spacing: 6 }, [
      Icon("chevron.right").size(8).color("tertiary").rotation(() => (open() ? 90 : 0)),
      Icon(() => g().symbol).size(12).color("secondary"),
      Text(() => g().name).font("caption").weight("semibold").color("secondary").lineLimit(1),
      Spacer(),
      Text(() => String(g().sessions.length)).font("caption").monospaced().color("tertiary")
    ])
      .paddingHorizontal(8)
      .frame({ height: 24 })
      .cornerRadius(12)
      .hoverBackground("hover")
      .cursor("pointer")
      .onTap(() => setClosed((c) => ({ ...c, [g().id]: !c[g().id] })))
      .contextMenu(() => [
        Button("Collapse Other Hosts", () => setClosed(Object.fromEntries(hosts().filter((h) => h.id !== g().id).map((h) => [h.id, true])))),
        Button("Expand All", () => setClosed({}))
      ])
  }

  function hostTree() {
    follow()
    return VStack({ spacing: 2 }, [
      ForEach({ items: hosts, key: (g) => g.id }, (g) =>
        VStack({ spacing: 1 }, [hostHeader(g), ForEach({ items: () => (closed()[g().id] ? [] : g().sessions), key: (s) => s.id }, sessionRow)])
      ),
      () => (workspaces().length ? null : EmptyState({ title: "No sessions", message: "Shift-Command-N starts one.", symbol: "rectangle.stack" }))
    ])
  }

  // Rows: one line each, regular weight, a plain dot while a chat works.
  function decorateRows() {
    const list = cmux.live("workspace.list", {})
    return VStack([ForEach({ items: () => list() ?? [], key: (w) => w.id }, (w) => Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "dot" }, []))])
  }

  const mx = (globalThis.__mx = globalThis.__mx || {})
  mx.hostTree = hostTree
  globalThis.__cmuxAppExports = Object.assign(globalThis.__cmuxAppExports || {}, { renderHosts: hostTree, decorateRows })
})()
