// The RFD model: pure functions over file text and GitHub JSON, so the bun tests run them
// without a page. An RFD is `docs/rfd/NNNN-slug.md` with front matter (state, authors, links).
import { Lexer, Parser, Renderer, type Token, type Tokens } from "marked"

export const STATES = ["prediscussion", "ideation", "discussion", "published", "committed", "abandoned"] as const
export type RfdState = (typeof STATES)[number] | string

export type FrontMatter = Record<string, string | string[]>

export interface RfdMeta {
  number: number
  slug: string
  path: string
  title: string
  state: RfdState
  authors: string[]
  links: string[]
  /** Who may read it (front matter `access`, e.g. `internal`); empty when the file does not say. */
  access: string
  /** ISO date of the last change: front matter `last_updated`, else the newest commit or PR update. */
  updated: string
  /** The blob sha of the text read, the cache key of its body. */
  sha: string
  /** The open pull request it is discussed in, when it is not on the base branch yet or is changing. */
  pr?: { number: number; url: string; head: string; updatedAt: string }
}

export interface Rfd extends RfdMeta {
  body: string
  /** Lines the front matter took, so a file line maps to a body line. */
  bodyLineOffset: number
}

const NAME = /^(\d{4})-([a-z0-9][a-z0-9-]*)\.md$/

/** `0002-earned-access-ladder.md` → {number: 2, slug}; anything else (a folder, a README) → null. */
export function parseRfdName(name: string): { number: number; slug: string } | null {
  const m = NAME.exec(name)
  return m ? { number: Number(m[1]), slug: m[2] } : null
}

export const pad = (n: number) => String(n).padStart(4, "0")

/** The YAML subset RFDs use: `key: value` and `key:` followed by `  - item` lines. */
export function parseFrontMatter(text: string): { data: FrontMatter; body: string; lines: number } {
  const src = text.replace(/^﻿/, "")
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(src)
  if (!m) return { data: {}, body: src, lines: 0 }
  const data: FrontMatter = {}
  let list: string | null = null
  for (const raw of m[1].split(/\r?\n/)) {
    const item = /^\s+-\s+(.*)$/.exec(raw)
    if (item && list) {
      ;(data[list] as string[]).push(unquote(item[1]))
      continue
    }
    const kv = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(raw)
    if (!kv) continue
    const [, key, value] = kv
    if (value === "") {
      data[key] = []
      list = key
    } else {
      list = null
      const inline = /^\[(.*)\]$/.exec(value)
      data[key] = inline ? inline[1].split(",").map((s) => unquote(s.trim())).filter(Boolean) : unquote(value)
    }
  }
  return { data, body: src.slice(m[0].length), lines: m[0].split("\n").length - 1 }
}

