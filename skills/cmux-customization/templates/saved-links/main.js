// Keep your actual dashboard links beside the workspace; open them as browser tabs.
const [links, setLinks] = signal([])
const [draft, setDraft] = signal("")
const [notice, setNotice] = signal(null)
const [ready, setReady] = signal(false)
let loading = false
let writing = Promise.resolve()
const valid = (url) => typeof url === "string" && /^https:\/\/[^\s/]+(?:\/[^\s]*)?$/.test(url)
function load() {
  if (loading || ready()) return
  loading = true
  cmux.storage.get("showcase.links").then((saved) => {
    setLinks(Array.isArray(saved) ? [...new Set(saved.filter(valid))] : [])
    setReady(true); setNotice(null); loading = false
  }, (error) => { loading = false; setNotice(`Cannot read saved links: ${String(error)}`) })
}
function save(next) {
  setLinks(next)
  writing = writing.then(() => cmux.storage.set("showcase.links", next))
    .then(() => setNotice(null)).catch((error) => setNotice(`Not saved: ${String(error)}`))
}
function add(text) {
  const url = String(text || "").trim()
  if (!valid(url)) return setNotice("Paste a complete https:// link.")
  if (!links().includes(url)) save([...links(), url])
  setDraft("")
}
function renderSavedLinks() {
  load()
  return VStack([
    ForEach({ items: links, key: (url) => url }, (url) => Row({ title: url, symbol: "link" })
      .onTap(() => cmux.actions.run("openBrowser", { url: url() }).catch((error) => setNotice(String(error))))
      .contextMenu([Button("Remove", () => save(links().filter((item) => item !== url())))])),
    () => ready() ? TextField(draft, { placeholder: "Paste a dashboard link", onEdit: setDraft, onSubmit: add }) : Text("Reading saved links…"),
    () => notice() ? VStack({ spacing: 1 }, [EmptyState({ title: "Links", message: notice() }), !ready() ? Button("Retry", () => { setNotice(null); load() }) : null]) : null
  ])
}

globalThis.__cmuxAppExports = { renderSavedLinks }
