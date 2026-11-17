// The RFD reader's page. Three designs share it (body[data-variant]): directory (list beside the
// document, comments in the margin), index (a full-width table, then the document with comment
// markers that open a card) and focus (the document alone; Cmd-/ is the way around, comments
// under their paragraph). The chips in the bar switch them; the choice is kept.
import "./main.css"
import { call, CmuxCallError } from "cmux-extension-sdk/web"
import {
  blockForLine,
  byUpdated,
  jump,
  newFileUrl,
  newRfdText,
  nextNumber,
  pad,
  relTime,
  renderBlocks,
  rfdOfHref,
  search,
  threads,
  STATES,
  type Rfd,
  type RfdMeta,
  type Thread,
} from "./model"
import { DEFAULT_CONFIG, Source, type Host } from "./source"

const VARIANTS = [
  { id: "directory", label: "A", title: "Directory: the list beside the document, comments in the margin" },
  { id: "index", label: "B", title: "Index: a table first, comment markers that open a card" },
  { id: "focus", label: "C", title: "Focus: the document alone, comments under their paragraph" },
] as const
type Variant = (typeof VARIANTS)[number]["id"]

// ---- Host -------------------------------------------------------------------------------

const previewHost = (globalThis as { __RFD_PREVIEW_HOST__?: Host & { open(url: string): void } }).__RFD_PREVIEW_HOST__

const host: Host & { open(url: string): Promise<void> } = previewHost
  ? { ...previewHost, open: async (url) => previewHost.open(url) }
  : {
      get: <T>(path: string) => call<T>("integration.request", { provider: "github", method: "GET", path }),
      load: async <T>(key: string) => (await call<T | null>("app.storage.get", { key })) ?? null,
      save: async (key, value) => void (await call("app.storage.set", { key, value })),
      open: async (url) => void (await call("tab.create_browser", { url })),
    }

const source = new Source(host, DEFAULT_CONFIG)

// ---- State ------------------------------------------------------------------------------

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T
const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: Partial<HTMLElementTagNameMap[K]> & { class?: string } = {}, ...kids: (Node | string | null | false)[]) => {
  const { class: cls, ...rest } = props
  const node = Object.assign(document.createElement(tag), rest)
  if (cls) node.className = cls
  for (const k of kids) if (k) node.append(k)
  return node
}

let rfds: RfdMeta[] = []
let current: Rfd | null = null
let stateFilter = new Set<string>()
let textFilter = ""
let variant: Variant = "directory"
let openSeq = 0

function status(text: string, tone: "" | "warn" = "") {
  const s = $("status")
  s.textContent = text
  s.dataset.tone = tone
}

function explain(e: unknown): string {
  if (e instanceof CmuxCallError) {
    if (e.code === "validation.invalid") return "This cmux's GitHub gateway cannot read RFD files yet; it needs the gateway read paths change."
    if (e.code === "scope.missing") return "The RFD reader was not allowed to read GitHub. Allow it in Settings > Apps."
    if (/rate|quota/i.test(e.code + e.message)) return "GitHub's rate limit is spent for now; showing the copy kept from the last read."
    return e.message
  }
  return String(e)
}

// ---- List -------------------------------------------------------------------------------

const stateTone = (s: string) =>
  ({ published: "ok", committed: "ok", discussion: "accent", ideation: "warm", prediscussion: "muted", abandoned: "muted" })[s] ?? "muted"

const stateChip = (s: string) => el("span", { class: `state ${stateTone(s)}`, textContent: s })

function visible(): RfdMeta[] {
  const q = textFilter.trim()
  const base = q ? jump(rfds, q) : [...rfds].sort(byUpdated)
  return base.filter((r) => stateFilter.size === 0 || stateFilter.has(r.state))
}

