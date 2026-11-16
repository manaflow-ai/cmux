// The elements of the current page that look like clutter, for the agent to
// choose from. Clean this page runs it with browserPage().eval, so it answers
// at once (no promise); it reads the DOM and changes nothing. Bounded: at most
// 6000 elements visited and 150 candidates, outermost first, never the
// element that holds the page's main text or an ancestor of it.
(() => {
  const MAX_VISIT = 6000
  const MAX_CANDIDATES = 150
  const WORDS = /^(ad|ads|adv|advert|advertisement|adslot|adunit|ad-slot|sponsor|sponsored|promo|promoted|cookie|cookies|consent|gdpr|ccpa|privacy-banner|banner|popup|pop-up|modal|overlay|interstitial|newsletter|subscribe|signup|sign-up|paywall|recommended|recommendations|related|trending|outbrain|taboola|share|social|sticky|toast|notification|survey|chat-widget|app-banner|smart-banner)$/
  const tokens = (el) => {
    const raw = [el.id || "", typeof el.className === "string" ? el.className : "", el.getAttribute("aria-label") || "", el.getAttribute("data-testid") || ""].join(" ")
    return raw.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().split(/[\s_\-:]+/).filter(Boolean)
  }
  const area = (r) => Math.max(0, r.width) * Math.max(0, r.height)
  const viewport = Math.max(1, window.innerWidth * window.innerHeight)
  // The main text: <main>/<article>/[role=main], else the element with the most paragraph text.
  let main = document.querySelector("main, article, [role=main]")
  if (!main) {
    let best = 0
    for (const p of document.querySelectorAll("p")) {
      const parent = p.parentElement
      if (!parent) continue
      const n = (parent.innerText || "").length
      if (n > best) { best = n; main = parent }
    }
  }
  const holdsMain = (el) => !!main && (el === main || el.contains(main))
  const esc = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, "\\$&"))
  const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1 } catch { return false } }
  const selectorOf = (el) => {
    if (el.id && /^[A-Za-z][\w-]{0,63}$/.test(el.id) && unique("#" + esc(el.id))) return "#" + esc(el.id)
    const tag = el.tagName.toLowerCase()
    const classes = (typeof el.className === "string" ? el.className : "").split(/\s+/).filter((c) => /^[A-Za-z][\w-]{0,47}$/.test(c)).slice(0, 3)
    if (classes.length) {
      const sel = tag + classes.map((c) => "." + esc(c)).join("")
      try {
        const all = document.querySelectorAll(sel)
        // A class that marks several clutter blocks (every ad slot) is the better rule.
        if (all.length >= 1 && all.length <= 20 && ![...all].some(holdsMain)) return sel
      } catch {}
    }
    const parts = []
    let node = el
    while (node && node.nodeType === 1 && node !== document.documentElement && parts.length < 6) {
      if (node.id && /^[A-Za-z][\w-]{0,63}$/.test(node.id) && unique("#" + esc(node.id))) { parts.unshift("#" + esc(node.id)); break }
      const t = node.tagName.toLowerCase()
      let i = 1
      for (let s = node.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === node.tagName) i++
      parts.unshift(`${t}:nth-of-type(${i})`)
      node = node.parentElement
    }
    const sel = parts.join(" > ")
    return unique(sel) ? sel : null
  }
  const out = []
  const seen = new Set()
  let visited = 0
  let truncated = false
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT)
  for (let el = walker.currentNode; el; el = walker.nextNode()) {
    if (++visited > MAX_VISIT) { truncated = true; break }
    if (el === document.body || holdsMain(el)) continue
    let inside = false
    for (let p = el.parentElement; p; p = p.parentElement) if (seen.has(p)) { inside = true; break }
    if (inside) continue
    const tag = el.tagName.toLowerCase()
    if (tag === "script" || tag === "style" || tag === "link" || tag === "meta") continue
    const style = getComputedStyle(el)
    if (style.display === "none" || style.visibility === "hidden") continue
    const rect = el.getBoundingClientRect()
    if (area(rect) < 400) continue
    const role = el.getAttribute("role") || ""
    const fixed = style.position === "fixed" || style.position === "sticky"
    const words = tokens(el).filter((w) => WORDS.test(w))
    const kind = tag === "iframe" || tag === "aside" || tag === "dialog" || role === "dialog" || role === "alertdialog" || role === "complementary"
    if (!fixed && !words.length && !kind) continue
    const selector = selectorOf(el)
    if (!selector) continue
    seen.add(el)
    out.push({
      selector,
      tag,
      role,
      label: [...new Set(words)].join(" ").slice(0, 80),
      text: (el.innerText || el.getAttribute("title") || el.getAttribute("src") || "").replace(/\s+/g, " ").trim().slice(0, 140),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
      fixed,
      area: Math.round((area(rect) / viewport) * 100) / 100
    })
    if (out.length >= MAX_CANDIDATES) { truncated = true; break }
  }
  return { candidates: out, truncated, main: main ? selectorOf(main) : null }
})()
