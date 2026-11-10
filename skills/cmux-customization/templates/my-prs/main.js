// Your open pull requests and the ones waiting for your review, in the sidebar. They stay in
// the order you keep: Move up, Move down and Move to top in a row's menu (kept with
// storage:local), new ones at the bottom. It reads GitHub through the connected account
// (integration:github:read, granted at install) once a minute, and again a few seconds after
// any agent chat changes, since that is when an agent opens or pushes a PR. A click opens the
// PR in a browser tab once actions:run is on in Settings > Apps > My views.

const [prs, setPRs] = signal(null) // [{ id, number, title, url, repo, draft, review }]
const [order, setOrder] = signal([]) // PR ids, as the person arranged them
const [error, setError] = signal(null)
let started = false

const message = (e) => (e instanceof Error ? e.message : String(e))

async function search(query) {
  const r = await cmux.integrations.github.request({ method: "GET", path: `/search/issues?q=${encodeURIComponent(query)}&per_page=30` })
  return r.items || []
}

// A burst of chat changes costs at most one search every 20 seconds (GitHub allows 30 a minute).
let reading = false
let last = 0
let queued = false
async function load() {
  if (reading || Date.now() - last < 20000) {
    if (!queued) {
      queued = true
      cmux.timer.after(20000, () => {
        queued = false
        load()
      })
    }
    return
  }
  reading = true
  last = Date.now()
  try {
    const [mine, reviews] = await Promise.all([search("is:pr is:open author:@me"), search("is:pr is:open review-requested:@me")])
    const row = (i, review) => ({
      id: i.id,
      number: i.number,
      title: i.title,
      url: i.html_url,
      repo: String(i.repository_url || "").replace("https://api.github.com/repos/", ""),
      draft: !!i.draft,
      review
    })
    setPRs([...mine.map((i) => row(i, false)), ...reviews.map((i) => row(i, true))])
    setError(null)
  } catch (e) {
    setError(message(e))
  } finally {
    reading = false
  }
}

// The person's order first, then PRs they have not placed yet, newest search hit first.
const arranged = computed(() => {
  const list = prs() || []
  const at = new Map(order().map((id, index) => [id, index]))
  const place = (p) => (at.has(p.id) ? at.get(p.id) : at.size)
  return [...list].sort((a, b) => place(a) - place(b))
})

function move(id, to) {
  const ids = arranged().map((p) => p.id)
  const from = ids.indexOf(id)
  if (from < 0) return
  const target = to === "top" ? 0 : Math.max(0, Math.min(ids.length - 1, from + to))
  ids.splice(from, 1)
  ids.splice(target, 0, id)
  setOrder(ids)
  cmux.storage.set("order", ids).catch(() => undefined)
}

function open(pr) {
  cmux.actions.run("openBrowser", { url: pr.url }).catch((e) =>
    cmux.toast({ title: "Turn on Run actions for My views to open PRs", message: message(e), tone: "warning" })
  )
}

function start() {
  if (started) return
  started = true
  cmux.storage.get("order").then((saved) => Array.isArray(saved) && setOrder(saved), () => undefined)
  load()
  cmux.timer.every(60000, load)
  cmux.events.on("agent_chat.changed", load)
}

function renderPRs() {
  start()
  return VStack({ spacing: 2 }, [
    ForEach({ items: arranged, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} ${p().number}`,
        symbol: () => (p().review ? "eye" : p().draft ? "circle.dashed" : "arrow.triangle.pull"),
        tint: () => (p().review ? cmux.theme.warning : p().draft ? cmux.theme.text.secondary : cmux.theme.success),
        badge: () => (p().review ? "Review" : undefined)
      })
        .help(() => p().url)
        .onTap(() => open(p()))
        .contextMenu(() => [
          Button("Open", () => open(p())),
          Divider(),
          Button("Move to top", () => move(p().id, "top")),
          Button("Move up", () => move(p().id, -1)),
          Button("Move down", () => move(p().id, 1)),
          Divider(),
          Button("Refresh", () => load())
        ])
    ),
    () => (error() ? EmptyState({ title: "Cannot read your pull requests", message: error(), symbol: "exclamationmark.triangle" }) : null),
    () => (!error() && prs() && prs().length === 0 ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null)
  ])
}

globalThis.__cmuxAppExports = { renderPRs }
