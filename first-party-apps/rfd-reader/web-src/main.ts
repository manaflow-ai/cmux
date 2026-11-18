// The RFD reader's page. Three designs share it (body[data-variant]): directory (list beside the
// document, comments in the margin), index (a full-width table, then the document with comment
// markers that open a card) and focus (the document alone; Cmd-/ is the way around, comments
// under their paragraph). The chips in the bar switch them; the choice is kept.
// Two kinds of document share the designs: RFDs (docs/rfd/) and reading notes (docs/reading/),
// one tab each in the bar; search, jump-to and hover previews cover both.
import "./main.css"
import { call, CmuxCallError } from "cmux-extension-sdk/web"
import {
  blockForLine,
  byRead,
  byUpdated,
  hostOf,
  jump,
  jumpNotes,
  linkKind,
  newNoteFileUrl,
  newNoteText,
  noteFileName,
  noteIndexRow,
  noteOfHref,
  noteTemplateBody,
  templateBody,
  toc,
  newFileUrl,
  newRfdText,
  nextNumber,
  pad,
  relTime,
  renderBlocks,
  openableUrl,
  rfdOfHref,
  search,
  searchNotes,
  tagCounts,
  threads,
  NOTE_STATES,
  STATES,
  type Block,
  type Note,
  type NoteMeta,
  type ReviewComment,
  type Rfd,
  type RfdMeta,
  type Thread,
} from "./model"
import { DEFAULT_CONFIG, NOTES_DIR, NoteSource, Source, type Host } from "./source"

const VARIANTS = [
  { id: "directory", label: "A", title: "Directory: the list beside the document, comments in the margin" },
  { id: "index", label: "B", title: "Index: a table first, comment markers that open a card" },
  { id: "focus", label: "C", title: "Focus: the document alone, comments under their paragraph" },
] as const
type Variant = (typeof VARIANTS)[number]["id"]

// ---- Host -------------------------------------------------------------------------------

const previewHost = (globalThis as { __RFD_PREVIEW_HOST__?: Host & { open(url: string): void } }).__RFD_PREVIEW_HOST__

const rawHost: Host & { open(url: string): Promise<void> } = previewHost
  ? { ...previewHost, open: async (url) => previewHost.open(url) }
  : {
      get: <T>(path: string) => call<T>("integration.request", { provider: "github", method: "GET", path }),
      load: async <T>(key: string) => (await call<T | null>("app.storage.get", { key })) ?? null,
      save: async (key, value) => void (await call("app.storage.set", { key, value })),
      open: async (url) => void (await call("tab.create_browser", { url })),
    }

// Every browser tab the reader opens goes through here: only http(s) URLs, whatever a file says.
const host: typeof rawHost = {
  ...rawHost,
  open: async (url) => {
    const safe = openableUrl(url, "https://github.com/")
    if (safe) await rawHost.open(safe)
  },
}

const source = new Source(host, DEFAULT_CONFIG)
const noteSource = new NoteSource(host, DEFAULT_CONFIG)

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
/** RFD 0000, the template: not listed; its body is a new RFD's skeleton. */
let template: RfdMeta | null = null
const setIndex = (all: RfdMeta[]) => {
  template = all.find((r) => r.number === 0) ?? null
  rfds = all.filter((r) => r.number > 0)
}
let current: Rfd | null = null
let stateFilter = new Set<string>()
let textFilter = ""
let variant: Variant = "directory"
let openSeq = 0

/** Which list shows: the RFDs or the reading notes (a tab each in the bar; kept per person). */
type Section = "rfds" | "reading"
let section: Section = "rfds"
let notes: NoteMeta[] = []
let currentNote: Note | null = null
let noteStateFilter = new Set<string>()
let tagFilter = new Set<string>()

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
  renderSections()
  if (layout !== "tabs") return renderCombined()
  if (section === "reading") return renderNoteList()
  $("tags").replaceChildren()
  renderFilters()
  const rows = visible()
  const list = $("rows")
  if (rows.length === 0) {
    list.replaceChildren(el("li", { class: "empty", textContent: rfds.length ? "No RFD matches." : "No RFDs yet. Write the first with New RFD." }))
    return
  }
  list.replaceChildren(...rows.map(rfdRow))
}

function rfdRow(r: RfdMeta) {
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
}

// ---- Reading notes list -----------------------------------------------------------------

const noteTone = (s: string) => ({ adopted: "ok", acting: "accent", read: "warm", rejected: "muted", stale: "muted" })[s] ?? "muted"
const noteChip = (s: string) => el("span", { class: `state ${noteTone(s)}`, textContent: s })
/** Where a note came from, for its row: the author's organization (or name) and the source's host. */
const noteFrom = (n: NoteMeta) => [/\(([^)]+)\)\s*$/.exec(n.sourceAuthor)?.[1] ?? n.sourceAuthor, hostOf(n.source)].filter(Boolean).join(" · ")

