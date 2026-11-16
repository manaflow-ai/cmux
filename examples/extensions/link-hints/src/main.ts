// Link hints: browse the built-in browser with the keyboard. It imports nothing but the public SDK.
// - Each verb is a command (catalog.json) with a page key: a `keyboard` entry whose `when` is
//   `browserFocused`. cmux runs it when you press that key on a page that left the key alone while
//   no text field had focus, and passes the page's tab as `{tab}`.
// - f and F draw a label on every link and button on screen with browserPage().eval. The labels
//   and the keys you type next live in the page: a capture listener takes them before the page
//   sees them, so nothing round-trips through cmux while you type a label.
// - a and y run cmux's own Bookmark This Page and Copy Page URL actions; b goes back.
// - D saves the page's images; / opens a find bar on the page.
// - The pane ("Link hints keys") rebinds every key; the bindings are kept with storage:local under
//   PAGE_KEYS_STORAGE_KEY, and cmux routes the new keys at once.

import {
  browserPage, cmux, command, EmptyState, ForEach, isPageKey, pageKeys, Row, setPageKeys, signal, Text, TextField, VStack,
  type View
} from "cmux-extension-sdk"

type Args = { tab?: string }
type Ctx = { app: string; gesture?: string; cmux: typeof cmux }

/** Every verb: its catalog op, the export that runs it, its default key and what it does. */
export const VERBS = [
  { op: "local.link_hints.follow", key: "f", title: "Follow a link" },
  { op: "local.link_hints.follow_new_tab", key: "shift+f", title: "Open a link in a new tab" },
  { op: "local.link_hints.back", key: "b", title: "Go back" },
  { op: "local.link_hints.bookmark", key: "a", title: "Bookmark this page" },
  { op: "local.link_hints.save_images", key: "shift+d", title: "Save the page's images" },
  { op: "local.link_hints.copy_url", key: "y", title: "Copy the page's address" },
  { op: "local.link_hints.find", key: "/", title: "Find on the page" }
] as const

/** The letters labels are made of: the home row first, so most labels are under your fingers. */
export const HINT_LETTERS = "sadfjklewcmpgh"

const target = (args: Args) => (args?.tab ? { tab: args.tab } : {})

// ---------------------------------------------------------------------------------------------
// Page scripts. Each runs in the page (browserPage().eval sends its source), so it closes over
// nothing and answers at once; what outlives the call stays on listeners it adds to the page.

/**
 * Draws a label on every link and button on screen and follows the one whose label is typed.
 * `newTab` labels only links and opens the pick in a new tab; otherwise Shift on a label's last
 * letter does. Escape, a click, a scroll or 20 seconds without a key take the labels away.
 * Answers how many labels it drew (0 when there is nothing to label).
 */
