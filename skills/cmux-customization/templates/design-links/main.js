// Your Figma files (and any other design or doc links) in the sidebar. Paste a link and press
// Return; a click opens it in a cmux browser tab, so the design sits in a split beside the
// code. Figma, FigJam, Linear, Notion and Google Docs links get their own symbol and a name
// from the link. The list is kept with storage:local; opening needs actions:run, both in
// Settings > Apps > My views.

const [links, setLinks] = signal([]) // [{ id, url, title }]
const [draft, setDraft] = signal("")
let loaded = false

const message = (e) => (e instanceof Error ? e.message : String(e))

function kind(url) {
  if (/figma\.com\/(board|figjam)\//.test(url)) return { symbol: "rectangle.on.rectangle", label: "FigJam" }
  if (/figma\.com\//.test(url)) return { symbol: "paintbrush", label: "Figma" }
  if (/linear\.app\//.test(url)) return { symbol: "checklist", label: "Linear" }
  if (/notion\.(so|site)\//.test(url)) return { symbol: "doc.text", label: "Notion" }
  if (/docs\.google\.com\//.test(url)) return { symbol: "doc.richtext", label: "Google Docs" }
  return { symbol: "link", label: "Link" }
}

// A Figma link reads figma.com/design/<key>/<File-Name>?node-id=...: the name is its third part.
// Any other link is named by its last part that reads as words (not an id or "edit").
function titleOf(url) {
  const [host, ...parts] = url.replace(/^https:\/\//, "").split(/[?\x23]/)[0].split("/").filter(Boolean)
  const wordy = parts.filter((p) => /[a-z].*[-_ ]|^[A-Za-z]+$/.test(p) && !/^(edit|view|d|document|spreadsheets|presentation)$/.test(p))
  const name = /figma\.com$/.test(host) && parts.length >= 3 ? parts[2] : wordy[wordy.length - 1] || host
  try {
    return decodeURIComponent(name).replace(/[-_]+/g, " ").trim()
  } catch (e) {
    return name
  }
}

function load() {
  if (loaded) return
  loaded = true
  cmux.storage.get("links").then(
    (saved) => {
      if (!Array.isArray(saved)) return
      const added = links().filter((x) => !saved.some((s) => s.id === x.id))
      added.length ? save([...saved, ...added]) : setLinks(saved)
    },
    () => undefined
  )
}

// Writes run one after another: the host may finish two calls in any order, and an older list
// landing last would drop the newer link.
let writing = Promise.resolve()
function save(next) {
  setLinks(next)
  writing = writing.then(() => cmux.storage.set("links", next)).catch(() => undefined)
}

function add(text) {
  const url = String(text || "").trim()
  if (!/^https:\/\//.test(url)) {
    cmux.toast({ title: "Paste a link that starts with https://", tone: "warning" })
    return
  }
  save([...links(), { id: `${Date.now()}-${links().length}`, url, title: titleOf(url) }])
  setDraft("")
}

function open(link) {
  cmux.actions.run("openBrowser", { url: link.url }).catch((e) =>
    cmux.toast({ title: "Turn on Run actions for My views to open links", message: message(e), tone: "warning" })
  )
}

function renderLinks() {
  load()
  return VStack({ spacing: 2 }, [
    ForEach({ items: links, key: (l) => l.id }, (l) =>
      Row({ title: () => l().title, subtitle: () => kind(l().url).label, symbol: () => kind(l().url).symbol })
        .help(() => l().url)
        .onTap(() => open(l()))
        .contextMenu(() => [Button("Open", () => open(l())), Divider(), Button("Remove", () => save(links().filter((x) => x.id !== l().id)))])
    ),
    TextField(draft, { placeholder: "Paste a Figma link and press Return", onEdit: setDraft, onSubmit: add })
  ])
}

globalThis.__cmuxAppExports = { renderLinks }
