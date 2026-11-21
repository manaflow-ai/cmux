// New Tab as a session switcher: one "Filter or create…" field over every workspace, a row per
// workspace (host glyph, name, host, activity), the folders you went to last, and a footer with
// New Session, New Session on Host and Add Remote Host. Typing filters; the last row creates a
// workspace named what you typed. Reads change by event (workspace.changed, agent_chat.changed),
// never by timer.

;(() => {
  const [workspaces, setWorkspaces] = signal([])
  const [chats, setChats] = signal([])
  const [machines, setMachines] = signal([])
  const [draft, setDraft] = signal("")
  const [recents, setRecents] = signal([]) // folders opened from this page, newest first
  const [now, setNow] = signal(Date.now())

  const message = (e) => (e instanceof Error ? e.message : String(e))
  const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this page`, message: message(e), tone: "warning" })
  const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

  cmux.storage
    .get("recent-folders")
    .then((saved) => Array.isArray(saved) && setRecents(saved))
    .catch(() => undefined)

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
      setNow(Date.now())
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
    cmux.timer.every(60_000, () => setNow(Date.now()))
  }

  const lastActivity = (c) => Math.max(Number(c.updated_ms) || 0, Number(c.since_ms) || 0, Number(c.created_ms) || 0)
  function age(ms) {
    if (!ms) return ""
    const s = Math.max(0, Math.round((now() - ms) / 1000))
    if (s < 60) return "now"
    if (s < 3600) return `${Math.floor(s / 60)}m`
    if (s < 86400) return `${Math.floor(s / 3600)}h`
    return `${Math.floor(s / 86400)}d`
  }

  const hostName = (id) => {
    const m = machines().find((x) => x.id === id)
    if (m) return m.origin === "local" ? "This Mac" : m.name
    const local = machines().find((x) => x.origin === "local")
    return local ? "This Mac" : "This Mac"
  }
  const hostSymbol = (id) => {
    const m = machines().find((x) => x.id === id) || machines().find((x) => x.origin === "local")
    if (!m || m.origin === "local") return "laptopcomputer"
    return m.origin === "cloud" ? "cloud" : "server.rack"
  }

  // Activity, in the order the activity look sorts by: blocked, error, done, working, idle.
  function stateOf(chat) {
    if (!chat) return { label: "Idle", symbol: "circle", tone: "tertiary", rank: 4 }
    if (chat.state === "input") return { label: "Needs you", symbol: "status.needsinput", tone: cmux.theme.warning, rank: 0 }
    if (chat.state === "failed" || chat.state === "lost") return { label: "Error", symbol: "status.error", tone: cmux.theme.danger, rank: 1 }
    if (chat.unread && chat.state !== "working") return { label: "Done", symbol: "status.success", tone: cmux.theme.success, rank: 2 }
    if (chat.state === "working") return { label: "Working", symbol: "status.inprogress", tone: cmux.theme.accent, rank: 3 }
    return { label: "Idle", symbol: "circle", tone: "tertiary", rank: 4 }
  }

  const sessions = computed(() =>
    workspaces()
      .map((w) => {
        const chat = chats()
          .filter((c) => c.workspace === w.id)
          .sort((a, b) => stateOf(a).rank - stateOf(b).rank || lastActivity(b) - lastActivity(a))[0]
        const state = stateOf(chat)
        return { id: w.id, name: w.name, focused: !!w.focused, host: hostName(chat && chat.machine), symbol: hostSymbol(chat && chat.machine), cwd: (chat && chat.cwd) || "", state, at: chat ? lastActivity(chat) : 0 }
      })
      .sort((a, b) => a.state.rank - b.state.rank || b.at - a.at)
  )

  const query = computed(() => draft().trim().toLowerCase())
  const matches = computed(() => (query() ? sessions().filter((s) => `${s.name} ${s.host} ${s.cwd}`.toLowerCase().includes(query())) : sessions()))
  const exact = computed(() => sessions().some((s) => s.name.toLowerCase() === query()))

  // Recent folders: the ones you opened from here, then the ones agent chats worked in.
  const folders = computed(() => {
    const out = []
    const seen = new Set()
    const add = (path) => {
      if (path && !seen.has(path)) {
        seen.add(path)
        out.push(path)
      }
    }
    recents().forEach(add)
    ;[...chats()].sort((a, b) => lastActivity(b) - lastActivity(a)).forEach((c) => add(c.cwd))
    const q = query()
    return (q ? out.filter((p) => p.toLowerCase().includes(q)) : out).slice(0, 6)
  })

  const tail = (path) => path.replace(/\/+$/, "").split("/").pop() || path
  const tidy = (path) => path.replace(/^\/Users\/[^/]+/, "~")

  function show(session) {
    cmux.workspace.focus({ workspace: session.id }).then(load, refused("Change workspaces"))
  }

  function create(name) {
    const title = name.trim()
    if (!title) return
    cmux.call("workspace.create", { name: title, initial_content: "terminal", focus: true }).then(() => {
      setDraft("")
      load()
    }, refused("Change workspaces"))
  }

  // Go to Directory: a workspace in that folder, remembered at the top of the list.
  function goTo(path) {
    cmux.call("workspace.create", { name: tail(path), initial_content: "terminal", cwd: path, focus: true }).then(() => {
      setRecents((r) => [path, ...r.filter((p) => p !== path)].slice(0, 12))
      cmux.storage.set("recent-folders", recents()).catch(() => undefined)
      load()
    }, refused("Change workspaces"))
  }

  function submit() {
    const first = matches()[0]
    if (first && (exact() || !query() || matches().length === 1)) show(first)
    else create(draft())
  }

  function sessionRow(s) {
    return HStack({ spacing: 8 }, [
      Icon(() => s().symbol).size(13).color("secondary"),
      Text(() => s().name).weight(() => (s().focused ? "semibold" : "regular")).lineLimit(1),
      Text(() => s().host).font("caption").color("tertiary").lineLimit(1),
      Spacer(),
      Icon(() => s().state.symbol).size(10).color(() => s().state.tone),
      Text(() => s().state.label).font("caption").color(() => s().state.tone).fixedSize("horizontal")
    ])
      .paddingHorizontal(10)
      .frame({ height: 34 })
      .cornerRadius(16.5)
      .background(() => (s().focused ? "selected" : null))
      .hoverBackground("hover")
      .cursor("pointer")
      .onTap(() => show(s()))
  }

  function renderNewTab() {
    follow()
    return VStack({ spacing: 12 }, [
      Spacer(),
      Panel({ style: "card" }, [
        TextField(draft, { placeholder: "Filter or create…", autofocus: true, onEdit: setDraft, onSubmit: submit }),
        VStack({ spacing: 2 }, [
          ForEach({ items: matches, key: (s) => s.id }, sessionRow),
          () =>
            query() && !exact()
              ? HStack({ spacing: 8 }, [
                  Icon("plus.circle").size(13).color(cmux.theme.accent),
                  Text(() => `Create ${draft().trim()}`).lineLimit(1),
                  Spacer(),
                  Text("This Mac").font("caption").color("tertiary")
                ])
                  .paddingHorizontal(10)
                  .frame({ height: 34 })
                  .cornerRadius(16.5)
                  .hoverBackground("hover")
                  .cursor("pointer")
                  .onTap(() => create(draft()))
              : null,
          () => (!sessions().length && !query() ? EmptyState({ title: "No sessions yet", message: "Type a name to create one.", symbol: "rectangle.stack" }) : null)
        ])
      ]),
      () =>
        folders().length
          ? Panel({ title: "Go to Directory", style: "card" }, [
              ForEach({ items: folders, key: (p) => p }, (p) =>
                Row({ title: () => tail(p()), subtitle: () => tidy(p()), symbol: "folder", tint: "secondary" }).onTap(() => goTo(p()))
              )
            ])
          : null,
      HStack({ spacing: 8 }, [
        Spacer(),
        Button(HStack({ spacing: 4 }, [Icon("rectangle.stack.badge.plus"), Text("New Session")]), () => run("new.terminal.workspace")),
        Button(HStack({ spacing: 4 }, [Icon("server.rack"), Text("New Session on Host…")]), () => run("workspace.newOnMachine")),
        Button(HStack({ spacing: 4 }, [Icon("globe"), Text("Add Remote Host…")]), () => run("machine.add")),
        Spacer()
      ]),
      Spacer()
    ])
  }

  globalThis.__cmuxAppExports = Object.assign(globalThis.__cmuxAppExports || {}, { renderNewTab })
})()