export function hintScript(letters: string, newTab: boolean): number {
  const w = window as unknown as { __cmuxLinkHints?: () => void }
  w.__cmuxLinkHints?.()
  const selector = newTab
    ? "a[href]"
    : 'a[href], button, input:not([type="hidden"]), select, textarea, summary, label[for], [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="menuitem"], [onclick], [contenteditable=""], [contenteditable="true"]'
  const width = innerWidth
  const height = innerHeight
  const targets: { el: HTMLElement; x: number; y: number }[] = []
  for (const el of Array.from(document.querySelectorAll<HTMLElement>(selector))) {
    if ((el as HTMLButtonElement).disabled) continue
    const rect = Array.from(el.getClientRects()).find((r) => r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < height && r.left < width)
    if (!rect) continue
    const style = getComputedStyle(el)
    if (style.visibility === "hidden" || style.opacity === "0") continue
    // Covered by something else (a modal, a sticky header): only label what a click would reach.
    const x = Math.min(Math.max(rect.left + 1, 0), width - 1)
    const y = Math.min(Math.max(rect.top + 1, 0), height - 1)
    const hit = document.elementFromPoint(Math.min(rect.left + rect.width / 2, width - 1), Math.min(rect.top + rect.height / 2, height - 1))
    if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) {
      const corner = document.elementFromPoint(x + 2, y + 2)
      if (!corner || (corner !== el && !el.contains(corner))) continue
    }
    if (targets.some((t) => t.el.contains(el) && t.x === x && t.y === y)) continue
    targets.push({ el, x, y })
  }
  if (targets.length === 0) return 0

  // Labels of one length, so no label is the start of another.
  let size = 1
  while (letters.length ** size < targets.length) size += 1
  const labels = targets.map((_, i) => {
    let label = ""
    for (let n = i, k = 0; k < size; k += 1, n = Math.floor(n / letters.length)) label = letters[n % letters.length] + label
    return label
  })

  const host = document.createElement("div")
  host.setAttribute("data-cmux-link-hints", "")
  host.style.cssText = "all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;"
  const root = host.attachShadow({ mode: "closed" })
  const sheet = document.createElement("style")
  sheet.textContent = `
    span { position: fixed; padding: 1px 4px; border-radius: 4px; font: 600 12px/16px ui-monospace, Menlo, monospace;
      text-transform: uppercase; letter-spacing: 0.5px; color: #1d1d1f; background: #ffd94a; border: 1px solid #c9a600;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35); white-space: nowrap; }
    span b { color: #9a7b00; font-weight: 600; }
    span.gone { display: none; }`
  root.append(sheet)
  const marks = targets.map((t, i) => {
    const mark = document.createElement("span")
    mark.style.left = `${t.x}px`
    mark.style.top = `${t.y}px`
    mark.textContent = labels[i]
    root.append(mark)
    return mark
  })
  document.documentElement.append(host)

  let typed = ""
  let timer = 0
  const done = () => {
    clearTimeout(timer)
    removeEventListener("keydown", onKey, true)
    removeEventListener("scroll", done, true)
    removeEventListener("mousedown", done, true)
    removeEventListener("blur", done)
    host.remove()
    if (w.__cmuxLinkHints === done) delete w.__cmuxLinkHints
  }
  const draw = () => {
    marks.forEach((mark, i) => {
      const label = labels[i]
      mark.className = label.startsWith(typed) ? "" : "gone"
      mark.replaceChildren()
      const head = document.createElement("b")
      head.textContent = label.slice(0, typed.length)
      mark.append(head, label.slice(typed.length))
    })
  }
  const follow = (el: HTMLElement, inNewTab: boolean) => {
    done()
    const href = el instanceof HTMLAnchorElement ? el.href : ""
    if (inNewTab && href && !href.startsWith("javascript:")) {
      window.open(href, "_blank", "noopener")
      return
    }
    const field = el instanceof HTMLInputElement && !["button", "submit", "reset", "checkbox", "radio", "image", "file", "color"].includes(el.type)
    if (field || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement || el.isContentEditable) {
      el.focus()
      return
    }
    el.focus({ preventScroll: true })
    el.click()
  }
  function onKey(event: KeyboardEvent) {
    if (event.metaKey || event.ctrlKey || event.altKey) return done()
    const key = event.key.toLowerCase()
    if (key === "escape") {
      done()
    } else if (key === "backspace") {
      typed = typed.slice(0, -1)
      draw()
    } else if (key.length === 1 && letters.includes(key)) {
      const next = typed + key
      const index = labels.indexOf(next)
      if (index >= 0) {
        event.preventDefault()
        event.stopImmediatePropagation()
        return follow(targets[index].el, newTab || event.shiftKey)
      }
      if (labels.some((label) => label.startsWith(next))) {
        typed = next
        draw()
      }
    } else if (key !== "shift" && !/^[a-z0-9]$/.test(key)) {
      // A letter no label has is a typo and is swallowed; any other key (an arrow, Space) goes
      // to the page and takes the labels away.
      return done()
    }
    event.preventDefault()
    event.stopImmediatePropagation()
    clearTimeout(timer)
    timer = window.setTimeout(done, 20_000)
  }
  addEventListener("keydown", onKey, true)
  addEventListener("scroll", done, true)
  addEventListener("mousedown", done, true)
  addEventListener("blur", done)
  timer = window.setTimeout(done, 20_000)
  w.__cmuxLinkHints = done
  draw()
  return targets.length
}

/**
 * Saves the page's images (at most 60) to Downloads. Each is fetched into a blob first, so an
 * image another site serves without letting the page read it is skipped. Answers how many it is
 * trying; `window.__cmuxSavedImages` then says how many it saved and skipped.
 */
export function saveImagesScript(): number {
  const w = window as unknown as { __cmuxSavedImages?: { saved: number; skipped: number; total: number } }
  const seen = new Set<string>()
  for (const img of Array.from(document.images)) {
    const src = img.currentSrc || img.src
    if (src && !src.startsWith("data:image/svg") && img.naturalWidth >= 32 && img.naturalHeight >= 32) seen.add(src)
  }
  const sources = Array.from(seen).slice(0, 60)
  const result = { saved: 0, skipped: 0, total: sources.length }
  w.__cmuxSavedImages = result
  const extension = (type: string) => ({ "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/avif": "avif", "image/svg+xml": "svg" })[type] ?? "img"
  sources.forEach((src, i) => {
    fetch(src, { credentials: "include" })
      .then((response) => (response.ok ? response.blob() : Promise.reject(new Error(String(response.status)))))
      .then((blob) => {
        const last = decodeURIComponent(new URL(src, location.href).pathname.split("/").pop() || "")
        const name = /\.[a-z0-9]{2,5}$/i.test(last) ? last : `${location.hostname}-${i + 1}.${extension(blob.type)}`
        const link = document.createElement("a")
        link.href = URL.createObjectURL(blob)
        link.download = name
        link.style.display = "none"
        document.body.append(link)
        link.click()
        link.remove()
        setTimeout(() => URL.revokeObjectURL(link.href), 60_000)
        result.saved += 1
      })
      .catch(() => {
        result.skipped += 1
      })
  })
  return sources.length
}

