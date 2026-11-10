// A New Tab widget (cmux.newtab.widget/1): drawn under the New Tab composer, one card per app.
// A classic script: the scene globals (VStack, HStack, Row, Text, ForEach, EmptyState, signal,
// computed, cmux) are already defined. cmux reloads this file every time it is saved.

const [now, setNow] = signal(new Date())
const [prs, setPrs] = signal(null)
const [error, setError] = signal("")

const repoOf = (url) => String(url || "").replace("https://api.github.com/repos/", "")

async function loadPrs() {
  try {
    const r = await cmux.integrations.github.request({ method: "GET", path: `/search/issues?q=${encodeURIComponent("is:open is:pr author:@me")}&sort=updated&per_page=5` })
    setPrs((r.items || []).map((i) => ({ id: i.id, title: i.title, url: i.html_url, repo: repoOf(i.repository_url), number: i.number })))
    setError("")
  } catch (e) {
    setError(String((e && e.message) || e))
  }
}

function renderNewTab() {
  // The clock ticks each half minute; pull requests are read again every two minutes, close
  // enough to live for a page you glance at.
  cmux.timer.every(30 * 1000, () => setNow(new Date()))
  cmux.timer.every(2 * 60 * 1000, loadPrs)
  loadPrs()
  return VStack({ spacing: 4 }, [
    Text(() => now().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })).font("title"),
    ForEach({ items: computed(() => prs() || []), key: (p) => p.id }, (p) =>
      Row({ title: () => p().title, subtitle: () => `${p().repo} #${p().number}`, symbol: "arrow.triangle.pull" })
        .help(() => p().url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().url }))
    ),
    () => (error() ? EmptyState({ title: "Cannot load pull requests", message: error(), symbol: "exclamationmark.triangle" }) : null),
    () => (!error() && prs() && prs().length === 0 ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null)
  ])
}

globalThis.__cmuxAppExports = { renderNewTab }
