// Reader mode's page script: one expression that browserPage.eval runs in the page of the focused
// browser tab. Run once, it lays a clean copy of the article (title, byline, text, images) over the
// page; run again, it takes the copy away. The page itself is never changed: no reload, the scroll
// position and anything typed stay, and going back is instant. Its answer is small JSON:
// {reader: true, title, words, minutes} | {reader: false} | {reader: false, reason: "no_article"}.
(() => {
  const ID = "cmux-reader-mode"
  const root = document.documentElement
  const open = document.getElementById(ID)
  if (open) {
    open.remove()
    root.style.overflow = root.getAttribute("data-cmux-reader-overflow") ?? ""
    root.removeAttribute("data-cmux-reader-overflow")
    return { reader: false }
  }

  // ---- Find the article: the block whose paragraphs carry the most text (the readability idea).
  const NEGATIVE = /(^|[-_\s])(ad|ads|advert|banner|breadcrumbs?|comments?|cookie|footer|footnotes?|masthead|menu|modal|nav|newsletter|outbrain|popup|promo|recirc|related|share|sharing|sidebar|social|sponsor(ed)?|subscribe|taboola|toolbar|widget)([-_\s]|$)/i
  const POSITIVE = /article|body|content|entry|main|post|prose|story|text/i
  const text = (node) => (node.textContent || "").replace(/\s+/g, " ").trim()
  const names = (node) => `${typeof node.className === "string" ? node.className : ""} ${node.id || ""}`
  const linkDensity = (node) => {
    const all = text(node).length || 1
    let links = 0
    for (const a of node.querySelectorAll("a")) links += text(a).length
    return links / all
  }
  const TAG_WEIGHT = { ARTICLE: 25, MAIN: 15, SECTION: 5, DIV: 5, TD: 3, BLOCKQUOTE: 3, FORM: -10, UL: -5, OL: -5, LI: -5, ASIDE: -25, NAV: -25, FOOTER: -25, HEADER: -10 }
  const scores = new Map()
  const score = (node, add) => {
    if (!node || node === document.body || node === root) return
    if (!scores.has(node)) {
      let base = TAG_WEIGHT[node.tagName] ?? 0
      const label = names(node)
      if (NEGATIVE.test(label)) base -= 25
      if (POSITIVE.test(label)) base += 25
      scores.set(node, base)
    }
    scores.set(node, scores.get(node) + add)
  }
  for (const p of document.body.querySelectorAll("p, pre")) {
    const length = text(p).length
    if (length < 25) continue
    const points = 1 + text(p).split(/[,،、，]/).length + Math.min(3, Math.floor(length / 100))
    score(p.parentElement, points)
    score(p.parentElement?.parentElement, points / 2)
  }
  let best = null
  let bestScore = -Infinity
  for (const [node, value] of scores) {
    const weighted = value * (1 - linkDensity(node))
    if (weighted > bestScore) [best, bestScore] = [node, weighted]
  }
  best = best ?? document.querySelector("article, [itemprop=articleBody], main, [role=main]")
  if (!best) return { reader: false, reason: "no_article" }

  // A body split into blocks (an ad slot every few paragraphs, the lead image in a block of its
  // own) has its story a few levels up: take the ancestor that holds clearly more story text.
  // Paragraphs under an aside, nav, footer, form or a junk-named block are not story text.
  const junkUnder = (node, top) => {
    for (let at = node; at && at !== top; at = at.parentElement) {
      if (/^(ASIDE|NAV|FOOTER|FORM)$/.test(at.tagName) || NEGATIVE.test(names(at))) return true
    }
    return false
  }
  const storyText = (node) => {
    let length = 0
    for (const p of node.querySelectorAll("p, pre")) {
      const size = text(p).length
      if (size >= 25 && linkDensity(p) < 0.5 && !junkUnder(p, node)) length += size
    }
    return length
  }
  let story = storyText(best)
  for (let up = best.parentElement, depth = 0; up && up !== document.body && up !== root && depth < 8; up = up.parentElement, depth++) {
    const more = storyText(up)
    if (more >= story * 1.25 && linkDensity(up) < 0.35) [best, story] = [up, more]
  }

  // Sibling blocks that belong to the same story (bodies split across several columns).
  const parts = []
  const threshold = Math.max(10, bestScore * 0.2)
  for (const sibling of best.parentElement ? best.parentElement.children : [best]) {
    if (sibling === best) { parts.push(sibling); continue }
    const value = scores.get(sibling)
    const length = text(sibling).length
    if ((value !== undefined && value * (1 - linkDensity(sibling)) >= threshold) ||
        (sibling.tagName === "P" && length > 80 && linkDensity(sibling) < 0.25)) parts.push(sibling)
  }

  // ---- Clean a copy: keep text, headings, lists, quotes, code, tables and images; nothing else.
  const absolute = (value) => { try { return new URL(value, document.baseURI).href } catch { return null } }
  const firstOfSet = (set) => (set || "").split(",").map((s) => s.trim().split(/\s+/)[0]).filter(Boolean).pop()
  const DROP = "script, style, noscript, template, iframe, form, button, input, select, textarea, nav, aside, footer, dialog, svg, canvas, object, embed, video, audio, [hidden], [aria-hidden=true], [role=dialog], [role=navigation], [role=complementary], " +
    ".byline, [data-component*=byline], [data-testid*=byline]" // the byline shows once, under the title
  const KEEP_ATTRS = { A: ["href", "title"], IMG: ["src", "alt", "title"], TD: ["colspan", "rowspan"], TH: ["colspan", "rowspan"], TIME: ["datetime"], OL: ["start"] }
  const clean = (source) => {
    const copy = source.cloneNode(true)
    for (const node of copy.querySelectorAll(DROP)) node.remove()
    for (const picture of copy.querySelectorAll("picture")) {
      const img = picture.querySelector("img")
      const set = picture.querySelector("source[srcset]")
      if (img && set && !img.getAttribute("src")) img.setAttribute("src", firstOfSet(set.getAttribute("srcset")))
      for (const s of picture.querySelectorAll("source")) s.remove()
    }
    for (const img of copy.querySelectorAll("img")) {
      const lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src") || img.getAttribute("data-original") ||
        firstOfSet(img.getAttribute("data-srcset") || img.getAttribute("srcset"))
      const current = img.getAttribute("src") || ""
      const src = absolute(current && !current.startsWith("data:") ? current : lazy || current)
      const tiny = Number(img.getAttribute("width")) > 0 && Number(img.getAttribute("width")) < 48
      if (!src || tiny) img.remove()
      else img.setAttribute("src", src)
    }
    for (const node of [...copy.querySelectorAll("div, section, ul, ol, table, header, span, p")].reverse()) {
      if (!copy.contains(node)) continue // the copy is detached: isConnected is false for all of it
      const length = text(node).length
      const media = node.querySelector("img, pre, table")
      const junk = NEGATIVE.test(names(node)) && !POSITIVE.test(names(node))
      if ((junk && length < 600 && !media) || (length < 300 && linkDensity(node) > 0.5 && !media) || (length === 0 && !media)) node.remove()
    }
    for (const node of [copy, ...copy.querySelectorAll("*")]) {
      const keep = KEEP_ATTRS[node.tagName] ?? []
      for (const attr of [...node.attributes]) if (!keep.includes(attr.name)) node.removeAttribute(attr.name)
      if (node.tagName === "A") {
        const href = absolute(node.getAttribute("href") || "")
        if (href && /^https?:/.test(href)) node.setAttribute("href", href)
        else node.removeAttribute("href")
      }
    }
    return copy
  }

  const meta = (...keys) => {
    for (const key of keys) {
      const value = document.querySelector(`meta[property="${key}"], meta[name="${key}"]`)?.getAttribute("content")
      if (value && value.trim()) return value.trim()
    }
    return ""
  }
  const heading = document.querySelector("article h1, main h1, h1")
  const title = (heading && text(heading)) || meta("og:title", "twitter:title") || document.title
  // The byline: the names in it when it marks them (a byline block often also holds the date and
  // share buttons), else its text when that is short enough to be only a byline.
  const bylineOf = (block) => {
    if (!block) return ""
    const named = [...block.querySelectorAll("[itemprop=name], [rel=author], [class*=ContributorName], [class*=author-name], [class*=AuthorName]")]
      .map(text).filter(Boolean)
    if (named.length) return `By ${[...new Set(named)].join(", ")}`
    const whole = text(block)
    return whole.length <= 80 ? whole : ""
  }
  const byline = meta("author", "article:author", "parsely-author") ||
    bylineOf(document.querySelector("[rel=author], [itemprop=author], .byline, .author, [data-component*=byline], [data-testid*=byline]"))
  const site = meta("og:site_name", "application-name") || location.hostname.replace(/^www\./, "")
  const body = document.createElement("div")
  for (const part of parts) body.append(clean(part))
  for (const h of body.querySelectorAll("h1")) if (text(h) === title) h.remove()
  const words = text(body).split(" ").filter(Boolean).length
  if (words < 60) return { reader: false, reason: "no_article" }
  const minutes = Math.max(1, Math.round(words / 230))

  // ---- Lay it over the page, in a shadow root so the page's styles never reach it.
  const host = document.createElement("div")
  host.id = ID
  host.setAttribute("style", "all: initial; position: fixed; inset: 0; z-index: 2147483647; display: block;")
  const shadow = host.attachShadow({ mode: "open" })
  shadow.innerHTML = `<style>
    :host { color-scheme: light dark; }
    .page { position: absolute; inset: 0; overflow-y: auto; outline: none; background: #faf8f4; color: #1d1c1a;
      -webkit-font-smoothing: antialiased; }
    article { max-width: 680px; margin: 0 auto; padding: 64px 28px 120px; font: 400 20px/1.65 "Iowan Old Style", "Charter", Georgia, serif; }
    .site { font: 600 12px/1.4 -apple-system, system-ui, sans-serif; letter-spacing: .06em; text-transform: uppercase; color: #8a847a; }
    h1.title { font: 700 38px/1.18 -apple-system, system-ui, sans-serif; letter-spacing: -.02em; margin: 10px 0 12px; }
    .meta { font: 400 14px/1.5 -apple-system, system-ui, sans-serif; color: #8a847a; margin-bottom: 36px; }
    .body h2, .body h3, .body h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.3; margin: 1.6em 0 .5em; }
    .body h2 { font-size: 26px; } .body h3 { font-size: 22px; } .body h4 { font-size: 19px; }
    .body p, .body ul, .body ol, .body blockquote, .body pre, .body table, .body figure { margin: 0 0 1.1em; }
    .body img { display: block; max-width: 100%; height: auto; margin: 1.4em auto; border-radius: 6px; }
    .body figure { margin: 1.6em 0; } .body figcaption, .body small { font: 400 14px/1.45 -apple-system, system-ui, sans-serif; color: #8a847a; }
    .body a { color: #2a5bd7; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .body blockquote { border-left: 3px solid #d8d2c6; padding-left: 18px; color: #4a4741; font-style: italic; }
    .body pre, .body code { font: 15px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
    .body pre { overflow-x: auto; padding: 14px 16px; background: rgba(0,0,0,.05); border-radius: 6px; }
    .body table { border-collapse: collapse; font-size: 16px; } .body td, .body th { border: 1px solid #d8d2c6; padding: 6px 10px; }
    .hint { font: 400 12px/1.4 -apple-system, system-ui, sans-serif; color: #a9a397; margin-top: 56px; text-align: center; }
    @media (prefers-color-scheme: dark) {
      .page { background: #1c1b19; color: #e7e3dc; }
      .site, .meta, .body figcaption, .body small { color: #9a9488; }
      .body a { color: #8fb0ff; } .body blockquote { border-color: #46423b; color: #c9c4ba; }
      .body pre { background: rgba(255,255,255,.06); } .body td, .body th { border-color: #46423b; }
      .hint { color: #6d685f; }
    }
  </style><div class="page" tabindex="-1"><article>
    <div class="site"></div><h1 class="title"></h1><div class="meta"></div><div class="body"></div>
    <div class="hint">Reader mode. The same key or Escape goes back to the page.</div>
  </article></div>`
  shadow.querySelector(".site").textContent = site
  shadow.querySelector(".title").textContent = title
  shadow.querySelector(".meta").textContent = [byline, `${minutes} min read`].filter(Boolean).join(" · ")
  shadow.querySelector(".body").append(...body.childNodes)
  const page = shadow.querySelector(".page")
  page.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return
    event.stopPropagation()
    host.remove()
    root.style.overflow = root.getAttribute("data-cmux-reader-overflow") ?? ""
    root.removeAttribute("data-cmux-reader-overflow")
  })
  root.setAttribute("data-cmux-reader-overflow", root.style.overflow)
  root.style.overflow = "hidden"
  root.append(host)
  page.focus({ preventScroll: true })
  return { reader: true, title, words, minutes }
})()