function visibleNotes(): NoteMeta[] {
  const q = textFilter.trim()
  const base = q ? jumpNotes([...notes].sort(byRead), q) : [...notes].sort(byRead)
  return base.filter((n) => (noteStateFilter.size === 0 || noteStateFilter.has(n.state)) && [...tagFilter].every((t) => n.tags.includes(t)))
}

function renderNoteFilters() {
  const present = new Set(notes.map((n) => n.state))
  const states = [...NOTE_STATES.filter((s) => present.has(s)), ...[...present].filter((s) => !(NOTE_STATES as readonly string[]).includes(s))]
  $("filters").replaceChildren(
    el("button", { type: "button", class: `chip ${noteStateFilter.size === 0 ? "on" : ""}`, textContent: `All ${notes.length}`, onclick: () => ((noteStateFilter = new Set()), renderList()) }),
    ...states.map((s) =>
      el("button", {
        type: "button",
        class: `chip ${noteStateFilter.has(s) ? "on" : ""}`,
        textContent: `${s} ${notes.filter((n) => n.state === s).length}`,
        onclick: () => {
          noteStateFilter.has(s) ? noteStateFilter.delete(s) : noteStateFilter.add(s)
          renderList()
        },
      }),
    ),
  )
  // Tags narrow the list together: a note shows when it carries every tag picked.
  // The most used tags show; the rest behind "+N", so the list keeps its room.
  const all = tagCounts(notes)
  const shown = allTags ? all : all.filter(([t], i) => i < TAGS_SHOWN || tagFilter.has(t))
  $("tags").replaceChildren(
    ...shown.map(([t, c]) =>
      el("button", {
        type: "button",
        class: `chip tag ${tagFilter.has(t) ? "on" : ""}`,
        textContent: `#${t} ${c}`,
        title: `Notes tagged ${t}`,
        onclick: () => toggleTag(t),
      }),
    ),
    ...(all.length > shown.length || allTags
      ? [el("button", { type: "button", class: "chip tag more", textContent: allTags ? "fewer" : `+${all.length - shown.length}`, onclick: () => ((allTags = !allTags), renderList()) })]
      : []),
  )
}

const TAGS_SHOWN = 8
let allTags = false

function toggleTag(t: string) {
  tagFilter.has(t) ? tagFilter.delete(t) : tagFilter.add(t)
  renderList()
}

function noteRow(n: NoteMeta) {
  const li = el(
    "li",
    { class: `row note ${currentNote?.id === n.id ? "selected" : ""}`, tabIndex: 0 },
    el("span", { class: "num", textContent: n.read.slice(5), title: `Read ${n.read}` }),
    el("span", { class: "rtitle", textContent: n.title }),
    noteChip(n.state),
    el("span", { class: "authors", textContent: noteFrom(n) }),
    el("span", { class: "when tagline", textContent: n.tags.slice(0, 3).map((t) => `#${t}`).join(" "), title: n.tags.join(", ") }),
    n.pr ? el("span", { class: "pr", textContent: `#${n.pr.number}`, title: "Added or changed in this open pull request" }) : null,
  )
  li.dataset.note = n.id
  li.onclick = () => void openNote(n.id)
  li.onkeydown = (e) => e.key === "Enter" && void openNote(n.id)
  return li
}

function renderNoteList() {
  renderNoteFilters()
  const rows = visibleNotes()
  const list = $("rows")
  if (rows.length === 0) {
    list.replaceChildren(el("li", { class: "empty", textContent: notes.length ? "No reading note matches." : "No reading notes yet. Write the first with New reading note." }))
    return
  }
  list.replaceChildren(...rows.map(noteRow))
}

// ---- Placement of the notes (gallery variants) --------------------------------------------
// tabs (shipped): RFDs and Reading as two tabs in the bar, one list at a time.
// sections: both in one list, RFDs then a "Reading notes" heading.
// mixed: one list of both, newest first, a kind label per row.
// The preview picks one with ?notes=tabs|sections|mixed; the pane always uses tabs.

type Layout = "tabs" | "sections" | "mixed"
const layout: Layout = (["sections", "mixed"].includes(new URLSearchParams(location.search).get("notes") ?? "") && previewHost ? new URLSearchParams(location.search).get("notes") : "tabs") as Layout

function renderSections() {
  const box = $("sections")
  box.hidden = layout !== "tabs"
  box.replaceChildren(
    ...(
      [
        ["rfds", "RFDs", rfds.length],
        ["reading", "Reading", notes.length],
      ] as const
    ).map(([id, label, n]) => {
      const b = el("button", { type: "button", role: "tab", onclick: () => setSection(id) }, label, el("span", { class: "count", textContent: String(n) }))
      b.setAttribute("aria-selected", String(section === id))
      return b
    }),
  )
  $("new").textContent = layout === "tabs" && section === "reading" ? "New reading note" : "New RFD"
  $<HTMLInputElement>("filter").placeholder = layout === "tabs" && section === "reading" ? "Filter by title, date or tag" : "Filter by title or number"
}