/** The tally saveImagesScript keeps. */
export function savedImagesScript(): { saved: number; skipped: number; total: number } | null {
  return (window as unknown as { __cmuxSavedImages?: { saved: number; skipped: number; total: number } }).__cmuxSavedImages ?? null
}

/**
 * A find bar at the top right of the page: type to find, Return for the next match, Shift-Return
 * for the one before, Escape to close it. The match stays selected when it closes.
 */
export function findScript(): boolean {
  const w = window as unknown as { __cmuxFindBar?: { focus(): void } }
  if (w.__cmuxFindBar) {
    w.__cmuxFindBar.focus()
    return true
  }
  const host = document.createElement("div")
  host.setAttribute("data-cmux-find-bar", "")
  host.style.cssText = "all: initial; position: fixed; top: 10px; right: 10px; z-index: 2147483647;"
  const root = host.attachShadow({ mode: "closed" })
  const sheet = document.createElement("style")
  sheet.textContent = `
    form { display: flex; gap: 8px; align-items: center; padding: 6px 8px; border-radius: 8px; background: rgba(30, 30, 32, 0.92);
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.35); font: 13px/18px -apple-system, system-ui, sans-serif; color: #f5f5f7; }
    input { width: 220px; padding: 3px 6px; border: 1px solid #5a5a5e; border-radius: 5px; background: #1c1c1e; color: inherit; font: inherit; outline: none; }
    input:focus { border-color: #0a84ff; }
    output { min-width: 64px; color: #a1a1a6; font-size: 12px; }`
  const form = document.createElement("form")
  const input = document.createElement("input")
  input.type = "search"
  input.placeholder = "Find on page"
  input.setAttribute("aria-label", "Find on page")
  const status = document.createElement("output")
  form.append(input, status)
  root.append(sheet, form)
  document.documentElement.append(host)

  const find = (backwards: boolean, fromTop: boolean) => {
    const text = input.value
    if (!text) {
      status.textContent = ""
      return
    }
    if (fromTop) getSelection()?.removeAllRanges()
    const finder = window as unknown as { find(text: string, caseSensitive: boolean, backwards: boolean, wrap: boolean): boolean }
    const found = finder.find(text, false, backwards, true)
    status.textContent = found ? "" : "No matches"
    input.focus({ preventScroll: true })
  }
  const close = () => {
    host.remove()
    delete w.__cmuxFindBar
  }
  input.addEventListener("input", () => find(false, true))
  input.addEventListener("keydown", (event) => {
    event.stopPropagation()
    if (event.key === "Escape") {
      event.preventDefault()
      close()
    } else if (event.key === "Enter") {
      event.preventDefault()
      find(event.shiftKey, false)
    }
  })
  // Keys typed in the bar are the bar's: the page's own shortcuts never see them.
  for (const type of ["keypress", "keyup"]) input.addEventListener(type, (event) => event.stopPropagation())
  form.addEventListener("submit", (event) => event.preventDefault())
  w.__cmuxFindBar = { focus: () => input.focus() }
  input.focus()
  return true
}

// ---------------------------------------------------------------------------------------------
// Commands (catalog.json). cmux calls each with `{tab}` for a page key; from the palette or the
// CLI the tab is the focused one.

async function hints(args: Args, ctx: Ctx, newTab: boolean) {
  const count = await browserPage(ctx.cmux).eval(hintScript, { ...target(args), args: [HINT_LETTERS, newTab] })
  if (!count) await ctx.cmux.toast({ title: newTab ? "No links on screen" : "No links or buttons on screen" })
  return { labels: count ?? 0 }
}

export const followLink = command<Args, unknown>((args, ctx) => hints(args, ctx, false))
export const followLinkInNewTab = command<Args, unknown>((args, ctx) => hints(args, ctx, true))

export const goBack = command<Args, unknown>((args, ctx) => browserPage(ctx.cmux).back(target(args)))

export const bookmarkPage = command<Args, unknown>((_args, ctx) => ctx.cmux.actions.run("bookmark.addPage"))

