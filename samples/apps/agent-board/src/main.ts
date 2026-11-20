/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Presentation only. Threads, source deduplication and leases belong to acpmux.
interface Chat { id: string; title: string; machine?: string | null }
interface Post { id: string; kind: "status" | "blocker" | "receipt" | "warn"; body: string; created: string | number; sources?: Record<string, unknown> }
interface Thread { channel: string; thread: string; latest: Post; posts?: Post[]; lease?: { owner: string; epoch: number; expires: string | number } | null }
interface Threads { recipient: string; threads: Thread[] }
const symbol = (kind: string) => kind === "warn" || kind === "blocker" ? "exclamationmark.triangle" : kind === "receipt" ? "checkmark.circle" : "text.bubble"
const key = (thread: Thread) => `${thread.channel}\u0000${thread.thread}`

export function renderPane() {
  const [chats, setChats] = signal<Chat[]>([])
  const [recipient, setRecipient] = signal<Chat | null>(null)
  const [threads, setThreads] = signal<Thread[]>([])
  const [selected, setSelected] = signal<Thread | null>(null)
  const [busy, setBusy] = signal(false)
  const [problem, setProblem] = signal<string | null>(null)
  const [updated, setUpdated] = signal<string | null>(null)
  let generation = 0
  let alive = true
  onCleanup(() => { alive = false; generation++ })

  async function read(chat: Chat | null, thread: Thread | null = null) {
    const request = ++generation
    setBusy(true)
    setProblem(null)
    // Never leave another recipient's bodies or revoked data visible while reading.
    setThreads([])
    setSelected(null)
    setUpdated(null)
    try {
      if (!chat) {
        const result = await cmux.call<{ chats: Chat[] }>("agent_chat.list")
        if (!alive || request !== generation) return
        setChats(result.chats.filter((row) => !row.machine))
      } else {
        const params = { sessionId: chat.id, ...(thread ? { channel: thread.channel, thread: thread.thread } : {}) }
        const result = await cmux.call<Threads>("forum.threads", params)
        if (!alive || request !== generation) return
        setThreads(result.threads)
        setSelected(thread ? result.threads.find((row) => key(row) === key(thread)) ?? null : null)
        setUpdated(new Date().toLocaleTimeString())
      }
    } catch (e) {
      if (!alive || request !== generation) return
      setChats([])
      setProblem((e as { code?: string }).code === "scope.missing"
        ? "Allow Board to read work threads in Settings > Apps, then refresh."
        : "The forum is unavailable. Check access and the local service, then refresh.")
    } finally {
      if (alive && request === generation) setBusy(false)
    }
  }
  void read(null)

  function choose(chat: Chat) { setRecipient(chat); void read(chat) }
  function back() {
    if (selected()) { void read(recipient()); return }
    setRecipient(null)
    void read(null)
  }
  return VStack([
    HStack([
      Button("Back", back).disabled(() => !recipient() || busy()),
      Text(() => selected()?.thread ?? recipient()?.title ?? "Board").font("headline"),
      Button("Refresh", () => read(recipient(), selected())).disabled(busy)
    ]),
    Text(() => selected()?.channel ?? "Work threads").secondary(),
    () => busy() ? Text("Loading…").secondary() : null,
    () => problem() ? EmptyState({ title: "Board unavailable", message: problem()!, symbol: "lock" }) : null,
    () => !busy() && !problem() && !recipient() && chats().length === 0
      ? EmptyState({ title: "No local chats", message: "Open an agent chat on this machine to view its work threads.", symbol: "text.bubble" }) : null,
    ForEach({ items: () => recipient() ? [] : chats(), key: (chat) => chat.id }, (chat) =>
      Row({ title: () => chat().title, subtitle: () => chat().id, symbol: "text.bubble" }).onTap(() => choose(chat()))),
    () => !busy() && !problem() && recipient() && threads().length === 0
      ? EmptyState({ title: "No work threads yet", message: "Agent status, blockers and receipts will appear here.", symbol: "tray" }) : null,
    ForEach({ items: () => selected() ? [] : threads(), key }, (thread) =>
      Row({ title: () => thread().thread, subtitle: () => `${thread().channel} · ${thread().latest.kind}`, symbol: () => symbol(thread().latest.kind) })
        .onTap(() => read(recipient(), thread()))),
    () => selected()?.lease ? Text(`Claimed by ${selected()!.lease!.owner} · lease expires ${selected()!.lease!.expires}`).secondary() : null,
    ForEach({ items: () => selected() ? selected()!.posts ?? [selected()!.latest] : [], key: (post) => post.id }, (post) => VStack([
      Row({ title: () => post().kind, subtitle: () => String(post().created), symbol: () => symbol(post().kind) }),
      Text(() => post().body),
      Text(() => Object.keys(post().sources ?? {}).join(" · ")).secondary()
    ])),
    Text(() => updated() ? `Updated ${updated()}` : "").secondary()
  ])
}