function setSection(s: Section, save = true) {
  // The open tab again: back to its list, as the title did.
  if (s === section) return home()
  section = s
  textFilter = ""
  $<HTMLInputElement>("filter").value = ""
  document.body.dataset.section = s
  if (save) void host.save("section", s).catch(() => undefined)
  if (document.body.dataset.view === "doc" && variant !== "index") {
    // The other tab opens on its newest (or last read) document, so the pane never shows a stale one.
    if (s === "reading" && notes.length) return void openNote(lastNote && notes.some((n) => n.id === lastNote) ? lastNote : [...notes].sort(byRead)[0].id)
    if (s === "rfds" && rfds.length) return void open(lastRfd !== null && rfds.some((r) => r.number === lastRfd) ? lastRfd : [...rfds].sort(byUpdated)[0].number)
  }
  home()
}

function renderCombined() {
  renderFilters()
  renderNoteFilters2()
  const list = $("rows")
  const r = visible()
  const n = visibleNotes()
  if (layout === "sections") {
    list.replaceChildren(
      el("li", { class: "group", textContent: `RFDs · ${r.length}` }),
      ...r.map(rfdRow),
      el("li", { class: "group", textContent: `Reading notes · ${n.length}` }),
      ...n.map(noteRow),
    )
    return
  }
  const when = (x: { kind: "rfd"; m: RfdMeta } | { kind: "note"; m: NoteMeta }) => (x.kind === "rfd" ? (x.m.pr?.updatedAt ?? x.m.updated) : x.m.read).slice(0, 10)
  const all = [...r.map((m) => ({ kind: "rfd" as const, m })), ...n.map((m) => ({ kind: "note" as const, m }))].sort((a, b) => when(b).localeCompare(when(a)))
  list.replaceChildren(
    ...all.map((x) => {
      const li = x.kind === "rfd" ? rfdRow(x.m) : noteRow(x.m)
      li.prepend(el("span", { class: `kind ${x.kind}`, textContent: x.kind === "rfd" ? "RFD" : "Note" }))
      return li
    }),
  )
}

/** In the combined layouts the tag chips sit under the RFD state chips. */
function renderNoteFilters2() {
  $("tags").replaceChildren(
    ...tagCounts(notes).map(([t, c]) => el("button", { type: "button", class: `chip tag ${tagFilter.has(t) ? "on" : ""}`, textContent: `#${t} ${c}`, onclick: () => toggleTag(t) })),
  )
}

// ---- Document ---------------------------------------------------------------------------

function renderDoc(rfd: Rfd) {
  const blocks = renderBlocks(rfd)
  const doc = $("doc")
  // The header: state badge and title, then the fields (state, number, authors, updated,
  // access) and the links (the discussion PR, a recording, other RFDs, anything else).
  const field = (label: string, ...value: (Node | string | null)[]) => el("div", { class: "field" }, el("dt", { textContent: label }), el("dd", {}, ...value))
  const updated = rfd.pr?.updatedAt ?? rfd.updated
  const links = rfd.links.map((url) => ({ url, ...linkKind(url) }))
  if (rfd.pr && !links.some((l) => l.kind === "discussion" && l.url.endsWith(`/pull/${rfd.pr!.number}`))) links.unshift({ url: rfd.pr.url, kind: "discussion", label: `Discussion #${rfd.pr.number}` })
  const head = el(
    "div",
    { class: "dochead" },
    el("div", { class: "docnum" }, stateChip(rfd.state), ` RFD ${pad(rfd.number)}`),
    el("h1", { textContent: rfd.title }),
    el(
      "dl",
      { class: "fields" },
      field("State", rfd.state),
      field("RFD", String(rfd.number)),
      field("Authors", rfd.authors.join(", ") || "—"),
      field("Updated", el("time", { textContent: updated ? `${updated.slice(0, 10)} (${relTime(updated)})` : "—", title: updated })),
      field("Access", el("span", { class: "access", textContent: rfd.access || "not stated" })),
    ),
    links.length
      ? el(
          "div",
          { class: "links" },
          ...links.map((l) => {
            if (l.kind === "rfd") {
              const a = el("a", { href: l.url, class: "extlink", textContent: l.label })
              return a
            }
            const a = linkButton(l.label, /^https?:/.test(l.url) ? l.url : `https://github.com/${source.config.repo}/blob/${source.config.branch}/${source.config.dir}/${l.url}`)
            a.classList.add(`link-${l.kind}`)
            return a
          }),
        )
      : null,
    el("div", { class: "docmeta" }, el("span", { id: "comment-count", class: "muted" })),
  )
  decorateLinks(head)
  doc.replaceChildren(head, docBody(blocks, source.config.dir))
  doc.scrollTop = 0
}