function renderFilters() {
  const present = new Set(rfds.map((r) => r.state))
  const states = [...STATES.filter((s) => present.has(s)), ...[...present].filter((s) => !(STATES as readonly string[]).includes(s))]
  const box = $("filters")
  box.replaceChildren(
    el("button", { type: "button", class: `chip ${stateFilter.size === 0 ? "on" : ""}`, textContent: `All ${rfds.length}`, onclick: () => ((stateFilter = new Set()), renderList()) }),
    ...states.map((s) =>
      el("button", {
        type: "button",
        class: `chip ${stateFilter.has(s) ? "on" : ""}`,
        textContent: `${s} ${rfds.filter((r) => r.state === s).length}`,
        onclick: () => {
          stateFilter.has(s) ? stateFilter.delete(s) : stateFilter.add(s)
          renderList()
        },
      }),
    ),
  )
}

function renderList() {
  renderFilters()
  const rows = visible()
  const list = $("rows")
  if (rows.length === 0) {
    list.replaceChildren(el("li", { class: "empty", textContent: rfds.length ? "No RFD matches." : "No RFDs yet. Write the first with New RFD." }))
    return
  }
  list.replaceChildren(
    ...rows.map((r) => {
      const li = el(
        "li",
        { class: `row ${current?.number === r.number ? "selected" : ""}`, tabIndex: 0 },
        el("span", { class: "num", textContent: pad(r.number) }),
        el("span", { class: "rtitle", textContent: r.title }),
        stateChip(r.state),
        el("span", { class: "authors", textContent: r.authors.join(", ") }),
        el("time", { class: "when", textContent: relTime(r.pr?.updatedAt ?? r.updated), title: r.pr?.updatedAt ?? r.updated }),
        r.pr ? el("span", { class: "pr", textContent: `#${r.pr.number}`, title: "Discussed in this open pull request" }) : null,
      )
      li.dataset.rfd = String(r.number)
      li.onclick = () => void open(r.number)
      li.onkeydown = (e) => e.key === "Enter" && void open(r.number)
      return li
    }),
  )
}

// ---- Document ---------------------------------------------------------------------------

function renderDoc(rfd: Rfd) {
  const blocks = renderBlocks(rfd)
  const doc = $("doc")
  const head = el(
    "div",
    { class: "dochead" },
    el("div", { class: "docnum", textContent: `RFD ${pad(rfd.number)}` }),
    el("h1", { textContent: rfd.title }),
    el(
      "div",
      { class: "docmeta" },
      stateChip(rfd.state),
      el("span", { textContent: rfd.authors.join(", ") }),
      el("span", { class: "muted", textContent: `updated ${relTime(rfd.pr?.updatedAt ?? rfd.updated)}` }),
      rfd.pr ? linkButton(`Discussion #${rfd.pr.number}`, rfd.pr.url) : null,
      el("span", { id: "comment-count", class: "muted" }),
    ),
  )
  const body = el("div", { class: "prose blocks" })
  blocks.forEach((b, i) => {
    // The `# RFD N: Title` heading is already the page title.
    if (i === 0 && b.heading?.depth === 1) return
    const row = el("div", { class: "blk" })
    row.dataset.from = String(b.from)
    row.dataset.to = String(b.to)
    const content = el("div", { class: "content" })
    content.innerHTML = b.html
    if (b.id) content.firstElementChild?.setAttribute("id", b.id)
    row.append(content, el("aside", { class: "margin" }))
    body.append(row)
  })
  decorateLinks(body)
  doc.replaceChildren(head, body)
  doc.scrollTop = 0
}

function linkButton(text: string, url: string) {
  return el("a", { class: "extlink", href: url, textContent: text, onclick: (e: MouseEvent) => (e.preventDefault(), void host.open(url)) })
}