const unquote = (s: string) => s.replace(/^(["'])(.*)\1$/, "$2").trim()

const asList = (v: string | string[] | undefined) => (v === undefined ? [] : Array.isArray(v) ? v : [v])
const asText = (v: string | string[] | undefined) => (Array.isArray(v) ? v.join(", ") : (v ?? ""))

/** The `# RFD 0002: Title` heading's title, else the slug. */
export function titleOf(body: string, slug: string): string {
  const h = /^#\s+(.+)$/m.exec(body)
  if (!h) return slug.replace(/-/g, " ")
  return h[1].replace(/^RFD\s*\d+\s*[:.-]\s*/i, "").trim()
}

export function toRfd(path: string, sha: string, text: string, fallbackUpdated = ""): Rfd | null {
  const name = parseRfdName(path.split("/").pop() ?? "")
  if (!name) return null
  const { data, body, lines } = parseFrontMatter(text)
  return {
    ...name,
    path,
    sha,
    title: titleOf(body, name.slug),
    state: asText(data.state).toLowerCase() || "prediscussion",
    authors: asList(data.authors),
    links: asList(data.links),
    access: asText(data.access),
    updated: asText(data.last_updated) || asText(data.updated) || fallbackUpdated,
    body,
    bodyLineOffset: lines,
  }
}

/** Newest first; ties by number, highest first. */
export function byUpdated(a: RfdMeta, b: RfdMeta): number {
  const t = (b.pr?.updatedAt ?? b.updated).localeCompare(a.pr?.updatedAt ?? a.updated)
  return t !== 0 ? t : b.number - a.number
}

export const meta = ({ body: _b, bodyLineOffset: _o, ...m }: Rfd): RfdMeta => m

// ---- Rendering ----------------------------------------------------------------------------

export interface Block {
  /** File lines (1-based) the block covers, front matter included, as review comments count them. */
  from: number
  to: number
  html: string
  /** A heading's id, for the outline. */
  id?: string
  heading?: { depth: number; text: string }
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!)

/**
 * Whether a link in a file may be followed: http(s), mailto, an in-page anchor or a relative path.
 * Anything else (`javascript:`, `data:`, `file:`, `vbscript:` ...) is shown as text and never opened.
 */
export function isSafeHref(href: string): boolean {
  // Browsers drop control characters and whitespace before reading a scheme ("java\tscript:").
  const h = href.replace(/[\u0000- \u007f]/g, "")
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(h)
  return scheme ? ["http", "https", "mailto"].includes(scheme[1]!.toLowerCase()) : true
}

/** A link's absolute URL, resolved against `base`, if it is one the reader may open in a browser tab. */
export function openableUrl(href: string, base: string): string | null {
  if (!isSafeHref(href)) return null
  try {
    const url = new URL(href, base)
    return url.protocol === "https:" || url.protocol === "http:" ? url.href : null
  } catch {
    return null
  }
}

/** A renderer that never passes raw HTML or an active link through: the page shows what the file says. */
function safeRenderer(): Renderer {
  const r = new Renderer()
  r.html = ({ text }: Tokens.HTML | Tokens.Tag) => escapeHtml(text)
  const link = r.link.bind(r)
  r.link = (t: Tokens.Link) => (isSafeHref(t.href) ? link(t) : r.parser.parseInline(t.tokens))
  const image = r.image.bind(r)
  r.image = (t: Tokens.Image) => (isSafeHref(t.href) ? image(t) : escapeHtml(t.text))
  return r
}

export const slugify = (s: string) =>
  s
    .toLowerCase()
    .replace(/[`*_~[\]()]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")

/** The body as top-level blocks, each with the file lines it came from. */
export function renderBlocks(rfd: Pick<Rfd, "body" | "bodyLineOffset">): Block[] {
  const tokens = new Lexer({ gfm: true }).lex(rfd.body)
  const renderer = safeRenderer()
  const blocks: Block[] = []
  let line = rfd.bodyLineOffset + 1
  for (const token of tokens as Token[]) {
    const lines = (token.raw.match(/\n/g) ?? []).length
    if (token.type !== "space") {
      const list = Object.assign([token], { links: (tokens as unknown as { links: Record<string, unknown> }).links })
      const html = Parser.parse(list as never, { gfm: true, renderer })
      const raw = token.raw.replace(/\n+$/, "")
      const block: Block = { from: line, to: line + (raw.match(/\n/g) ?? []).length, html }
      if (token.type === "heading") {
        const h = token as Tokens.Heading
        block.heading = { depth: h.depth, text: h.text }
        block.id = slugify(h.text)
      }
      blocks.push(block)
    }
    line += lines
  }
  return blocks
}

/** RFD numbers a text names: `RFD 2`, `RFD 0002`, `rfd/0002-x.md`, `0002-x.md`. */
export function rfdRefs(text: string): number[] {
  const out = new Set<number>()
  for (const m of text.matchAll(/\bRFD[\s-]?0*(\d{1,4})\b/gi)) out.add(Number(m[1]))
  for (const m of text.matchAll(/(?:^|\/)(\d{4})-[a-z0-9-]+\.md\b/g)) out.add(Number(m[1]))
  return [...out]
}

/** The RFD a link points at, by file name or `RFD N` text, else null. */
export function rfdOfHref(href: string): number | null {
  const m = /(?:^|\/)(\d{4})-[a-z0-9-]+\.md(?:#.*)?$/.exec(href)
  return m ? Number(m[1]) : null
}

// ---- Review comments ----------------------------------------------------------------------

export interface ReviewComment {
  id: number
  in_reply_to_id?: number
  path: string
  /** The line in the PR head; null when the comment is outdated (its line changed). */
  line: number | null
  start_line?: number | null
  original_line?: number | null
  body: string
  user: { login: string; avatar_url?: string } | null
  html_url: string
  created_at: string
}

export interface Thread {
  line: number
  startLine: number
  comments: ReviewComment[]
  url: string
}

/** Comments still on a line of this file, as threads (a reply joins its first comment). */
export function threads(comments: ReviewComment[], path: string): Thread[] {
  const roots = new Map<number, Thread>()
  const sorted = [...comments].sort((a, b) => a.created_at.localeCompare(b.created_at))
  for (const c of sorted) {
    if (c.path !== path) continue
    if (c.in_reply_to_id && roots.has(c.in_reply_to_id)) {
      roots.get(c.in_reply_to_id)!.comments.push(c)
      continue
    }
    if (c.line == null) continue
    roots.set(c.id, { line: c.line, startLine: c.start_line ?? c.line, comments: [c], url: c.html_url })
  }
  return [...roots.values()].sort((a, b) => a.line - b.line)
}

/** The block a thread sits beside: the one whose lines hold its line, else the nearest before it. */
export function blockForLine(blocks: Block[], line: number): number {
  let best = -1
  for (let i = 0; i < blocks.length; i++) {
    if (blocks[i].from <= line && line <= blocks[i].to) return i
    if (blocks[i].from <= line) best = i
  }
  return best < 0 ? 0 : best
}

// ---- Search -------------------------------------------------------------------------------

export interface Hit {
  number: number
  score: number
  /** A short excerpt around the first match, with the match marked by « ». */
  excerpt: string
}

const plain = (md: string) =>
  md
    // Fences go, their code stays: a command or name in an example is searchable too.
    .replace(/^```.*$/gm, " ")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[#>*_|~-]+/g, " ")
    .replace(/\s+/g, " ")

/** Every term must appear; the title weighs more than the body. Numbers match `RFD N`. */
export function search(rfds: Rfd[], query: string): Hit[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return []
  const hits: Hit[] = []
  for (const r of rfds) {
    const title = `${pad(r.number)} ${r.number} ${r.title} ${r.authors.join(" ")} ${r.state}`.toLowerCase()
    const text = plain(r.body)
    const lower = text.toLowerCase()
    let score = 0
    let first = -1
    let ok = true
    for (const t of terms) {
      const inTitle = title.includes(t)
      const at = lower.indexOf(t)
      if (!inTitle && at < 0) {
        ok = false
        break
      }
      score += (inTitle ? 10 : 0) + (at >= 0 ? 1 + Math.min(5, lower.split(t).length - 2) : 0)
      if (at >= 0 && (first < 0 || at < first)) first = at
    }
    if (!ok) continue
    let excerpt = ""
    if (first >= 0) {
      const t = terms.find((x) => lower.indexOf(x) === first) ?? terms[0]
      const s = Math.max(0, first - 60)
      excerpt = `${s > 0 ? "…" : ""}${text.slice(s, first)}«${text.slice(first, first + t.length)}»${text.slice(first + t.length, first + t.length + 90)}…`
    }
    hits.push({ number: r.number, score, excerpt })
  }
  return hits.sort((a, b) => b.score - a.score || b.number - a.number)
}

/** Jump-to: by number (`2`, `0002`) or title words, in list order. */
export function jump(rfds: RfdMeta[], query: string): RfdMeta[] {
  const q = query.trim().toLowerCase()
  if (!q) return rfds
  const n = /^\d+$/.test(q) ? Number(q) : null
  return rfds
    .map((r) => {
      const hay = `${pad(r.number)} ${r.title}`.toLowerCase()
      const score = n !== null && r.number === n ? 100 : hay.startsWith(q) ? 50 : q.split(/\s+/).every((w) => hay.includes(w)) ? 10 : 0
      return { r, score }
    })
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((x) => x.r)
}

// ---- A new RFD ----------------------------------------------------------------------------

export function nextNumber(rfds: RfdMeta[]): number {
  return rfds.reduce((m, r) => Math.max(m, r.number), 0) + 1
}

/**
 * The body sections every RFD has, in order (`docs/rfd/0000-template.md` in the repository is
 * the source; this is the fallback when it is missing).
 */
export const TEMPLATE_BODY = `## Problem and context

## Options

1. **Option A**: one line.
2. **Option B**: one line.

Not under consideration:

- **Option C**: why, in one line.

## Goals

## The options against the goals

### Option A

### Option B

## Determination
`

/** RFD 0000 is the template: its body, without front matter and title, is a new RFD's skeleton. */
export function templateBody(templateText: string | undefined): string {
  if (!templateText) return TEMPLATE_BODY
  const body = parseFrontMatter(templateText).body.replace(/^\s*#\s+[^\n]*\n/, "").trim()
  return body ? `${body}\n` : TEMPLATE_BODY
}

export function newRfdText(o: { number: number; title: string; state: string; authors: string[]; body?: string; template?: string; today: string }): string {
  const authors = o.authors.length ? o.authors.map((a) => `  - ${a}`).join("\n") : "  - "
  return `---
state: ${o.state}
authors:
${authors}
last_updated: ${o.today}
access: internal
links: []
---

# RFD ${pad(o.number)}: ${o.title}

${o.body?.trim() || (o.template ?? TEMPLATE_BODY).trim()}
`
}

export type LinkKind = "discussion" | "recording" | "rfd" | "link"

/** What a front matter link is, for the header: a pull request, a recording, another RFD or a link. */
export function linkKind(url: string): { kind: LinkKind; label: string } {
  const pr = /github\.com\/[^/]+\/[^/]+\/pull\/(\d+)/.exec(url)
  if (pr) return { kind: "discussion", label: `Discussion #${pr[1]}` }
  if (/youtube\.com|youtu\.be|vimeo\.com|loom\.com|\.(mp4|mov|m4a|mp3|webm)(\?|$)|recording|episode|podcast/i.test(url)) return { kind: "recording", label: "Recording" }
  const n = rfdOfHref(url)
  if (n !== null) return { kind: "rfd", label: `RFD ${pad(n)}` }
  const host = /^https?:\/\/([^/]+)/.exec(url)?.[1]
  return { kind: "link", label: host ? host.replace(/^www\./, "") : url.split("/").pop() || url }
}

/** The table of contents: the body sections (level 2 headings), numbered, with their level 3s. */
export function toc(blocks: Block[]): Array<{ id: string; text: string; depth: number }> {
  return blocks.filter((b) => b.heading && b.id && (b.heading.depth === 2 || b.heading.depth === 3)).map((b) => ({ id: b.id!, text: b.heading!.text, depth: b.heading!.depth }))
}

/** GitHub's new-file page with the RFD filled in: committing it there on a new branch opens the pull request. */
export function newFileUrl(repo: string, branch: string, dir: string, number: number, title: string, text: string): string {
  const filename = `${dir.replace(/\/$/, "")}/${pad(number)}-${slugify(title) || "untitled"}.md`
  return `https://github.com/${repo}/new/${encodeURIComponent(branch)}?filename=${encodeURIComponent(filename)}&value=${encodeURIComponent(text)}`
}

export const relTime = (iso: string, now = Date.now()) => {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return iso
  const d = Math.round((now - t) / 86400000)
  if (d <= 0) return "today"
  if (d === 1) return "yesterday"
  if (d < 30) return `${d} days ago`
  return new Date(t).toISOString().slice(0, 10)
}