/** The contents and the body blocks (each with a margin for its comments), links decorated. */
function docBody(blocks: Block[], dir: string) {
  const contents = toc(blocks)
  const nav = contents.length
    ? el(
        "nav",
        { class: "toc" },
        el("div", { class: "toc-title", textContent: "Contents" }),
        el(
          "ol",
          {},
          ...contents.map((c) => {
            const a = el("a", { href: `#${c.id}`, textContent: c.text, onclick: (e: MouseEvent) => (e.preventDefault(), document.getElementById(c.id)?.scrollIntoView({ block: "start" })) })
            return el("li", { class: `d${c.depth}` }, a)
          }),
        ),
      )
    : null
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
  decorateLinks(body, dir)
  return el("div", { class: "docbody" }, nav, body)
}

function renderNoteDoc(n: Note) {
  const blocks = renderBlocks(n)
  const field = (label: string, ...value: (Node | string | null)[]) => el("div", { class: "field" }, el("dt", { textContent: label }), el("dd", {}, ...value))
  const links = n.links.map((url) => ({ url, ...linkKind(url) }))
  if (n.pr && !links.some((l) => l.kind === "discussion" && l.url.endsWith(`/pull/${n.pr!.number}`))) links.unshift({ url: n.pr.url, kind: "discussion", label: `Discussion #${n.pr.number}` })
  const sourceUrl = openableUrl(n.source, "https://github.com/")
  const head = el(
    "div",
    { class: "dochead" },
    el("div", { class: "docnum" }, noteChip(n.state), ` Reading note · read ${n.read}`),
    el("h1", { textContent: n.title }),
    sourceUrl
      ? el(
          "div",
          { class: "source" },
          el("a", { class: "extlink source-link", href: sourceUrl, textContent: `Open the source ↗`, title: sourceUrl, onclick: (e: MouseEvent) => (e.preventDefault(), void host.open(sourceUrl)) }),
          el("span", { class: "muted", textContent: ` ${hostOf(sourceUrl)}` }),
        )
      : null,
    el(
      "dl",
      { class: "fields" },
      field("State", n.state),
      field("Source by", n.sourceAuthor || "—"),
      field("Published", n.published || "—"),
      field("Read", el("time", { textContent: `${n.read} (${relTime(n.read)})`, title: n.read })),
      field("Read by", n.readBy || "—"),
      field("Shared by", n.sharedBy || "—"),
      field("Access", el("span", { class: "access", textContent: n.access || "not stated" })),
    ),
    n.ask ? el("blockquote", { class: "ask" }, el("span", { class: "muted", textContent: `${n.sharedBy || "Shared"}: ` }), n.ask) : null,
    n.tags.length
      ? el(
          "div",
          { class: "tags" },
          ...n.tags.map((t) => el("button", { type: "button", class: `chip tag ${tagFilter.has(t) ? "on" : ""}`, textContent: `#${t}`, title: `List the notes tagged ${t}`, onclick: () => toggleTag(t) })),
        )
      : null,
    links.length
      ? el(
          "div",
          { class: "links" },
          ...links.map((l) => {
            if (l.kind === "rfd" || l.kind === "note") return el("a", { href: l.url, class: "extlink", textContent: l.label })
            const a = linkButton(l.label, /^https?:/.test(l.url) ? l.url : `https://github.com/${source.config.repo}/blob/${source.config.branch}/${NOTES_DIR}/${l.url}`)
            a.classList.add(`link-${l.kind}`)
            return a
          }),
        )
      : null,
    n.pr && n.indexed === false
      ? el(
          "div",
          { class: "notice" },
          `Pull request #${n.pr.number} does not add this note's row to the index (README.md) yet. `,
          el("button", { type: "button", textContent: "Add its index row", onclick: () => void showIndexRow(n) }),
        )
      : null,
    el("div", { class: "docmeta" }, el("span", { id: "comment-count", class: "muted" })),
  )
  decorateLinks(head, NOTES_DIR)
  $("doc").replaceChildren(head, docBody(blocks, NOTES_DIR))
  $("doc").scrollTop = 0
}

function linkButton(text: string, url: string) {
  return el("a", { class: "extlink", href: url, textContent: text, onclick: (e: MouseEvent) => (e.preventDefault(), void host.open(url)) })
}

/**
 * Links to other RFDs and to reading notes open here and preview on hover; other links open in a
 * browser tab. Relative links resolve against `dir`, the folder of the document they are in.
 */