/** Links to other RFDs open here and preview on hover; other links open in a browser tab. */
function decorateLinks(root: HTMLElement) {
  for (const a of root.querySelectorAll<HTMLAnchorElement>("a[href]")) {
    const href = a.getAttribute("href") ?? ""
    const n = rfdOfHref(href)
    if (n !== null) {
      a.dataset.rfd = String(n)
      a.onclick = (e) => (e.preventDefault(), void open(n))
    } else if (href.startsWith("#")) {
      // in-page anchor
    } else {
      a.onclick = (e) => (e.preventDefault(), void host.open(new URL(href, `https://github.com/${source.config.repo}/blob/${source.config.branch}/${source.config.dir}/`).href))
    }
  }
  // `RFD 12` in plain text becomes a reference too.
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const hits: Text[] = []
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (/\bRFD[\s-]?\d{1,4}\b/i.test(n.nodeValue ?? "") && !(n.parentElement?.closest("a, code, pre, h1"))) hits.push(n as Text)
  }
  for (const t of hits) {
    const frag = document.createDocumentFragment()
    let last = 0
    const text = t.nodeValue ?? ""
    for (const m of text.matchAll(/\bRFD[\s-]?0*(\d{1,4})\b/gi)) {
      const n = Number(m[1])
      if (n === current?.number || !rfds.some((r) => r.number === n)) continue
      frag.append(text.slice(last, m.index), el("a", { href: "#", class: "rfdref", textContent: m[0], onclick: (e: MouseEvent) => (e.preventDefault(), void open(n)) }))
      ;(frag.lastChild as HTMLElement).dataset.rfd = String(n)
      last = m.index! + m[0].length
    }
    if (last > 0) {
      frag.append(text.slice(last))
      t.replaceWith(frag)
    }
  }
}

/** Review comments, read after the text is on screen, placed beside (or under) their lines. */
async function streamComments(rfd: Rfd, seq: number) {
  const count = () => document.getElementById("comment-count")
  try {
    const { pr, comments } = await source.comments(rfd)
    if (seq !== openSeq) return
    if (pr === null) return
    const ts = threads(comments, rfd.pr ? rfd.path : rfd.path)
    const c = count()
    if (c) c.textContent = ts.length ? `${ts.length} comment thread${ts.length === 1 ? "" : "s"} on lines` : "no line comments"
    const rows = [...document.querySelectorAll<HTMLElement>("#doc .blk")]
    const blocks = rows.map((r) => ({ from: Number(r.dataset.from), to: Number(r.dataset.to), html: "" }))
    for (const t of ts) {
      const row = rows[blockForLine(blocks, t.line)]
      if (!row) continue
      row.classList.add("has-comments")
      row.querySelector(".margin")!.append(threadView(t))
    }
  } catch (e) {
    if (seq === openSeq) {
      const c = count()
      if (c) c.textContent = "comments unavailable"
      status(explain(e), "warn")
    }
  }
}

function threadView(t: Thread) {
  const first = t.comments[0]
  const box = el(
    "details",
    { class: "thread", open: variant !== "index" },
    el(
      "summary",
      {},
      el("span", { class: "who", textContent: first.user?.login ?? "someone" }),
      el("span", { class: "muted", textContent: ` L${t.startLine === t.line ? t.line : `${t.startLine}–${t.line}`}` }),
      t.comments.length > 1 ? el("span", { class: "replies", textContent: ` +${t.comments.length - 1}` }) : null,
    ),
    ...t.comments.map((c) => el("div", { class: "comment" }, el("div", { class: "cby", textContent: `${c.user?.login ?? "someone"} · ${relTime(c.created_at)}` }), el("div", { class: "cbody", textContent: c.body }))),
    linkButton("Reply on GitHub", t.url),
  )
  return box
}

async function open(number: number) {
  const m = rfds.find((r) => r.number === number)
  if (!m) return
  const seq = ++openSeq
  hideHover()
  document.body.dataset.view = "doc"
  $("crumb").textContent = `RFD ${pad(m.number)}`
  try {
    const rfd = await source.rfd(m)
    if (seq !== openSeq) return
    current = rfd
    renderDoc(rfd)
    renderList()
    void host.save("last", number).catch(() => undefined)
    void streamComments(rfd, seq)
  } catch (e) {
    if (seq === openSeq) status(explain(e), "warn")
  }
}

