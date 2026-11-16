// The pure half of Clean this page: the prompt the agent gets, how its reply is read, and the
// filter that keeps only selectors cmux itself found on the page. No cmux calls here, so the
// tests run these directly.

/** An element src/page_read.js listed (the fields this extension uses). */
export interface Candidate {
  selector: string
  tag: string
  role?: string
  label?: string
  text?: string
  width: number
  height: number
  fixed: boolean
  area?: number
}

/** What the agent picked: elements to hide, and fixed or sticky ones to let scroll away. */
export interface Picks {
  hide: string[]
  unstick: string[]
}

/** The page's own content: never offered to the agent, never hidden. */
const CONTENT = new Set(["article", "main"])
/** The daemon takes at most this many selectors per list. */
const MAX_RULES = 200
/** Characters of an element's text and label the prompt shows. */
const SNIPPET = 80

/** Whether an element is the page's content rather than something around it. */
export function isContent(c: Candidate): boolean {
  return CONTENT.has(c.tag.toLowerCase()) || CONTENT.has((c.role ?? "").toLowerCase())
}

const clip = (s: string | undefined) => {
  const flat = (s ?? "").replace(/\s+/g, " ").trim()
  return flat.length > SNIPPET ? `${flat.slice(0, SNIPPET - 1)}…` : flat
}

/** One line per element: selector, tag and role, size, fixed, then its label and text. */
function describe(c: Candidate): string {
  const parts = [c.selector, c.role ? `${c.tag} role=${c.role}` : c.tag, `${Math.round(c.width)}x${Math.round(c.height)}`]
  if (c.fixed) parts.push("fixed")
  const label = clip(c.label)
  const text = clip(c.text)
  if (label) parts.push(`label=${JSON.stringify(label)}`)
  if (text && text !== label) parts.push(`text=${JSON.stringify(text)}`)
  return parts.join(" | ")
}

/** The question for the agent: what to hide and unstick, chosen only from the listed selectors. */
export function buildPrompt(page: { url: string; title: string; candidates: Candidate[] }): string {
  const lines = page.candidates.filter((c) => !isContent(c)).map(describe)
  return [
    "You are cleaning up a web page so it reads like reader mode. Below are elements on the page,",
    "one per line: selector | tag | width x height | fixed (when it stays on screen) | label | text.",
    "",
    "Pick the clutter: ads and sponsored blocks, cookie and consent banners, popups and modals,",
    "newsletter and sign-up prompts, recommended or related rails. Pick fixed headers, footers and",
    "bars that cover the page to unstick (they then scroll with the page) unless they are clutter",
    "too, then hide them. Never pick the article, its headline, its images or its text. When unsure,",
    "leave an element alone.",
    "",
    "Answer with only this JSON, using selectors copied exactly from the list:",
    '{"hide": ["selector", ...], "unstick": ["selector", ...]}',
    "",
    `Page: ${clip(page.title) || "(untitled)"} (${page.url})`,
    ...lines
  ].join("\n")
}

/** Every top-level `{...}` in text, in order (strings and escapes respected). */
function objects(text: string): string[] {
  const found: string[] = []
  let depth = 0
  let start = -1
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === "\\") i++
      else if (ch === '"') quoted = false
      continue
    }
    if (ch === '"' && depth > 0) quoted = true
    else if (ch === "{") {
      if (depth === 0) start = i
      depth++
    } else if (ch === "}" && depth > 0) {
      depth--
      if (depth === 0) found.push(text.slice(start, i + 1))
    }
  }
  return found
}

const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((s): s is string => typeof s === "string").map((s) => s.trim()).filter(Boolean) : [])

/**
 * Reads the agent's reply: the first JSON object in it with a `hide` or `unstick` list, whether
 * the agent wrapped it in a code fence, explained itself around it or answered with nothing else.
 * Null when there is none.
 */
export function parseReply(text: string): Picks | null {
  for (const candidate of objects(text)) {
    let value: unknown
    try {
      value = JSON.parse(candidate)
    } catch {
      continue
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) continue
    const o = value as Record<string, unknown>
    if (!Array.isArray(o.hide) && !Array.isArray(o.unstick)) continue
    return { hide: strings(o.hide), unstick: strings(o.unstick) }
  }
  return null
}

/** Whether cmux takes a selector as a rule: at most 256 bytes, none of `{ } ; < > @ \` or control characters. */
export function storable(selector: string): boolean {
  return selector.length > 0 && utf8Length(selector) <= 256 && !/[{};<>@\\\u0000-\u001f\u007f]/.test(selector)
}

/** UTF-8 bytes in `s`, counted by hand: cmux's sandbox has no TextEncoder. */
function utf8Length(s: string): number {
  let n = 0
  for (const ch of s) {
    const code = ch.codePointAt(0)!
    n += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4
  }
  return n
}

/**
 * Keeps only selectors src/page_read.js listed (so a made-up or mistyped selector never reaches the page)
 * that cmux takes as rules, never the page's content, each once, at most 200 per list. A selector
 * picked for both is hidden.
 */
export function keepListed(picks: Picks, candidates: Candidate[]): Picks {
  const listed = new Set(candidates.filter((c) => !isContent(c) && storable(c.selector)).map((c) => c.selector))
  const take = (list: string[], skip: Set<string>) => {
    const out: string[] = []
    for (const s of list) {
      if (out.length === MAX_RULES) break
      if (listed.has(s) && !skip.has(s) && !out.includes(s)) out.push(s)
    }
    return out
  }
  const hide = take(picks.hide, new Set())
  return { hide, unstick: take(picks.unstick, new Set(hide)) }
}

/** A web page's origin (`https://host[:port]`, lowercased), or null for any other address. */
export function originOf(url: string): string | null {
  const m = /^(https?):\/\/(?:[^@/?#]*@)?([^/?#]+)/i.exec(url.trim())
  return m ? `${m[1]!.toLowerCase()}://${m[2]!.toLowerCase()}` : null
}

/** `https://www.example.com:8443` -> `www.example.com:8443`. */
export function hostOf(origin: string): string {
  return origin.replace(/^[a-z]+:\/\//i, "").replace(/\/.*$/, "")
}

/** "1 element", "3 elements". */
export function elements(n: number): string {
  return `${n} ${n === 1 ? "element" : "elements"}`
}
