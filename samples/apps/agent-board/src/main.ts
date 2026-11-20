/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Presentation only. Threads, source deduplication and leases belong to acpmux.
interface Chat { id: string; title: string; machine?: string | null }
interface Post { id: string; kind: "status" | "blocker" | "receipt" | "warn"; body: string; created: number; sourceCount?: number; sources?: Record<string, unknown> }
interface Thread { channel: string; thread: string; latest: Post; posts?: Post[]; lease?: { owner: string; epoch: number; expires: number } | null }
interface Threads { recipient: string; threads: Thread[]; nextCursor?: string | null }
const symbol = (kind: string) => kind === "warn" || kind === "blocker" ? "exclamationmark.triangle" : kind === "receipt" ? "checkmark.circle" : "text.bubble"
const time = (milliseconds: number) => new Date(milliseconds).toLocaleString()
const key = (thread: Thread) => `${thread.channel}\u0000${thread.thread}`

// Pagination can split a post's source receipts across responses. Reassemble
// only the displayed page state; the owner decides post identity and ordering.
function appendPage(previous: Thread[], incoming: Thread[]): Thread[] {
  const rows = new Map(previous.map((thread) => [key(thread), thread]))
  for (const thread of incoming) {
    const before = rows.get(key(thread))
    const posts = new Map((before?.posts ?? []).map((post) => [post.id, post]))
    for (const post of thread.posts ?? []) {
      const prior = posts.get(post.id)
      const names = Object.fromEntries(Object.keys(post.sources ?? {}).map((name) => [name, null]))
      posts.set(post.id, { ...post, sources: { ...prior?.sources, ...names } })
    }
    rows.set(key(thread), { ...thread, ...(posts.size ? { posts: [...posts.values()] } : {}) })
  }
  return [...rows.values()]
}

export function renderPane() {
  const [chats, setChats] = signal<Chat[]>([])
  const [recipient, setRecipient] = signal<Chat | null>(null)
  const [threads, setThreads] = signal<Thread[]>([])
  const [selected, setSelected] = signal<Thread | null>(null)
  const [busy, setBusy] = signal(false)
  const [problem, setProblem] = signal<string | null>(null)
  const [nextCursor, setNextCursor] = signal<string | null>(null)
  const [updated, setUpdated] = signal<string | null>(null)
  let generation = 0
  let alive = true
  onCleanup(() => { alive = false; generation++ })

  async function read(chat: Chat | null, thread: Thread | null = null, cursor?: string) {
    const request = ++generation
    const previous = cursor ? threads() : []
    setBusy(true)
    setProblem(null)
    // Never leave another recipient's bodies or revoked data visible while reading.
    if (!cursor) {
      setThreads([])
      setSelected(null)
      setNextCursor(null)
      setUpdated(null)
    }
    try {
      if (!chat) {
        const result = await cmux.call<{ chats: Chat[] }>("agent_chat.list")
        if (!alive || request !== generation) return
        setChats(result.chats.filter((row) => !row.machine))
      } else {
        const params = { sessionId: chat.id, ...(thread ? { channel: thread.channel, thread: thread.thread } : {}), ...(cursor ? { cursor } : {}) }
        const result = await cmux.call<Threads>("forum.threads", params)
        if (!alive || request !== generation) return
        const rows = appendPage(previous, result.threads)
        setThreads(rows)
        setSelected(thread ? rows.find((row) => key(row) === key(thread)) ?? null : null)
        setNextCursor(result.nextCursor ?? null)
        setUpdated(new Date().toLocaleTimeString())
      }
    } catch (e) {
      if (!alive || request !== generation) return
      setChats([])
      setThreads([])
      setSelected(null)
      setNextCursor(null)
      setUpdated(null)
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
    () => selected()?.lease ? Text(`Lease owner ${selected()!.lease!.owner} · expires ${time(selected()!.lease!.expires)}`).secondary() : null,
    ForEach({ items: () => selected() ? selected()!.posts ?? [selected()!.latest] : [], key: (post) => post.id }, (post) => VStack([
      Row({ title: () => post().kind, subtitle: () => time(post().created), symbol: () => symbol(post().kind) }),
      Text(() => post().body),
      Text(() => {
        const names = Object.keys(post().sources ?? {})
        return `Sources ${names.length}/${post().sourceCount ?? names.length}: ${names.join(" · ")}`
      }).secondary()
    ])),
    () => nextCursor() ? Button("Load more", () => read(recipient(), selected(), nextCursor()!)).disabled(busy) : null,
    Text(() => updated() ? `Updated ${updated()}` : "").secondary()
  ])
}