function home() {
  openSeq++
  current = null
  document.body.dataset.view = "list"
  $("crumb").textContent = ""
  $("doc").replaceChildren(el("div", { class: "placeholder" }, el("p", { textContent: "Pick an RFD, or press ⌘/ to jump to one." })))
  renderList()
}

// ---- Hover previews ---------------------------------------------------------------------

let hoverTimer: ReturnType<typeof setTimeout> | undefined
function hideHover() {
  clearTimeout(hoverTimer)
  $("hovercard").hidden = true
}

document.addEventListener("mouseover", (e) => {
  const a = (e.target as HTMLElement).closest<HTMLElement>("#doc [data-rfd], #search-preview [data-rfd]")
  if (!a) return
  const r = rfds.find((x) => x.number === Number(a.dataset.rfd))
  if (!r) return
  clearTimeout(hoverTimer)
  hoverTimer = setTimeout(() => {
    const card = $("hovercard")
    card.replaceChildren(
      el("div", { class: "docnum", textContent: `RFD ${pad(r.number)}` }),
      el("div", { class: "htitle", textContent: r.title }),
      el("div", { class: "docmeta" }, stateChip(r.state), el("span", { textContent: r.authors.join(", ") })),
      el("div", { class: "muted", textContent: `updated ${relTime(r.pr?.updatedAt ?? r.updated)}` }),
    )
    const box = a.getBoundingClientRect()
    card.hidden = false
    card.style.left = `${Math.min(box.left, innerWidth - card.offsetWidth - 12)}px`
    card.style.top = `${box.bottom + 6 + card.offsetHeight > innerHeight ? box.top - card.offsetHeight - 6 : box.bottom + 6}px`
  }, 250)
})
document.addEventListener("mouseout", (e) => {
  if ((e.target as HTMLElement).closest?.("[data-rfd]")) hideHover()
})

// ---- Search (Cmd-K) and jump-to (Cmd-/) -------------------------------------------------

/** Keyboard selection over a result list: arrows move, Return opens. */
function listKeys(input: HTMLInputElement, list: HTMLOListElement, onPick: (n: number) => void, onMove?: (n: number) => void) {
  input.addEventListener("keydown", (e) => {
    const items = [...list.querySelectorAll<HTMLElement>("li[data-rfd]")]
    const at = items.findIndex((i) => i.classList.contains("active"))
    const move = (to: number) => {
      items.forEach((i) => i.classList.remove("active"))
      const it = items[Math.max(0, Math.min(items.length - 1, to))]
      if (!it) return
      it.classList.add("active")
      it.scrollIntoView({ block: "nearest" })
      onMove?.(Number(it.dataset.rfd))
    }
    if (e.key === "ArrowDown") (e.preventDefault(), move(at + 1))
    else if (e.key === "ArrowUp") (e.preventDefault(), move(at - 1))
    else if (e.key === "Enter" && items.length) (e.preventDefault(), onPick(Number(items[Math.max(0, at)].dataset.rfd)))
  })
}

const loaded = new Map<number, Rfd>()
async function allBodies(): Promise<Rfd[]> {
  await Promise.all(
    rfds.map(async (r) => {
      if (!loaded.has(r.number) || loaded.get(r.number)!.sha !== r.sha) loaded.set(r.number, await source.rfd(r))
    }),
  )
  return [...loaded.values()]
}