function decorateLinks(root: HTMLElement, dir = source.config.dir) {
  for (const a of root.querySelectorAll<HTMLAnchorElement>("a[href]")) {
    const href = a.getAttribute("href") ?? ""
    const n = rfdOfHref(href)
    const note = noteOfHref(href)
    if (note !== null && notes.some((x) => x.id === note)) {
      a.dataset.note = note
      a.onclick = (e) => (e.preventDefault(), void openNote(note))
    } else if (n !== null) {
      a.dataset.rfd = String(n)
      a.onclick = (e) => (e.preventDefault(), void open(n))
    } else if (href.startsWith("#")) {
      // in-page anchor
    } else {
      const url = openableUrl(href, `https://github.com/${source.config.repo}/blob/${source.config.branch}/${dir}/`)
      if (url) a.onclick = (e) => (e.preventDefault(), void host.open(url))
      else a.removeAttribute("href")
    }
  }
  // `RFD 12` in plain text becomes a reference too.
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const hits: Text[] = []
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (/\bRFD[\s-]?\d{1,4}\b/i.test(n.nodeValue ?? "") && !(n.parentElement?.closest("a, code, pre, h1, h2, .docnum"))) hits.push(n as Text)
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
async function streamComments(doc: { path: string }, read: () => Promise<{ pr: number | null; comments: ReviewComment[] }>, seq: number) {
  const count = () => document.getElementById("comment-count")
  try {
    const { pr, comments } = await read()
    if (seq !== openSeq) return
    if (pr === null) return
    const ts = threads(comments, doc.path)
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
  showSection("rfds")
  document.body.dataset.view = "doc"
  $("crumb").textContent = `RFD ${pad(m.number)}`
  try {
    const rfd = await source.rfd(m)
    if (seq !== openSeq) return
    current = rfd
    currentNote = null
    lastRfd = rfd.number
    renderDoc(rfd)
    renderList()
    void host.save("last", number).catch(() => undefined)
    void streamComments(rfd, () => source.comments(rfd), seq)
  } catch (e) {
    if (seq === openSeq) status(explain(e), "warn")
  }
}

/** Opening a document shows its own tab (in the tabs layout), without the tab's own auto-open. */
function showSection(s: Section) {
  if (section === s) return
  section = s
  document.body.dataset.section = s
  textFilter = ""
  $<HTMLInputElement>("filter").value = ""
  void host.save("section", s).catch(() => undefined)
}

let lastNote: string | null = null
/** The RFD read last, so the RFDs tab comes back to it. */
let lastRfd: number | null = null

async function openNote(id: string) {
  const m = notes.find((n) => n.id === id)
  if (!m) return
  const seq = ++openSeq
  hideHover()
  showSection("reading")
  document.body.dataset.view = "doc"
  $("crumb").textContent = `Reading · ${m.read}`
  try {
    const note = await noteSource.note(m)
    if (seq !== openSeq) return
    currentNote = note
    current = null
    lastNote = id
    renderNoteDoc(note)
    renderList()
    void host.save("lastNote", id).catch(() => undefined)
    void streamComments(note, () => noteSource.comments(note), seq)
  } catch (e) {
    if (seq === openSeq) status(explain(e), "warn")
  }
}

function home() {
  openSeq++
  current = null
  currentNote = null
  document.body.dataset.view = "list"
  $("crumb").textContent = ""
  const reading = layout === "tabs" && section === "reading"
  $("doc").replaceChildren(el("div", { class: "placeholder" }, el("p", { textContent: reading ? "Pick a reading note, or press ⌘/ to jump to one." : "Pick an RFD, or press ⌘/ to jump to one." })))
  renderList()
}

// ---- Hover previews ---------------------------------------------------------------------

let hoverTimer: ReturnType<typeof setTimeout> | undefined
function hideHover() {
  clearTimeout(hoverTimer)
  $("hovercard").hidden = true
}

document.addEventListener("mouseover", (e) => {
  const a = (e.target as HTMLElement).closest<HTMLElement>("#doc [data-rfd], #search-preview [data-rfd], #doc [data-note], #search-preview [data-note]")
  if (!a) return
  const r = a.dataset.rfd !== undefined ? rfds.find((x) => x.number === Number(a.dataset.rfd)) : undefined
  const n = a.dataset.note !== undefined ? notes.find((x) => x.id === a.dataset.note) : undefined
  if (!r && !n) return
  clearTimeout(hoverTimer)
  hoverTimer = setTimeout(() => {
    const card = $("hovercard")
    if (r)
      card.replaceChildren(
        el("div", { class: "docnum", textContent: `RFD ${pad(r.number)}` }),
        el("div", { class: "htitle", textContent: r.title }),
        el("div", { class: "docmeta" }, stateChip(r.state), el("span", { textContent: r.authors.join(", ") })),
        el("div", { class: "muted", textContent: `updated ${relTime(r.pr?.updatedAt ?? r.updated)}` }),
      )
    else if (n)
      card.replaceChildren(
        el("div", { class: "docnum", textContent: `Reading note · read ${n.read}` }),
        el("div", { class: "htitle", textContent: n.title }),
        el("div", { class: "docmeta" }, noteChip(n.state), el("span", { textContent: noteFrom(n) })),
        el("div", { class: "muted", textContent: n.tags.map((t) => `#${t}`).join(" ") }),
      )
    const box = a.getBoundingClientRect()
    card.hidden = false
    card.style.left = `${Math.min(box.left, innerWidth - card.offsetWidth - 12)}px`
    card.style.top = `${box.bottom + 6 + card.offsetHeight > innerHeight ? box.top - card.offsetHeight - 6 : box.bottom + 6}px`
  }, 250)
})
document.addEventListener("mouseout", (e) => {
  if ((e.target as HTMLElement).closest?.("[data-rfd], [data-note]")) hideHover()
})

// ---- Search (Cmd-K) and jump-to (Cmd-/) -------------------------------------------------

/** Keyboard selection over a result list: arrows move, Return opens. */
/** A result's key: `rfd:2` or `note:2026-11-18-google-abfs`. */
type Key = string
const rfdKey = (n: number): Key => `rfd:${n}`
const noteKey = (id: string): Key => `note:${id}`
function openKey(k: Key) {
  if (k.startsWith("note:")) void openNote(k.slice(5))
  else void open(Number(k.slice(4)))
}

function listKeys(input: HTMLInputElement, list: HTMLOListElement, onPick: (k: Key) => void, onMove?: (k: Key) => void) {
  input.addEventListener("keydown", (e) => {
    const items = [...list.querySelectorAll<HTMLElement>("li[data-key]")]
    const at = items.findIndex((i) => i.classList.contains("active"))
    const move = (to: number) => {
      items.forEach((i) => i.classList.remove("active"))
      const it = items[Math.max(0, Math.min(items.length - 1, to))]
      if (!it) return
      it.classList.add("active")
      it.scrollIntoView({ block: "nearest" })
      onMove?.(it.dataset.key!)
    }
    if (e.key === "ArrowDown") (e.preventDefault(), move(at + 1))
    else if (e.key === "ArrowUp") (e.preventDefault(), move(at - 1))
    else if (e.key === "Enter" && items.length) (e.preventDefault(), onPick(items[Math.max(0, at)].dataset.key!))
  })
}

const loadedNotes = new Map<string, Note>()
let notesInFlight: Promise<Note[]> | null = null

/** Every note's text, shared by the keystrokes of one read. */
function allNotes(): Promise<Note[]> {
  notesInFlight ??= Promise.all(
    notes.map(async (n) => {
      if (!loadedNotes.has(n.id) || loadedNotes.get(n.id)!.sha !== n.sha) loadedNotes.set(n.id, await noteSource.note(n))
    }),
  )
    .then(() => [...loadedNotes.values()].filter((n) => notes.some((m) => m.id === n.id)))
    .finally(() => (notesInFlight = null))
  return notesInFlight
}

const loaded = new Map<number, Rfd>()
let bodiesInFlight: Promise<Rfd[]> | null = null

/** Every RFD's text; keystrokes during a read share it instead of reading the blobs again. */
function allBodies(): Promise<Rfd[]> {
  bodiesInFlight ??= Promise.all(
    rfds.map(async (r) => {
      if (!loaded.has(r.number) || loaded.get(r.number)!.sha !== r.sha) loaded.set(r.number, await source.rfd(r))
    }),
  )
    .then(() => [...loaded.values()])
    .finally(() => (bodiesInFlight = null))
  return bodiesInFlight
}

let searchRun = 0

async function runSearch() {
  const run = ++searchRun
  const q = $<HTMLInputElement>("search-input").value
  const list = $<HTMLOListElement>("search-results")
  // A note that cannot be read leaves RFD search working (and the reverse).
  const [bodies, noteBodies] = await Promise.all([allBodies().catch(() => [] as Rfd[]), allNotes().catch(() => [] as Note[])])
  // A newer keystroke started its own run while this one read bodies: let that one answer.
  if (run !== searchRun) return
  // One list for both kinds, best first: an RFD and a note score on the same scale.
  type Row = { key: Key; score: number; excerpt: string; head: () => HTMLElement }
  const rows: Row[] = [
    ...search(bodies, q).map((h) => {
      const r = rfds.find((x) => x.number === h.number)!
      return { key: rfdKey(r.number), score: h.score, excerpt: h.excerpt, head: () => el("div", {}, el("span", { class: "num", textContent: pad(r.number) }), " ", el("strong", { textContent: r.title }), " ", stateChip(r.state)) }
    }),
    ...searchNotes(noteBodies, q).map((h) => {
      const n = notes.find((x) => x.id === h.id)!
      return { key: noteKey(n.id), score: h.score, excerpt: h.excerpt, head: () => el("div", {}, el("span", { class: "num kindnote", textContent: `Note ${n.read.slice(5)}` }), " ", el("strong", { textContent: n.title }), " ", noteChip(n.state)) }
    }),
  ].sort((a, b) => b.score - a.score)
  list.replaceChildren(
    ...rows.map((h, i) => {
      const [pre, mid, post] = h.excerpt.split(/[«»]/)
      const li = el("li", { class: i === 0 ? "active" : "" }, h.head(), h.excerpt ? el("div", { class: "excerpt" }, pre ?? "", el("mark", { textContent: mid ?? "" }), post ?? "") : null)
      li.dataset.key = h.key
      li.onclick = () => pickSearch(h.key)
      li.onmouseenter = () => previewSearch(h.key)
      return li
    }),
  )
  if (!q.trim()) list.replaceChildren(el("li", { class: "empty", textContent: "Type to search the text of every RFD and reading note." }))
  else if (rows.length === 0) list.replaceChildren(el("li", { class: "empty", textContent: "Nothing matches." }))
  if (rows[0]) previewSearch(rows[0].key)
  else $("search-preview").replaceChildren()
}

function previewSearch(k: Key) {
  const note = k.startsWith("note:") ? loadedNotes.get(k.slice(5)) : undefined
  const r = note ? undefined : loaded.get(Number(k.slice(4)))
  const doc = note ?? r
  if (!doc) return
  const q = $<HTMLInputElement>("search-input").value.trim().toLowerCase().split(/\s+/)[0]
  const blocks = renderBlocks(doc)
  const hit = Math.max(0, blocks.findIndex((b) => q && b.html.toLowerCase().includes(q)))
  const box = $("search-preview")
  const label = note ? `Reading note · read ${note.read}` : `RFD ${pad(r!.number)}`
  // The label and title are file text: set as text; the blocks are the safe renderer's HTML.
  box.innerHTML = blocks.slice(Math.max(1, hit - 1), hit + 4).map((b) => b.html).join("")
  box.prepend(el("div", { class: "docnum", textContent: label }), el("h2", { textContent: doc.title }))
  decorateLinks(box, note ? NOTES_DIR : source.config.dir)
}

function pickSearch(k: Key) {
  $<HTMLDialogElement>("search-dialog").close()
  openKey(k)
}

function runJump() {
  const q = $<HTMLInputElement>("jump-input").value
  const list = $<HTMLOListElement>("jump-results")
  const rfdRows = jump([...rfds].sort(byUpdated), q).map((r) => {
    const li = el("li", {}, el("span", { class: "num", textContent: pad(r.number) }), " ", el("span", { textContent: r.title }), " ", stateChip(r.state))
    li.dataset.key = rfdKey(r.number)
    return li
  })
  const noteRows = jumpNotes([...notes].sort(byRead), q).map((n) => {
    const li = el("li", {}, el("span", { class: "num kindnote", textContent: `Note ${n.read.slice(5)}` }), " ", el("span", { textContent: n.title }), " ", noteChip(n.state))
    li.dataset.key = noteKey(n.id)
    return li
  })
  // The open tab's kind first; a number is always an RFD.
  const rows = (section === "reading" && !/^\d+$/.test(q.trim()) ? [...noteRows, ...rfdRows] : [...rfdRows, ...noteRows]).slice(0, 50)
  rows.forEach((li, i) => {
    if (i === 0) li.classList.add("active")
    li.onclick = () => pickJump(li.dataset.key!)
  })
  list.replaceChildren(...rows)
  if (rows.length === 0) list.replaceChildren(el("li", { class: "empty", textContent: "No RFD or reading note has that number or title." }))
}

function pickJump(k: Key) {
  $<HTMLDialogElement>("jump-dialog").close()
  openKey(k)
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
  if (layout === "tabs" && section === "reading") return showNewNote()
  const n = nextNumber(rfds)
  $("new-number").textContent = pad(n)
  const authors = $<HTMLInputElement>("new-authors")
  if (!authors.value) authors.value = await source.login().catch(() => "")
  // The body starts as the repository's template (RFD 0000), so every RFD has the same sections.
  const body = $<HTMLTextAreaElement>("new-body")
  if (!body.value.trim()) body.value = templateBody(template ? (await source.rfd(template).catch(() => null))?.body : undefined)
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

// ---- New reading note -------------------------------------------------------------------
// A note starts from the repository's `docs/reading/_template.md`: its front matter filled in
// from the form and its four sections. The gateway only reads, so the note goes up the way a new
// RFD does (GitHub's new-file page, committed on a new branch opens the pull request); its index
// row in README.md is the second commit on that branch: the form shows the row, and the note's
// header offers "Add its index row" until that pull request changes README.md.

const today = () => new Date().toISOString().slice(0, 10)
const field = <T extends HTMLElement = HTMLInputElement>(id: string) => $<T>(id) as unknown as HTMLInputElement

function noteForm() {
  const tags = field("note-tags").value.split(/[,\s]+/).map((t) => t.trim().toLowerCase().replace(/^#/, "")).filter(Boolean)
  return {
    title: field("note-title").value.trim(),
    state: field("note-state").value,
    source: field("note-source").value.trim(),
    sourceAuthor: field("note-author").value.trim(),
    published: field("note-published").value.trim(),
    read: field("note-read").value.trim() || today(),
    readBy: field("note-readby").value.trim(),
    sharedBy: field("note-sharedby").value.trim(),
    ask: field("note-ask").value.trim(),
    tags,
    body: field("note-body").value,
  }
}

function rowFor(f: ReturnType<typeof noteForm>) {
  return noteIndexRow({ ...f, file: noteFileName(f.read, f.title || "untitled") })
}

function updateNotePreview() {
  const f = noteForm()
  $("note-file").textContent = `${NOTES_DIR}/${noteFileName(f.read, f.title || "untitled")}`
  $("note-row").textContent = rowFor(f)
}

async function showNewNote() {
  if (!field("note-read").value) field("note-read").value = today()
  const readBy = field("note-readby")
  if (!readBy.value) readBy.value = await source.login().catch(() => "")
  const body = field("note-body")
  if (!body.value.trim()) body.value = noteTemplateBody(await noteSource.templateText())
  updateNotePreview()
  $<HTMLDialogElement>("note-dialog").showModal()
  $("note-title").focus()
}

for (const id of ["note-title", "note-state", "note-source", "note-author", "note-read", "note-tags"]) $(id).addEventListener("input", updateNotePreview)

$<HTMLDialogElement>("note-dialog").addEventListener("close", () => {
  const d = $<HTMLDialogElement>("note-dialog")
  if (d.returnValue !== "ok") return
  const f = noteForm()
  if (!f.title) return
  const file = noteFileName(f.read, f.title)
  const text = newNoteText({ ...f, template: noteTemplateBody(undefined) })
  const { repo, branch } = source.config
  void host.open(newNoteFileUrl(repo, branch, NOTES_DIR, file, text))
  pendingRow = { file, row: rowFor(f) }
  status(`${file} is open on GitHub: commit it on a new branch to open its pull request, then add its index row from the note (Refresh).`)
})

/** The row of the note last written here, until its pull request shows up. */
let pendingRow: { file: string; row: string } | null = null

/** The index row of a note on a pull request: shown to copy, and README.md opened on that branch. */
async function showIndexRow(n: Note) {
  const file = n.path.split("/").pop()!
  const pending = pendingRow
  const row = pending && pending.file === file ? pending.row : noteIndexRow({ ...n, file })
  $("row-text").textContent = row
  const d = $<HTMLDialogElement>("row-dialog")
  d.showModal()
  const copy = $<HTMLButtonElement>("row-copy")
  copy.textContent = "Copy the row"
  copy.onclick = async () => {
    copy.textContent = (await navigator.clipboard?.writeText(row).then(() => true, () => false)) ? "Copied" : "Select and copy it"
  }
  $("row-open").onclick = () => {
    const { repo } = source.config
    if (n.pr) void host.open(`https://github.com/${repo}/edit/${encodeURIComponent(n.pr.head)}/${NOTES_DIR}/README.md`)
    d.close()
  }
}

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
    setIndex(await source.cachedIndex().catch(() => []))
    notes = await noteSource.cachedIndex().catch(() => [])
    if (rfds.length || notes.length) renderList()
  }
  status(`Reading ${source.config.repo}/${source.config.dir} and ${NOTES_DIR}…`)
  // The two folders are read side by side; one failing keeps the other's fresh list.
  const [r, n] = await Promise.allSettled([source.index(), noteSource.index()])
  if (r.status === "fulfilled") setIndex(r.value.rfds)
  if (n.status === "fulfilled") notes = n.value.notes
  renderList()
  const failed = r.status === "rejected" ? r.reason : n.status === "rejected" ? n.reason : null
  if (failed) status(explain(failed), "warn")
  else {
    const missing = r.status === "fulfilled" && r.value.missingFolder && rfds.length === 0
    status(missing ? `${source.config.dir} is not on ${source.config.branch} yet; RFDs in open pull requests show here.` : `${rfds.length} RFDs · ${notes.length} reading notes · read ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`)
  }
  if (current) {
    const now = rfds.find((x) => x.number === current!.number)
    if (now && now.sha !== current.sha) void open(now.number)
  }
  if (currentNote) {
    const now = notes.find((x) => x.id === currentNote!.id)
    if (now && (now.sha !== currentNote.sha || now.indexed !== currentNote.indexed)) void openNote(now.id)
  }
}

const refreshButton = el("button", { type: "button", class: "ghost", textContent: "Refresh", title: "Read GitHub again", onclick: () => void refresh(false) })
$("status").before(refreshButton)
refreshButton.id = "refresh"

void (async () => {
  setVariant(((await host.load<Variant>("variant").catch(() => null)) ?? "directory") as Variant, false)
  const params = new URLSearchParams(location.search)
  lastNote = params.get("note") ?? (await host.load<string>("lastNote").catch(() => null))
  const savedSection = params.get("note") ? "reading" : params.get("rfd") ? "rfds" : ((params.get("section") ?? (await host.load<Section>("section").catch(() => null))) as Section | null)
  section = layout === "tabs" && savedSection === "reading" ? "reading" : "rfds"
  document.body.dataset.section = section
  home()
  await refresh(true)
  const want = Number(params.get("rfd") ?? (await host.load<number>("last").catch(() => null)) ?? NaN)
  if (Number.isFinite(want)) lastRfd = want
  // The index design opens on its table; the others open the last document read on the open
  // tab, else its newest.
  const tableFirst = (variant as Variant) === "index"
  if (tableFirst) return
  if (section === "reading") {
    if (lastNote && notes.some((n) => n.id === lastNote)) void openNote(lastNote)
    else if (notes.length) void openNote([...notes].sort(byRead)[0].id)
    return
  }
  if (Number.isFinite(want) && rfds.some((r) => r.number === want)) void open(want)
  else if (rfds.length) void open([...rfds].sort(byUpdated)[0].number)
})()
