// Activity: every agent chat in one list, grouped by what needs you first (blocked, then error,
// then done, then working, then idle), or grouped by session. The toggle is a control at the top of
// the section. Data is agent_chat.list, read once per change (agent_chat.changed).

;(() => {
  const [chats, setChats] = signal([])
  const [mode, setMode] = signal("priority") // "priority" | "session"
  const [idle, setIdle] = signal(false) // include idle chats
  const [now, setNow] = signal(Date.now())

  const message = (e) => (e instanceof Error ? e.message : String(e))
  const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this view`, message: message(e), tone: "warning" })
  const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

  cmux.storage
    .get("mode")
    .then((saved) => (saved === "session" || saved === "priority") && setMode(saved))
    .catch(() => undefined)

  let reading = false
  let again = false
  async function load() {
    if (reading) return void (again = true)
    reading = true
    try {
      const list = await cmux.call("agent_chat.list", {})
      setChats(list.chats || [])
      setNow(Date.now())
    } catch (e) {
      setChats([])
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
    cmux.events.on("agent_chat.changed", load)
    cmux.timer.every(30_000, () => setNow(Date.now()))
  }

  const lastActivity = (c) => Math.max(Number(c.updated_ms) || 0, Number(c.since_ms) || 0, Number(c.created_ms) || 0)
  function age(ms) {
    if (!ms) return ""
    const s = Math.max(0, Math.round((now() - ms) / 1000))
    if (s < 60) return `${s}s`
    if (s < 3600) return `${Math.floor(s / 60)}m`
    if (s < 86400) return `${Math.floor(s / 3600)}h`
    return `${Math.floor(s / 86400)}d`
  }

  // blocked > error > done > working > idle
  const LEVELS = [
    { id: "blocked", title: "Blocked", symbol: "status.needsinput", tone: () => cmux.theme.warning },
    { id: "error", title: "Error", symbol: "status.error", tone: () => cmux.theme.danger },
    { id: "done", title: "Done", symbol: "status.success", tone: () => cmux.theme.success },
    { id: "working", title: "Working", symbol: "status.inprogress", tone: () => cmux.theme.accent },
    { id: "idle", title: "Idle", symbol: "circle", tone: () => "tertiary" }
  ]
  function levelOf(c) {
    if (c.state === "input") return "blocked"
    if (c.state === "failed" || c.state === "lost") return "error"
    if (c.state === "working") return "working"
    if (c.unread) return "done"
    return "idle"
  }

  const visible = computed(() => chats().filter((c) => idle() || levelOf(c) !== "idle"))
  const groups = computed(() => {
    if (mode() === "priority") {
      return LEVELS.map((l) => ({ id: l.id, title: l.title, symbol: l.symbol, tone: l.tone(), chats: visible().filter((c) => levelOf(c) === l.id).sort((a, b) => lastActivity(b) - lastActivity(a)) })).filter((g) => g.chats.length)
    }
    const by = new Map()
    for (const c of [...visible()].sort((a, b) => lastActivity(b) - lastActivity(a))) {
      const key = c.workspace || c.project || "No session"
      if (!by.has(key)) by.set(key, { id: key, title: c.project || "No session", symbol: "rectangle.stack", tone: "secondary", chats: [] })
      by.get(key).chats.push(c)
    }
    return [...by.values()].slice(0, 12)
  })

  function show(c) {
    if (c.workspace) cmux.workspace.focus({ workspace: c.workspace }).catch(refused("Change workspaces"))
    else run("agent.openSessionTab", { session: c.id })
  }

  function chatRow(c) {
    const lvl = () => LEVELS.find((l) => l.id === levelOf(c()))
    return HStack({ spacing: 6 }, [
      Icon(() => lvl().symbol).size(10).color(() => lvl().tone()),
      Text(() => c().title).font(12).color(() => (levelOf(c()) === "idle" ? "secondary" : "primary")).lineLimit(1),
      Spacer(),
      Text(() => age(lastActivity(c()))).font("caption").monospaced().color("tertiary").fixedSize("horizontal")
    ])
      .paddingHorizontal(10)
      .frame({ height: 26 })
      .cornerRadius(13)
      .hoverBackground("hover")
      .cursor("pointer")
      .help(() => [c().title, c().cwd, c().step || c().error].filter(Boolean).join("\n"))
      .onTap(() => show(c()))
  }

  function groupHeader(g) {
    return HStack({ spacing: 6 }, [
      Icon(() => g().symbol).size(10).color(() => g().tone),
      Text(() => g().title).font("caption").weight("semibold").color("secondary").lineLimit(1),
      Spacer(),
      Text(() => String(g().chats.length)).font("caption").monospaced().color("tertiary")
    ])
      .paddingHorizontal(8)
      .frame({ height: 22 })
  }

  function activityList() {
    follow()
    return VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [
        Menu(() => (mode() === "priority" ? "By priority" : "By session"), [
          Button("Show Activity by Priority", () => (setMode("priority"), cmux.storage.set("mode", "priority").catch(() => undefined))),
          Button("Show Activity by Session", () => (setMode("session"), cmux.storage.set("mode", "session").catch(() => undefined)))
        ]),
        Spacer(),
        Toggle(idle, { label: "Idle", onChange: setIdle })
      ]),
      ForEach({ items: groups, key: (g) => g.id }, (g) => VStack({ spacing: 1 }, [groupHeader(g), ForEach({ items: () => g().chats.slice(0, 12), key: (c) => c.id }, chatRow)])),
      () => (visible().length ? null : EmptyState({ title: "Nothing needs you", message: "Agents that work, block or finish show up here.", symbol: "checkmark.circle" }))
    ])
  }

  const mx = (globalThis.__mx = globalThis.__mx || {})
  mx.activityList = activityList
  globalThis.__cmuxAppExports = Object.assign(globalThis.__cmuxAppExports || {}, { renderActivity: activityList })
})()