async function runSearch() {
  const q = $<HTMLInputElement>("search-input").value
  const list = $<HTMLOListElement>("search-results")
  const hits = search(await allBodies(), q)
  list.replaceChildren(
    ...hits.map((h, i) => {
      const r = rfds.find((x) => x.number === h.number)!
      const [pre, mid, post] = h.excerpt.split(/[«»]/)
      const li = el(
        "li",
        { class: i === 0 ? "active" : "" },
        el("div", {}, el("span", { class: "num", textContent: pad(r.number) }), " ", el("strong", { textContent: r.title }), " ", stateChip(r.state)),
        h.excerpt ? el("div", { class: "excerpt" }, pre ?? "", el("mark", { textContent: mid ?? "" }), post ?? "") : null,
      )
      li.dataset.rfd = String(r.number)
      li.onclick = () => pickSearch(r.number)
      li.onmouseenter = () => previewSearch(r.number)
      return li
    }),
  )
  if (!q.trim()) list.replaceChildren(el("li", { class: "empty", textContent: "Type to search the text of every RFD." }))
  else if (hits.length === 0) list.replaceChildren(el("li", { class: "empty", textContent: "Nothing matches." }))
  if (hits[0]) previewSearch(hits[0].number)
  else $("search-preview").replaceChildren()
}

function previewSearch(n: number) {
  const r = loaded.get(n)
  if (!r) return
  const q = $<HTMLInputElement>("search-input").value.trim().toLowerCase().split(/\s+/)[0]
  const blocks = renderBlocks(r)
  const hit = Math.max(0, blocks.findIndex((b) => q && b.html.toLowerCase().includes(q)))
  const box = $("search-preview")
  box.innerHTML = `<div class="docnum">RFD ${pad(r.number)}</div><h2>${r.title.replace(/</g, "&lt;")}</h2>` + blocks.slice(Math.max(1, hit - 1), hit + 4).map((b) => b.html).join("")
  decorateLinks(box)
}

function pickSearch(n: number) {
  $<HTMLDialogElement>("search-dialog").close()
  void open(n)
}

function runJump() {
  const q = $<HTMLInputElement>("jump-input").value
  const list = $<HTMLOListElement>("jump-results")
  const rows = jump([...rfds].sort(byUpdated), q).slice(0, 50)
  list.replaceChildren(
    ...rows.map((r, i) => {
      const li = el("li", { class: i === 0 ? "active" : "" }, el("span", { class: "num", textContent: pad(r.number) }), " ", el("span", { textContent: r.title }), " ", stateChip(r.state))
      li.dataset.rfd = String(r.number)
      li.onclick = () => pickJump(r.number)
      return li
    }),
  )
  if (rows.length === 0) list.replaceChildren(el("li", { class: "empty", textContent: "No RFD has that number or title." }))
}

function pickJump(n: number) {
  $<HTMLDialogElement>("jump-dialog").close()
  void open(n)
}

function showSearch() {
  $<HTMLDialogElement>("jump-dialog").close()
  const d = $<HTMLDialogElement>("search-dialog")
  if (!d.open) d.showModal()
  $<HTMLInputElement>("search-input").select()
  void runSearch()
}

function showJump() {
  $<HTMLDialogElement>("search-dialog").close()
  const d = $<HTMLDialogElement>("jump-dialog")
  if (!d.open) d.showModal()
  const input = $<HTMLInputElement>("jump-input")
  input.value = ""
  input.focus()
  runJump()
}

// ---- New RFD ----------------------------------------------------------------------------

async function showNew() {
  const n = nextNumber(rfds)
  $("new-number").textContent = pad(n)
  const authors = $<HTMLInputElement>("new-authors")
  if (!authors.value) authors.value = await source.login().catch(() => "")
  $<HTMLDialogElement>("new-dialog").showModal()
  $("new-title").focus()
}