export const copyURL = command<Args, unknown>(async (_args, ctx) => {
  await ctx.cmux.actions.run("browser.copyURL")
  return null
})

export const findOnPage = command<Args, unknown>((args, ctx) => browserPage(ctx.cmux).eval(findScript, target(args)))

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export const saveImages = command<Args, unknown>(async (args, ctx) => {
  const page = browserPage(ctx.cmux)
  const total = await page.eval(saveImagesScript, target(args))
  if (!total) {
    await ctx.cmux.toast({ title: "No images on this page" })
    return { saved: 0, skipped: 0, total: 0 }
  }
  // The page saves them on its own; read its tally until every image is saved or skipped.
  let tally: { saved: number; skipped: number; total: number } | null = null
  for (let i = 0; i < 20; i += 1) {
    await wait(500)
    tally = await page.eval(savedImagesScript, target(args))
    if (!tally || tally.saved + tally.skipped >= tally.total) break
  }
  const saved = tally?.saved ?? 0
  const skipped = tally?.skipped ?? 0
  await ctx.cmux.toast({
    title: `Saved ${saved} ${saved === 1 ? "image" : "images"} to Downloads`,
    message: skipped ? `${skipped} could not be read from the page.` : undefined,
    tone: saved ? "success" : "warning"
  })
  return tally ?? { saved: 0, skipped: 0, total }
})

// ---------------------------------------------------------------------------------------------
// The keys pane: every verb with its key; type new keys (comma separated) and press Return.

/** Parses what the person typed into page keys: `f`, `F` (Shift+F), `shift+f` or `/`; null when one is not a page key. */
export function parseKeys(text: string): string[] | null {
  const keys: string[] = []
  for (const part of text.split(/[,\s]+/).filter(Boolean)) {
    const key = part.length === 1 && part !== part.toLowerCase() ? `shift+${part.toLowerCase()}` : part.toLowerCase()
    if (!isPageKey(key)) return null
    if (!keys.includes(key)) keys.push(key)
  }
  return keys
}

/** How a key reads in the pane: `F` for Shift+F. */
export function showKey(key: string): string {
  return key.startsWith("shift+") ? key.slice(6).toUpperCase() : key
}

const [bindings, setBindings] = signal<Record<string, string[]> | null>(null)
const [problem, setProblem] = signal<string | null>(null)

function load() {
  pageKeys().then(setBindings, (error: unknown) => setProblem(error instanceof Error ? error.message : String(error)))
}

/** Saves one verb's keys; the verb's default when they match it, so a reset leaves storage clean. */
export function bind(current: Record<string, string[]>, op: string, keys: string[], fallback: string): Record<string, string[]> {
  const next = { ...current }
  if (keys.length === 1 && keys[0] === fallback) delete next[op]
  else next[op] = keys
  return next
}

export function renderKeys(): View {
  if (bindings() === null) load()
  const keysOf = (verb: (typeof VERBS)[number]) => bindings()?.[verb.op] ?? [verb.key]
  const save = (verb: (typeof VERBS)[number], text: string) => {
    const keys = parseKeys(text)
    if (!keys) return setProblem(`"${text}" has a key cmux can't route from a page: use a to z, Shift with a letter, or /.`)
    const next = bind(bindings() ?? {}, verb.op, keys, verb.key)
    setBindings(next)
    setPageKeys(next).then(
      () => setProblem(null),
      (error: unknown) => setProblem(error instanceof Error ? error.message : String(error))
    )
  }
  return VStack({ spacing: 6 }, [
    Text("Keys work on a browser page while no text field has focus. Type keys separated by commas and press Return; leave a field empty to turn its key off.")
      .font("caption")
      .color(cmux.theme.text.secondary),
    ForEach({ items: () => [...VERBS], key: (v) => v.op }, (verb) =>
      VStack({ spacing: 2 }, [
        Row({ title: () => verb().title, subtitle: () => keysOf(verb()).map(showKey).join(", ") || "Off", symbol: "keyboard" }),
        TextField(() => keysOf(verb()).map(showKey).join(", "), { placeholder: "Off", onSubmit: (text) => save(verb(), text) })
      ])
    ),
    Row({ title: "Put back every default key", symbol: "arrow.uturn.backward", tint: cmux.theme.text.secondary }).onTap(() => {
      setBindings({})
      setPageKeys({}).then(
        () => setProblem(null),
        (error: unknown) => setProblem(error instanceof Error ? error.message : String(error))
      )
    }),
    () => (problem() ? EmptyState({ title: "Couldn't change a key", message: problem()!, symbol: "exclamationmark.triangle" }) : null)
  ])
}