$<HTMLDialogElement>("new-dialog").addEventListener("close", () => {
  const d = $<HTMLDialogElement>("new-dialog")
  if (d.returnValue !== "ok") return
  const title = $<HTMLInputElement>("new-title").value.trim()
  if (!title) return
  const number = nextNumber(rfds)
  const text = newRfdText({
    number,
    title,
    state: $<HTMLSelectElement>("new-state").value,
    authors: $<HTMLInputElement>("new-authors").value.split(",").map((s) => s.trim()).filter(Boolean),
    body: $<HTMLTextAreaElement>("new-body").value,
    today: new Date().toISOString().slice(0, 10),
  })
  const { repo, branch, dir } = source.config
  void host.open(newFileUrl(repo, branch, dir, number, title, text))
  status(`RFD ${pad(number)} is open on GitHub: commit it on a new branch to open its pull request.`)
})

// ---- Variants ---------------------------------------------------------------------------

function setVariant(v: Variant, save = true) {
  variant = v
  document.body.dataset.variant = v
  for (const b of $("variants").querySelectorAll<HTMLButtonElement>("button")) b.setAttribute("aria-checked", String(b.dataset.v === v))
  for (const d of document.querySelectorAll<HTMLDetailsElement>("#doc .thread")) d.open = v !== "index"
  if (save) void host.save("variant", v).catch(() => undefined)
}

$("variants").append(
  ...VARIANTS.map((v) => {
    const b = el("button", { type: "button", textContent: v.label, title: v.title, onclick: () => setVariant(v.id) })
    b.dataset.v = v.id
    b.setAttribute("role", "radio")
    return b
  }),
)

// ---- Keys and wiring --------------------------------------------------------------------

document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey
  if (mod && e.key === "/") (e.preventDefault(), showJump())
  else if (mod && e.key.toLowerCase() === "k") (e.preventDefault(), showSearch())
  else if (e.key === "Escape" && !document.querySelector("dialog[open]") && document.body.dataset.view === "doc") home()
})

$("open-search").onclick = showSearch
$("open-jump").onclick = showJump
$("new").onclick = () => void showNew()
$("home").onclick = home
$("filter").addEventListener("input", (e) => ((textFilter = (e.target as HTMLInputElement).value), renderList()))
$("search-input").addEventListener("input", () => void runSearch())
$("jump-input").addEventListener("input", runJump)
listKeys($("search-input"), $("search-results"), pickSearch, previewSearch)
listKeys($("jump-input"), $("jump-results"), pickJump)

/** Read the list: the kept copy first (instant), then GitHub (cheap when nothing changed). */
async function refresh(first: boolean) {
  if (first) {
    rfds = await source.cachedIndex().catch(() => [])
    if (rfds.length) renderList()
  }
  status(`Reading ${source.config.repo}/${source.config.dir}…`)
  try {
    const { rfds: fresh, missingFolder } = await source.index()
    rfds = fresh
    renderList()
    status(missingFolder && rfds.length === 0 ? `${source.config.dir} is not on ${source.config.branch} yet; RFDs in open pull requests show here.` : `${rfds.length} RFDs · read ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`)
    if (current) {
      const now = rfds.find((r) => r.number === current!.number)
      if (now && now.sha !== current.sha) void open(now.number)
    }
  } catch (e) {
    status(explain(e), "warn")
  }
}

const refreshButton = el("button", { type: "button", class: "ghost", textContent: "Refresh", title: "Read GitHub again", onclick: () => void refresh(false) })
$("status").before(refreshButton)
refreshButton.id = "refresh"

void (async () => {
  setVariant(((await host.load<Variant>("variant").catch(() => null)) ?? "directory") as Variant, false)
  home()
  await refresh(true)
  const params = new URLSearchParams(location.search)
  const want = Number(params.get("rfd") ?? (await host.load<number>("last").catch(() => null)) ?? NaN)
  // The index design opens on its table; the others open the last RFD read, else the newest.
  const tableFirst = (variant as Variant) === "index"
  if (!tableFirst && Number.isFinite(want) && rfds.some((r) => r.number === want)) void open(want)
  else if (!tableFirst && rfds.length) void open([...rfds].sort(byUpdated)[0].number)
})()
